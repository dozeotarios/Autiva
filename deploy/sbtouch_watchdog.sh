#!/var/jb/bin/bash
# arcflow sbtouch-watchdog — conservative self-heal for the SpringBoardTouch tap
# server (dylib inside backboardd).
#
# ── 2026-11-11 rewrite: the heal was more dangerous than the fault ────────────
# The previous version healed with `killall -9 backboardd`. That is precisely
# the daemon whose missed userspace-watchdog checkins produce
# `userspace-panic-*.ips`:
#
#     no successful checkins from backboardd
#     service: backboardd, no successful checkins in 824 seconds
#     This panic was prevented by palera1n and palera1nd triggered a
#     userspace reboot instead.
#
# (four such reports on this phone, 2026-11-08 16:53-17:02, 3 minutes apart —
# i.e. a loop). A userspace reboot can come back unjaillbroken. So this script
# now follows three rules:
#
#   1. NEVER touch backboardd. Heal with `sbreload` (SpringBoard userspace
#      reload) at most once per cooldown, and never while a session lease or
#      recent touch activity says the phone is being driven.
#   2. NEVER heal on one failed ping. Two consecutive misses are required, and
#      the counter is durable so a restart cannot launder a strike.
#   3. NEVER loop. 30 min cooldown, max 2 heals per hour, then a sticky
#      give-up marker for the operator (the host watchdog alerts on it).
#
# Deployed to /var/jb/usr/local/bin/sbtouch_watchdog.sh (tracked in the repo at
# src/arcflow/phone/native/sbtouch_watchdog.sh).
set -u
CMD=/var/mobile/touch_cmd.json
ST=/var/mobile/touch_status.json
STAMP=/var/mobile/.sbtouch_last_respring
STRIKES=/var/mobile/.sbtouch_dead_strikes
HLOG=/var/mobile/.sbtouch_heals.log
GAVEUP=/var/mobile/.sbtouch_gaveup
# Written by the host (arcflow) while a plan / recording session owns the phone.
LEASE=/var/mobile/.sbtouch_session
BUSY_WINDOW=120          # s of recent touch-file activity ⇒ a post is active
STRIKES_TO_HEAL=2        # consecutive failed pings before ANY heal
COOLDOWN=1800            # s between heals
MAX_HEALS_PER_HOUR=2
NOW=$(date +%s)

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }

# 0. Give-up state is sticky until an operator removes the marker.
if [ -f "$GAVEUP" ]; then
  log "give-up marker present ($GAVEUP) — idle; needs operator action"
  exit 0
fi

# 1. Never heal while the phone is legitimately in use.
if [ -f "$LEASE" ]; then
  log "skip: session lease $LEASE present"
  exit 0
fi
for f in "$CMD" "$ST"; do
  [ -f "$f" ] || continue
  m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  if [ $((NOW - m)) -lt "$BUSY_WINDOW" ]; then
    log "skip: phone busy (touch file activity < ${BUSY_WINDOW}s)"
    exit 0
  fi
done

# 2. Probe the tap server via its file protocol (v9 adds a socket probe).
rm -f "$ST"
printf '%s' '{"action":"ping"}' > "${CMD}.wd" && mv "${CMD}.wd" "$CMD"
i=0
while [ ! -s "$ST" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
if grep -q success "$ST" 2>/dev/null; then
  [ -f "$STRIKES" ] && rm -f "$STRIKES"
  exit 0
fi

# 3. Failed ping ⇒ strike. A single strike never heals.
n=0
[ -f "$STRIKES" ] && n=$(tr -dc '0-9' < "$STRIKES" 2>/dev/null || echo 0)
[ -n "$n" ] || n=0
n=$((n + 1))
echo "$n" > "$STRIKES"
if [ "$n" -lt "$STRIKES_TO_HEAL" ]; then
  log "tap ping failed (strike $n/$STRIKES_TO_HEAL) — awaiting confirmation"
  exit 0
fi

# 4. Cooldown.
if [ -f "$STAMP" ]; then
  last=$(tr -dc '0-9' < "$STAMP" 2>/dev/null || echo 0)
  [ -n "$last" ] || last=0
  if [ $((NOW - last)) -lt "$COOLDOWN" ]; then
    log "heal wanted but within ${COOLDOWN}s cooldown — waiting"
    exit 0
  fi
fi

# 5. Hourly budget, then sticky give-up.
if [ -f "$HLOG" ]; then
  awk -v cut=$((NOW - 3600)) '$1+0 >= cut+0' "$HLOG" > "${HLOG}.tmp" 2>/dev/null \
    && mv "${HLOG}.tmp" "$HLOG"
fi
heals=0
[ -f "$HLOG" ] && heals=$(wc -l < "$HLOG" | tr -d ' ')
[ -n "$heals" ] || heals=0
if [ "$heals" -ge "$MAX_HEALS_PER_HOUR" ]; then
  log "heal budget exhausted (${heals}/h) — giving up; marker $GAVEUP"
  echo "$NOW" > "$GAVEUP"
  exit 0
fi

# 6. Heal: sbreload only. backboardd is never signalled from here.
SBRELOAD=$(command -v sbreload 2>/dev/null || true)
[ -n "$SBRELOAD" ] || SBRELOAD=/var/jb/usr/bin/sbreload
echo "$NOW" > "$STAMP"
echo "$NOW" >> "$HLOG"
log "tap server DOWN after $n strikes — sbreload via $SBRELOAD (backboardd NOT touched)"
nohup "$SBRELOAD" >/dev/null 2>&1 &
exit 0
