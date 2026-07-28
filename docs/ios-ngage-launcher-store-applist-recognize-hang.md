# N-Gage Launcher Store hangs, reports OOM, or renders black

## Symptom

On the 5320 (RM-409), moving right through the N-Gage Launcher tabs works until
the final **Store** tab. The Store header appears over an empty content area,
then the guest stops responding to every key while the iOS application itself
remains alive.

## Narrowing down

The first three tab changes continued to load bitmaps and redraw normally. The
fourth change loaded `ngibrowserengine.dll` and started `CookieServer.exe`, then
the emulator log stopped immediately after:

```
[Service.Applist]: Unimplemented applist opcode 0xA
```

The host process was idle rather than deadlocked: it used almost no CPU and
could still be inspected, but another direction-key event produced neither a
new frame nor any guest log activity. This matched a guest thread blocked in a
synchronous service request.

EKA2L1's new-architecture AppList opcode table identifies `0xA` as
`applist_request_recognize_data`. The enum and the file-handle form of the
request already existed, but the ordinary buffer form had no dispatch case.
The AppList session's default branch only logged an error and did not complete
the IPC, leaving its caller in `SendReceive` forever.

The Symbian AppArc source confirms the contract:

- `RApaLsSession::RecognizeData` sends `EAppListServRecognizeData`;
- slot 0 is a writable packaged `TDataRecognitionResult`;
- slot 1 is the file name;
- slot 2 is the data buffer;
- the server performs recognition, writes the result to slot 0, and completes
  the synchronous message.

This also rules out the nearby missing cache files and OOM-server warning as
the original freeze cause: both occur before the final AppList request, whereas
the uncompleted request exactly accounts for the permanent wait.

## Fix

The AppList server now dispatches `applist_request_recognize_data`. Its handler
wraps the slot-2 descriptor in the same read-only stream used by the existing
file-handle implementation, runs the shared MIME recognizer, writes a
zero-initialized `data_recog_result` to slot 0, and completes with `KErrNone`.
The result uses AppArc's actual signed confidence values. Every non-empty MIME
result, including the deliberate `application/octet-stream` fallback, is
`EProbable` (`100`). The fallback must remain a positive-confidence recognized
type: `EPossible` is numerically zero, which the Launcher treats as no match and
causes it to take a different online-download path. The previous literal `10`
was not a member of Symbian's discrete confidence enum. The file-handle path
now shares this result construction, so its reserved/UID data and confidence
are deterministic too.

Completing the request exposed a second compatibility error: Store displayed
`Out of internal memory (Error -4)`. A temporary request probe showed that the
Launcher was asking AppArc to recognize:

```
E:\Private\20003B78\showroom\frontpage_lg-1.xhtml
```

Its 637-byte buffer began with `<!DOCTYPE`, but EKA2L1's small built-in
recognizer returned the generic `application/octet-stream` fallback with
`EProbable` confidence. That sent the local Store front page through the wrong
content-handler path; the resulting `KErrNoMemory` was a guest error, not host
memory exhaustion.

The original S60 web recognizer classifies `.html`, `.htm`, `.shtml`, `.shtm`,
and `.xhtml` as `text/html` with `EProbable` confidence. It similarly
classifies `.xml` as `text/xml`. EKA2L1 now follows those rules, passes the
filename into the shared recognizer for both IPC variants, and advertises both
web MIME types in the supported-type array. In particular, S60 intentionally
reports XHTML as `text/html`, not `application/xhtml+xml`.

This implements the shared AppArc IPC contract rather than bypassing browser
behavior or special-casing N-Gage.

## Why the local front page was black

The Store is not waiting for a retired online service at this point.
`frontpage_lg-1.xhtml` is a fully local wrapper whose only object is:

```html
<object data="frontpage_lg-1.swf"
        type="application/x-shockwave-flash"
        height="236" width="240">
```

File tracing confirmed that the browser resolved the relative URL correctly
and opened `E:\Private\20003B78\showroom\frontpage_lg-1.swf`. The Flash Lite
DLLs loaded as well. Copying the SWF into the browser cache therefore could not
help.

Getting far enough into the plug-in exposed two missing platform contracts.
The RM-409 browser gates Flash on Feature Manager ID 1146
(`KFeatureIdFlashLiteBrowserPlugin`), and Flash opens its helper process by ID
through executive call `0x71`.

The general compatibility fixes are:

- report feature 1146 when `z:\sys\bin\npflashlite.dll` is present;
- register executive call `0x71` as `process_open_by_id` on Symbian 9.3.

After those changes, forcing a redraw no longer produced a uniformly black
window, but the Flash image appeared as a diagonal trail of colored pixels.
That visual signature isolated the final defect to the iOS bitmap upload.
Flash draws a 246-pixel-wide, 24-bpp bitmap. Symbian/OpenGL pads each row to
four bytes: `246 * 3` is 738 bytes, so the actual stride is 740. The iOS GLES
path manually expands BGR to RGBA and advanced by an integral
`pixels_per_line`; integer division reduced 740 bytes to 246 pixels, and the
converter consequently started every row two bytes early. It now computes the
source byte stride using the same four-byte unpack alignment as the normal GL
upload path. This is a general fix for every padded 24-bpp FBS bitmap, not a
Flash-specific exception.

## Verification

With the Release simulator build on RM-409, four right-direction inputs reach
the Store tab without an unimplemented AppList opcode, frozen guest, or
out-of-memory dialog. The local SWF renders the N-Gage Store header and its five
navigation icons immediately, with correct rows and colors. After waiting 30
seconds, the left soft key still opens the complete Store Options menu, proving
that the browser, Flash plug-in, and Launcher event loops remain responsive.

The Release iOS regression suite also passes 12/12 both with a fresh install
and on the immediately repeated run.
