# Autiva

Remote touch control for a jailbroken iPhone. A dylib inside the phone injects real
touches and captures the screen. A small CLI drives it over SSH from another machine.

Built for an iPhone X on iOS 16 with palera1n rootless. Running in production against a
posting pipeline.

## The problem

Driving a phone over SSH normally costs one round trip per gesture: tap, screenshot,
decide, tap again. Each of those can fail on its own, and a failed tap reports success
often enough that the logs stop meaning anything.

Two traps are specific to this device:

1. Every synthetic touch looks identical to the system. Same finger, same pressure, same
   80 ms hold, no contact size. Gesture recognizers and automation checks read those
   fields.
2. The obvious recovery for a stuck touch daemon is to restart backboardd. On this device
   that can trip a userspace watchdog panic, and a panic can come back unjailed.

Autiva answers both. A whole session is one request executed on the device against
absolute deadlines. Recovery is one SpringBoard reload, and it needs two failures in a row
before it fires.

## Architecture

```
laptop
  sbtctl
    |
    | ssh
    v
/var/mobile/sbtouch_inbox/<id>.json
    |
    v
backboardd + Autiva
    |                  |
    v                  v
HID events      screen capture
    |                  |
    v                  v
the app's UI    PNG on the phone
```

## Layers

| Layer | What it does | What it prevents | Why it sits there |
|---|---|---|---|
| `src/core` | JSON, request and reply protocol, gesture sampling, plan validation, recorder ring | malformed commands reaching the phone, repeated identical gestures, a plan that half executes | no Apple APIs, so it compiles and tests anywhere in milliseconds |
| `src/ios` | builds and dispatches HID events, captures the screen, runs the mailbox, owns the entry point | a napping display killing a run, memory churn inside backboardd, a capture stalling input | the only place Apple frameworks exist, kept as thin as possible |
| `src/cli` | one request, one reply, exit codes | callers guessing whether the phone is busy, gone, or refusing | a separate process, so transport stays out of the dylib and works over plain ssh |
| `deploy` | injection filter, LaunchDaemon, watchdog script | a dead touch server staying dead, a recovery that panics the device | recovery rules that the code under recovery cannot rewrite |
| `tests` | host unit tests, device verification | merging a change because it looked fine | pixel and field evidence instead of status strings |

## Why it is split this way

Three rules decide every boundary in this repo.

1. **Apple APIs live in one directory.** `src/ios` is small and boring on purpose. Anything
   that can be written without a framework goes into `src/core`, where it can be tested on
   a laptop in milliseconds instead of on a phone that needs a respring to deploy.
2. **The transport is a detail, not the design.** Requests and replies are plain JSON.
   That is why the same protocol survived a forced change of transport: the daemon cannot
   open a socket or register a Mach service, so it uses per request files, and nothing
   above that layer had to change.
3. **Recovery is separate from what it recovers.** The watchdog is a shell script plus a
   LaunchDaemon, not code inside the dylib. If the dylib is the thing that wedged, its own
   recovery logic is the least trustworthy code on the device.

## Request lifecycle

1. `sbtctl` writes `sbtouch_inbox/<id>.json` with a single JSON line.
2. The dylib picks it up, validates every field, and refuses stale requests.
3. If a command is already running it replies `busy` immediately instead of queueing.
4. Execution happens on a serial queue, off the main thread, on absolute deadlines.
5. The reply lands in `sbtouch_outbox/<id>.json` with the same `id` and a `delivered` flag.

`delivered` is true only after the event left the main queue. The old binary wrote success
the moment the event was queued, which is the difference between "we tried" and "it landed".

## Use

```bash
sbtctl '{"id":"1","action":"tap","x":562,"y":962}'
# {"id":"1","status":"ok","ms":94,"delivered":true}

sbtctl '{"id":"2","action":"plan","steps":[
  {"op":"tap","x":1021,"y":2262},
  {"op":"wait","ms":800},
  {"op":"swipe","x1":560,"y1":1800,"x2":560,"y2":900,"duration_ms":320}]}'
# {"id":"2","status":"ok","ms":1263,"delivered":true,
#  "result":{"steps":3,"done":3,"failed_at":null,"budget_ms":15900}}
```

Coordinates are device pixels, 1125 by 2436 on the reference device. Actions, fields, error
codes and exit codes are listed in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Install

```bash
make test           # portable core, about 35k checks, no phone needed
make dylib cli      # compiles on the phone with its own clang-16
make install        # copies into /var/jb and keeps the previous binary for rollback
```

Reload the dylib once, since it lives inside backboardd:

```bash
ssh root@<phone> launchctl kickstart -k system/com.apple.backboardd
```

## What is proven on the device

| Claim | Evidence |
|---|---|
| Taps reach the UI | pixel diffs on both sides of the tap, `delivered:true`, reversible |
| Captures survive a sleeping display | 49 of 50 on a phone that was napping |
| Plans are bounded | 3 of 3 steps in 986 ms, a malformed plan rejected before step 1 |
| Recovery cannot panic the phone | sbreload only, two consecutive failures, then an alert |
| It rebuilds from this source | 179 KB dylib compiled on the device |

## What it does not do

| Missing | Why | Use instead |
|---|---|---|
| Recording real touches | a monitor inside backboardd receives no digitizer events on iOS 16 | a hook inside the target app, the take format is already built |
| Writing the clipboard | UIPasteboard writes from backboardd do not reach the app | `pbset` |
| Resetting the idle timer | not available in that process | a wake nudge plus a capture retry |

Each of these is measured rather than assumed. The evidence is in
[docs/FINDINGS.md](docs/FINDINGS.md).

## Layout

```
README.md
Makefile              host tests, device build, install
build_device.sh       the on device compile step
src/core/             portable C++20
src/ios/              Objective C++ shell
src/cli/              sbtctl
deploy/               injection filter, LaunchDaemon, watchdog
tests/                host unit tests and device verification
docs/                 protocol and findings
```

## License

MIT
