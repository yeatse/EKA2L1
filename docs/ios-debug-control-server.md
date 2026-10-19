# Simulator control server

Simulator builds of the iOS app serve a small HTTP/JSON API on
`127.0.0.1:8765`. It covers what the UI can do, so automation does not have to
drive the UI tap by tap. Because the simulator shares the host's network stack,
plain `curl localhost:8765/...` works from the Mac. Device builds do not compile
it (`DebugControlServer.swift` is `#if targetEnvironment(simulator)`).

- Port: launch argument `-DebugServerPort <n>`. `0` turns the server off. Give
  each booted simulator its own port.
- The server starts once the emulator core is up, which is the first thing the
  home screen does. `GET /v1/status` answers as soon as it is listening.
- Paths in request bodies are **host paths**. A simulator app can read
  `~/Documents/...` directly, so packages do not need to be copied in first.

## Conventions

- Every response is JSON except screenshots, icons, file downloads and the log.
- Successful responses carry the resource itself, with no envelope.
- Failures use a non-2xx status and
  `{"error": {"code": "...", "message": "..."}}`, so `curl -f` fails on them.
  Codes:

  | Code | Status | Meaning |
  |---|---|---|
  | `bad_request` | 400 | Malformed or missing input |
  | `not_found` | 404 | No such device, app, file, job or route |
  | `busy` | 409 | Another emulator operation holds the session |
  | `no_device` | 409 | No device is booted |
  | `no_screen` | 409 | The emulator screen is not up |
  | `not_running` | 409 | No app is running |
  | `*_failed` | 422 | The emulator refused the operation (`install_failed`, `boot_failed`, `mount_failed`, …) |
  | `timeout` | 504 | A wait or launch did not complete in time |

- UIDs are accepted as `0x101FD40B` or decimal, and are always returned as
  `0x%08X`. A device is named by its index or its firmware code (`rh-29`,
  case-insensitive).
- **Jobs.** Long operations (device install/boot/delete/rescan, app install,
  card mount) run as jobs.
  - By default the request blocks until the job ends and returns its result.
  - With `?async=1` the request returns `202` with the job record right away.
    Poll it at `GET /v1/jobs/{id}`; the record has `state`
    (`running|succeeded|failed`), `progress`, `result` and `error`.
- State changes go through the same `DeviceStore`/navigation paths as the UI,
  so the screen always matches what the API reports.

## Endpoints

