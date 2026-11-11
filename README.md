# Autiva

Remote touch control for a jailbroken iPhone. A dylib injects real touches and captures
the screen; a small CLI drives it over SSH.

```
your machine ──ssh──▶ sbtctl ──▶ backboardd + Autiva ──▶ tap · swipe · hold · capture
```

No Mac, no Xcode, no Appium, no runner app. Built for an iPhone X on iOS 16 / palera1n
(rootless), and running in production against a posting pipeline.

## Why it exists

Driving a phone over SSH normally means one command per gesture — tap, screenshot, tap,
screenshot — so every gesture is a round trip that can fail on its own. Two things make
that worse here:

- every synthetic touch looks identical to the system (same finger, same pressure), and
- the obvious recovery for a stuck touch daemon — restarting `backboardd` — is the exact
  thing that can panic this device and cost you the jailbreak.

Autiva fixes both. Gestures are **plans** executed on the device against absolute
deadlines, so a session costs one round trip instead of a hundred. Recovery is a single
SpringBoard reload with a two-strike rule and a give-up marker.

## Install

```bash
make test           # portable core, ~35k checks, no phone required
make dylib cli      # compiles on the phone with its own clang-16
make install        # copies into /var/jb, keeps the previous binary for rollback
```

Reload the dylib once (it lives in `backboardd`):

```bash
ssh root@<phone> launchctl kickstart -k system/com.apple.backboardd
```

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

Every request carries an `id` and every reply echoes it, with `status` = `ok` · `busy`
(executor mid-command) · `error` plus a stable code. `delivered` means the event actually
left the main queue, not that it was queued.

Coordinates are device pixels (1125×2436 on the reference device). The full surface —
actions, fields, error codes, exit codes — is in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## What is proven on the device

| | |
|---|---|
| Taps reach the UI | pixel diffs either side of the tap, `delivered:true`, reversible |
| Captures survive a sleeping display | 49/50 on a phone that was napping |
| Plans are bounded | 3/3 steps in 986 ms; a malformed plan is rejected before step 1 |
| Recovery cannot panic the phone | `sbreload` only, two consecutive failures, then alert |
| It rebuilds from this source | 179 KB dylib compiled on-device with `clang-16` |

## What it does not do

- **Record real touches.** A monitor client inside `backboardd` receives no digitizer
  events on iOS 16, so `record_start` refuses with `no_touch_source` instead of writing
  empty traces. Capturing gestures needs a hook inside the target app.
- **Write the clipboard.** `UIPasteboard` writes from `backboardd` do not reach the app;
  use `pbset`.
- **Reset the display idle timer.** Not available in that process; a wake nudge plus a
  capture retry replaces it.

All three are measured rather than assumed — the evidence is in
[docs/FINDINGS.md](docs/FINDINGS.md).

## Layout

```
src/core/    portable C++20 — protocol, seeded waveform, plans, recorder ring
src/ios/     Objective-C++ shell — HID events, capture, mailbox IPC, entry point
src/cli/     sbtctl
deploy/      injection filter, LaunchDaemon, watchdog script
tests/       host unit tests and device verification
docs/        protocol and findings
```

The split is load-bearing: `src/core` has no Apple APIs, so protocol and gesture
regressions are caught in milliseconds on any machine (`make test`) instead of on a phone
that needs a respring to deploy.

## License

MIT
