# Autiva

**Touch automation for a jailbroken iPhone, driven from another machine over SSH.**

One dylib injected into `backboardd` turns taps, long-presses and swipes into real HID
events — plus screen capture — and a tiny CLI (`sbtctl`) drives it. No Mac, no Xcode, no
Appium, no test-runner app.

Written for an iPhone X (A11) on iOS 16 / palera1n rootless, and in production driving a
real posting pipeline.

---

## What it solves

**1. Touch injection that doesn't take the phone down with it.**
The previous version healed a stuck touch daemon by killing `backboardd` — which is the
daemon whose missed userspace-watchdog checkins *panic the device* (`no successful checkins
from backboardd`, four such reports on our phone in nine minutes). And the deployed binary
had drifted a version ahead of its source, so it could not be rebuilt. Both are fixed here:
the recovery path is one SpringBoard reload, and the source builds the binary.

**2. One round trip per session, not per tap.**
A gesture plan is pushed as a single request and executed on the device against absolute
deadlines. 100 actions cost 1 SSH round trip instead of 100 × ~150 ms. Replies are
correlated by id, so "did it work" is a fact rather than a guess.

## What is actually proven (measured on the device)

| Claim | Evidence |
|---|---|
| Taps reach the UI and are reversible | pixels: phash A→B 16, B→C 16, A→C 0 |
| `delivered` means delivered | true only after the event left the main queue |
| Captures survive a napping display | 49/50 on a sleeping phone (in-dylib wake + retry) |
| `busy` is exact, not a heuristic | a ping concurrent with a screenshot returns `status:"busy"` |
| Plans execute and are bounded | 3/3 steps in 986 ms; malformed plan rejected before any step; budget cut-off at step 1 |
| No new device panics | only the four from 2026-11-08, i.e. before the unstable tweak was disabled |
| Rebuilds from source | 179 KB dylib, compiled on the device with its own clang-16 |

## What it deliberately does **not** do

- **Record real touches.** A monitor client inside `backboardd` receives zero digitizer
  events on iOS 16 (`setMatching` fails; only IMU/ambient/vendor events arrive), so
  `record_start` refuses with `no_touch_source` rather than writing empty traces that look
  successful. Capturing real gestures needs a hook inside the target app.
- **Write the system clipboard.** `UIPasteboard` writes from `backboardd` do not reach the
  app-facing pasteboard. Use `pbset` (or a file + an injected helper). Autiva reports
  `clipboard:false` and says so instead of answering `success` like the old binary did.
- **Reset the display idle timer.** `BKUserEventTimer` does not respond in this process;
  a wake nudge plus a capture retry replaces it.

## Layout

```
src/core/     portable C++20 — JSON, protocol, RNG, waveform profile, plans, recorder ring
src/ios/      Objective-C++ shell — HID events, capture, mailbox IPC, entry point
src/cli/      sbtctl, the client
deploy/       injection filter, watchdog LaunchDaemon + script
tests/        host unit tests (35k checks) and device verification
docs/         protocol and findings
```

The split is not decoration: `src/core` has no Apple APIs, so protocol and waveform
regressions are caught in milliseconds on a Linux host (`make test`) instead of on a phone
that needs a respring to deploy.

## Build

```bash
make test      # portable core, runs anywhere (g++)
make dylib     # compiles ON the phone with its own clang-16, signs with ldid
make cli       # sbtctl
make install   # copies both into /var/jb, keeps the previous binary for rollback
```

Two device constraints are baked into the build because they cost hours to find: the phone's
libc++ has no floating-point `std::to_chars`, and a binary executed from `/tmp` is SIGKILLed
(it must live under `/var/jb`).

## Use

```bash
sbtctl '{"id":"t1","action":"tap","x":562,"y":962}'
# {"id":"t1","status":"ok","ms":94,"delivered":true}

sbtctl '{"id":"p1","action":"plan","steps":[
  {"op":"tap","x":1021,"y":2262},
  {"op":"wait","ms":800},
  {"op":"swipe","x1":560,"y1":1800,"x2":560,"y2":900,"duration_ms":320}]}'
# {"id":"p1","status":"ok","ms":1263,"delivered":true,
#  "result":{"steps":3,"done":3,"failed_at":null,"budget_ms":15900}}
```

Exit codes: `0` ok · `2` busy · `3` no server · `4` command error · `5` usage.
See [docs/PROTOCOL.md](docs/PROTOCOL.md) for every action, reply field and error code.

## Deploying a new build

Reloading the dylib means restarting `backboardd` **once, deliberately**, while the phone is
idle:

```bash
launchctl kickstart -k system/com.apple.backboardd
```

That is a deployment step, never a recovery step. Autiva's own watchdog heals with
`sbreload` only, requires two consecutive failures, and gives up loudly — see
[docs/FINDINGS.md](docs/FINDINGS.md) for why that distinction exists.

MIT licensed.