| Method & path | Body / query | Notes |
|---|---|---|
| `GET /v1` | | Endpoint list |
| `GET /v1/status` | | Booted device, card, session, guest screen geometry, frame count, running jobs, `documents` and `log` host paths |
| `GET /v1/devices` | | |
| `POST /v1/devices` | `{"rom", "rpkg"?}` or `{"archive"}`, `"isolateDrives"?`, `"boot"?` (default true) | Job. Boots the new device |
| `POST /v1/devices/rescan` | | Job |
| `POST /v1/devices/{id}/boot` | | Job. Closes a running app first |
| `PATCH /v1/devices/{id}` | `{"name"}` | Rename |
| `DELETE /v1/devices/{id}` | | Job |
| `GET /v1/apps` | `?system=1` | Includes ROM apps |
| `POST /v1/apps` | `{"path"}` or `{"paths": [...]}`, `"type"?` | Job. Type comes from the path: `.sis/.sisx` → `sis`; `.n-gage` → `ngage2` (staged onto `E:\n-gage`); anything else → `ngage` (N-Gage 1.0 card folder/archive). The result lists `added` apps |
| `DELETE /v1/apps/{uid}` | | Uninstall |
| `GET /v1/apps/{uid}/icon` | `?size=96` | PNG |
| `POST /v1/apps/{uid}/launch` | `{"timeoutMs"?}`, `?wait=0` | Closes the current app, pushes the emulator screen and waits for the launch result |
| `GET /v1/session` | | `state`: `none`, `launching`, `running`, `launch_failed`, `exited`, `crashed` or `closed`; plus `lastExit` (`fatal` holds the panic text) |
| `DELETE /v1/session` | | Close the running app (the in-game "Exit" menu item) |
| `GET/PUT /v1/session/screen-mode` | `{"mode"}` | |
| `GET/PUT /v1/session/frame-limit` | `{"limit"}` | 0 = unlimited |
| `GET /v1/card` | | |
| `PUT /v1/card` | `{"path"}` | Job. Mount a card folder or zip on E: |
| `DELETE /v1/card` | | Eject |
| `GET /v1/keys` | | Key names → scan codes |
| `POST /v1/input/key` | `{"key" \| "keys": [...], "action": "tap\|down\|up", "holdMs": 80, "repeat": 1, "gapMs": 80}` | `keys` presses a chord. `down` keys stay held until `up` or `/v1/input/release` |
| `POST /v1/input/touch` | `{"action": "tap\|down\|move\|up\|swipe", "x", "y", "toX"?, "toY"?, "durationMs"?, "holdMs"?, "id"?, "space"?}` | Coordinates are guest pixels by default, the same grid as `/v1/screenshot`. `space: "normalized"` uses 0…1; `"surface"` uses raw render-surface pixels. `id` keeps multi-touch pointers apart |
| `POST /v1/input/text` | `{"text", "intervalMs"?}` | Taps letter/digit keys; the guest input method decides what they produce |
| `POST /v1/input/sequence` | `{"steps": [...]}` | Each step is a key, touch (`{"touch": {...}}`), text or `{"waitMs"}` object. A step's own `waitMs` runs after it |
| `POST /v1/input/release` | | Releases every key and pointer held through the API |
| `GET /v1/screenshot` | `?region=guest\|screen&scale=1` | PNG. `guest` (default while a game is up) is the guest picture at its own resolution; `screen` is the whole host window in points. `X-Frame-Count` header |
| `GET /v1/log` | `?tail=200`, `?since=<offset>`, `?grep=<regex>` | Text. `X-Log-Offset` gives the position to pass as `since` next time |
| `POST /v1/wait` | `{"until": "running\|exited\|idle\|frames\|log\|sleep", "timeoutMs": 30000, "count"?, "pattern"?, "since"?}` | `frames` waits for `count` new frames. `log` waits for a line matching `pattern` written after the call (or after `since`) |
| `GET/PATCH /v1/config` | partial config object | Same keys as the settings snapshot |
| `GET/PUT /v1/language` | `{"code"}` | |
| `GET /v1/files` | `?path=` | Downloads a file, or lists a directory as JSON |
| `PUT /v1/files` | `?path=`, raw body | Creates parent directories |
| `DELETE /v1/files` | `?path=`, `&recursive=1` | |
| `POST /v1/emulator/pause` / `resume` | | |
| `GET /v1/jobs`, `GET /v1/jobs/{id}` | | The last 50 jobs |

File paths take three forms:

- `C:\...` or `C:/...` is drive C, D or E of the booted device. E is the
  device's own storage, not a mounted card. Each component matches
  case-insensitively, the way the guest sees it.
- `docs:/...` is the app's Documents folder.
- A bare absolute path is a host path.

URL-encode backslashes, or use forward slashes.

## Examples

```sh
api=localhost:8765/v1
curl -s -X POST $api/devices/rh-29/boot
curl -s -X PUT $api/card -d '{"path":"'"$HOME"'/Documents/Apps Backup/Nokia/n-gage/SystemRush.zip"}'
curl -s -X POST $api/apps/0x101FD40B/launch
curl -s -X POST $api/wait -d '{"until":"frames","count":60}'
curl -s -X POST $api/input/sequence -d '{"steps":[{"key":"down","waitMs":600},{"key":"ok"}]}'
curl -s -X POST $api/input/key -d '{"key":"5","action":"down"}'          # hold accelerate
curl -s -X POST $api/input/key -d '{"keys":["5","left"],"holdMs":1500}'  # chord
curl -s -X POST $api/input/touch -d '{"action":"swipe","x":180,"y":500,"toX":180,"toY":200}'
curl -s -o shot.png "$api/screenshot?scale=2"
curl -s "$api/files?path=C:/system/apps/6R63/gameprogress.bin" -o save.bin
curl -s -X PUT --data-binary @save.bin "$api/files?path=C:/system/apps/6R63/gameprogress.bin"
curl -s "$api/log?grep=panic|Access violation&tail=50"
curl -s -X DELETE $api/session
```

API touches are injected straight into the emulator with their own pointer
ids; they do not go through UIKit. A bug in the UITouch path needs real HID
touches (AXe), which is what the Angry Birds regression suite still uses.

Menu screens often ignore a second key that arrives within a few hundred
milliseconds. Put a `waitMs` of about 500 between menu steps.
