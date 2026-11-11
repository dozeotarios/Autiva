# Findings (measured, not assumed)

Every statement below has a device-side observation behind it. They are kept because each
one cost real time to discover, and because several of them are the reason a design choice
exists.

## 1. The "jailbreak dropping" was backboardd, and our healer caused the same fault

Four reports on the phone, 3 minutes apart:

```
userspace-panic-2026-11-08 16:53 / 16:56 / 16:59 / 17:02

no successful checkins from backboardd
service: backboardd, no successful checkins in 824 seconds
service: mediaserverd, no successful checkins in 824 seconds
service: configd, no successful checkins in 824 seconds
This panic was prevented by palera1n and palera1nd triggered a userspace reboot instead.
```

`backboardd` is exactly where the touch dylib lives, and the old watchdog healed by
`killall -9 backboardd` (then `ldrestart` from the host). A userspace reboot can come back
unjaillbroken. So the healer could produce the failure it was meant to repair.

Now: `sbreload` only, two consecutive failures required, 30 min cooldown, 2/hour, then a
sticky give-up marker. `backboardd` and `ldrestart` are retired from the ladder and a
retired rung raises instead of running.

Caveat kept honest: those four panics happened while a different, unstable tweak was
injected, and there have been none since it was disabled. The healer fix is about the
mechanism, not about claiming we caused those four.

## 2. The deployed binary was ahead of its source

- deployed `SpringBoardTouch.dylib`: md5 `891308fe…`, 74,848 B
- tracked source: 831 lines, header says **v7**, five actions
- live probe: `{"action":"clipboard"}` answers `success`, for a capability that is not in
  the source at all

Rebuilding from the tracked source would have silently removed a used action. Hence the
`version` action with a build stamp, and the rules: no feature ships unless `version`
reports it, and the host refuses what the phone does not report.

## 3. `backboardd`'s sandbox forbids every socket-shaped IPC

| transport | result |
|---|---|
| unix `bind()` at `/var/mobile/sbtouch.sock` | `EPERM` |
| `/private/var/tmp/sbtouch.sock`, `/var/mobile/Library/…` | `EPERM` |
| `CFMessagePortCreateLocal` (Mach service) | returns `NULL` |
| **create/unlink files under `/var/mobile`** | **works** (always has: `touch_status.json`) |

Hence the per-request file mailbox. It is not a preference; it is the only channel this
process is allowed.

## 4. A monitor client cannot see touches in `backboardd`

`IOHIDEventSystemClientCreateWithType` succeeds, the callback fires, and the events are
types **13 / 12 / 1** (accelerometer, ambient light, vendor-defined), never **11**
(digitizer). `IOHIDEventSystemClientSetMatching(digitizer/touchscreen)` returns a non-zero
IOReturn. Injecting touches from this process works; observing them does not.

Recording therefore needs a hook inside the app whose gestures are being recorded. Until
that exists, `record_start` returns `no_touch_source` (exit 4) instead of writing a trace
with zero samples that reads like a success.

## 5. `UIPasteboard` from `backboardd` is not the app's pasteboard

The old `clipboard` action answered `success` and the caption never landed; production
already used `pbset` + `/var/mobile/clipboard_text.txt` + an injected helper inside
Instagram. Autiva now reads the pasteboard (`clipboard_get`) and refuses the write with an
explicit error code.

## 6. `BKUserEventTimer` exists but does not respond here

`objc_getClass("BKUserEventTimer")` returns a class, `sel_registerName("userEventOccurred")`
resolves, but `respondsToSelector:` is false, so a synthetic touch cannot reset the display
idle timer from this process. Replaced with: nudge `/var/mobile/wake_trigger` between plan
steps, and wake + retry inside the capture path. A napping display fails a capture in ~1 ms,
so the retry is cheap when it is not needed.

## 7. Toolchain facts (cost hours to find)

- the phone's libc++ has **no floating-point `std::to_chars`/`from_chars`** → undefined
  symbol at link time; `snprintf`/`strtod` are used instead
- a binary executed from `/tmp` is **SIGKILLed** (`rc=137`) → everything must live under
  `/var/jb` and be `ldid -S` signed
- private SPI (`kIOSurface*`, `CARenderServer*`) is not in the public SDK → the dylib links
  with `-undefined dynamic_lookup`, and `IOHIDEventSetFloatValue` is resolved with `dlsym`
  so a future iOS that drops it cannot stop the dylib loading
