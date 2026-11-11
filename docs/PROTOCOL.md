# Protocol

One JSON object per request, one per reply. Transport is a per-request file mailbox inside
`/var/mobile`, because that is the only IPC capability `backboardd`'s sandbox grants:

```
host  -> /var/mobile/sbtouch_inbox/<id>.json     (written tmp + rename)
dylib -> /var/mobile/sbtouch_outbox/<id>.json    (written tmp + rename)
```

`/var/mobile/touch_cmd.json` + `touch_status.json` remain supported unchanged, so hosts that
were written against v8 keep working. The mailbox is what adds ids and an exact `busy`.

## Request

```json
{"id": "t1", "action": "tap", "x": 562, "y": 962}
```

`id` is required on the mailbox path (sanitised to `[A-Za-z0-9_.:-]`, max 64 chars) and
echoed in the reply. Coordinates are device pixels: 1125×2436 on the reference device.

| action | fields | notes |
|---|---|---|
| `ping` | — | liveness only |
| `version` | — | build id, capabilities, screen size |
| `state` | — | current executor state |
| `tap` | `x`, `y`, `hold_ms?` | `hold_ms` absent ⇒ sampled (~85 ms) |
| `long_press` | `x`, `y`, `duration_ms?` | default 900 ms, jittered ±10 % |
| `swipe` | `x1`,`y1`,`x2`,`y2`,`duration_ms?` | default 300 ms, 125–160 Hz sampled path |
| `plan` | `steps[]`, `budget_ms?` | see below |
| `screenshot` | `out_path`, `scale?` | PNG on the device, `scale` 0.1–1.0 |
| `clipboard_get` | — | reads the general pasteboard (reads work, writes do not) |
| `clipboard` | `text` | **returns `clipboard_write_unsupported_use_pbset`** |
| `record_start` | `label`, `take_id`, `max_ms` | refuses with `no_touch_source` on iOS 16 |
| `record_stop` / `record_status` | — | take lifecycle (see FINDINGS) |

### Planned steps

```json
{"op":"tap","x":1,"y":2}
{"op":"long_press","x":1,"y":2,"duration_ms":900}
{"op":"swipe","x1":1,"y1":2,"x2":3,"y2":4,"duration_ms":300}
{"op":"wait","ms":500}
```

The whole plan is validated before the first gesture: unknown ops, out-of-screen
coordinates, absurd durations and >500 steps are rejected with nothing executed. Execution
is bounded by `budget_ms` (default: durations + 15 s; max 10 min).

## Reply

```json
{"id":"t1","status":"ok","ms":94,"delivered":true}
{"id":"p1","status":"ok","ms":1263,"delivered":true,
 "result":{"steps":3,"done":3,"failed_at":null,"budget_ms":15900}}
{"id":"r1","status":"busy","ms":0,"delivered":false}
{"id":"s1","status":"error","ms":1,"delivered":false,"error":"out_of_range"}
```

- `status`: `ok` | `busy` | `error`
- `delivered`: the event actually left the main queue (not "queued")
- `busy` is returned instead of queueing, so a probe learns the executor is taken

### Error codes

`bad_json` · `bad_id` · `missing_action` · `unknown_action` · `missing_field` ·
`bad_field` · `out_of_range` · `capture_failed` · `internal` ·
`no_touch_source` · `clipboard_write_unsupported_use_pbset`

Legacy file replies keep the v8 shape: `{"status":"success"|"fail","ts":<epoch>,"error":?}`.
