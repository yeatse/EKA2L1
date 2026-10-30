# Snakes Subsonic: RGB444 data on the N97 PostingSurface path

After the N97 N-Gage launcher/input/startup fixes in upstream PR #967,
Snakes Subsonic starts but shows two purple-tinted copies of its picture
across the upper half of the game area. The lower half stays black. This
investigation used the Release iOS simulator at `bbdeb6799` with temporary
instrumentation; it did not change production emulator behavior.

## What the device profile explains

The supplied `N-Gage_2.0_configs_en.txt` distinguishes display configurations,
backbuffer configurations, color formats, and device orientations. These are
useful leads rather than a reason to replace the entire profile or force all
buffers to the physical screen size.

The installed N97 repository, UID `0x20001079`, has independent 320×240 and
640-wide display configurations, separate backbuffer sizes, and only the
90-degree N-Gage orientation. Its 320×240 landscape backbuffer configuration
requests scaling to 480×360 at window position (80, 0).
`backbufferscaling` is 1. Both `0x00010010` and `0x00040020` display color
formats are present. No profile setting was retained from the experiments.

At `dispatch::flexible_post`, the game actually supplies:

| Field | Value |
|---|---|
| Posting source | 320×240, `0x01000004` (RGBx8888 little endian) |
| Source crop | (0, 0)–(320, 240) |
| Displayed rectangle | (80, 0)–(560, 360) |
| Scale rectangle | (0, 0)–(480, 360), relative to the displayed rectangle |
| Posting rotation / mirror | 0 / 0 |
| Emulator screen / display scale | 640×360 / 1 |

The posting rotation is already zero; applying another 90-degree rotation
based only on the phone profile would be incorrect for this submission.

## The corruption is present before texture upload

A snapshot of the 307,200-byte posting buffer already contains the repeated
picture. Reading those same bytes as the declared RGBx8888 reproduces the
two purple copies and the black lower half. Reading its first 153,600 bytes
as a 320×240 RGB444 image, stored in 16-bit words, produces one complete
menu with normal red/orange/cyan colors. RGB565 interpretation also restores
the geometry, but gives incorrect colors. Thus the precise source is RGB444,
not RGB565.

The duplicate geometry follows directly from the pixel-size mismatch: each
32-bit destination pixel consumes two 16-bit source pixels, and a destination
row consumes two source rows. The two halves resemble adjacent source rows;
the remaining destination memory is black. This is not GPU texture wrapping.

## Guest adapter evidence

The installed `ngibackbuffer.dll` has UID3 `0x20002331`, code size `0x2A6C4`,
and SHA-256
`e879bd5a15ba145c4007f2eafb2bc1e9c1a519d3b39082e6319609d462b1741d`.
The following are code-relative offsets, not process addresses:

- The source-parameter setup near `0x5158` / `0x546C` maps source format
  `0x00010010` to posting RGB565, `0x00020018` to RGB888, and other formats
  to RGBx8888. It therefore selects RGBx8888 for `0x00004010` (RGB444).
- At posting time, the backbuffer object still records source format
  `0x00004010` at offset `0x188`, while its posting format at `0xFC` is
  `0x01000004`.
- The temporary-buffer allocation near `0x66B8` and the copy near `0x6F70`
  treat only `0x00010010` as two bytes per pixel; other formats take the
  four-byte path. The latter is a word-copy loop ending at `0x6FC0`, followed
  by the PostingSurface `PostBuffer` call. This branch performs no RGB444
  expansion before presenting the data as RGBx8888.

For RGB444, the proposed format and the fallback format are both RGBx8888:
`r5 == r6` in the code above. Both outcomes of `FormatSupported` therefore store
the same posting format and `EColor16MU` display mode. Changing that capability
response cannot repair this particular format mismatch. The PostingSurface API
has no RGB444 posting format to advertise instead.

The confirmed fault boundary is the guest RGB444 producer / N-Gage posting
adapter: the pixel data reaching EKA2L1 disagrees with the declared posting
format, and this adapter's copy path does not expand it. A general fix must
resolve the producer/adapter agreement or convert the source before posting.
Inferring a format from image contents in the host renderer would hide the
contract violation and affect unrelated software. This does not yet establish
why the producer ignores the adapter's returned display mode, or whether a
different emulated capability selects a different backend before this point.

## Comparison with the working 5320 package

The locally available package `N-Gage 2.0 v1.40.1557 by BodyZ, Fixed by
FROST_A-52.sis` supplies a different `ngibackbuffer.dll`, with the same UID3,
file size 46,999 bytes, code size `0x25018`, and SHA-256
`53c628ddb0e8926f7fb1f8b33577ed6352ca5b3ebf0b3ab7f6bf3c42ec921af6`.
Its decompressed code contains DirectScreenAccess and RGB444 conversion
classes, but lacks the PostingSurface backend identifiers and profile keys
present in the N97 library. Both libraries contain RGB444 conversion classes;
their mere presence does not show that the active path uses them.

The comparison used the same clean Release emulator at `3973d5f49`, the same
installed Snakes game, and temporary isolated copies of the C: and E: drives.
Installation and guest input used the HTTP control API.

| ROM / runtime | Result |
|---|---|
| N97 / original 1.30 runtime | Starts, with the RGB444-as-RGBx8888 corruption described above |
| 5320 / complete 1.40.1557 package | Starts with one correctly colored, full 320×240 menu |
| N97 / complete 1.40.1557 package | Startup error 3, including after discarding the isolated old device-profile cache |
| N97 / original runtime with only the 1.40 backbuffer DLL | Startup error 3 |
| 5320 / 1.40 runtime with only the original N97 backbuffer DLL | Startup error 3 |

The working 5320 configuration is a useful control for the game and emulator,
but does not exercise the N97 PostingSurface adapter. The failed mixed-DLL
experiments do not isolate a conversion fix; the libraries cannot be treated as
interchangeable. The complete 1.40 package is not a validated N97 workaround,
and its startup error remains a separate investigation from the observed
posting-buffer corruption. The original N97 DLL and device-drive configuration
were restored byte for byte, and the temporary isolated drives were removed.

## Controls and remaining limits

Using converted copies of the Symbian rectangles in the host blit did not
remove the duplication, consistent with the raw-buffer finding. Separately,
the current blit ignores the displayed rectangle's (80, 0) origin, explaining
the leftward placement; that is not the source of the duplicated pixels.

Temporarily setting `backbufferscaling` to 0 selects a different path, but
Snakes then reports startup error 3 and logs guest access violations. It is
not a validated workaround. The original repository was restored byte for
byte, all probes were removed, and a clean Release application was rebuilt.
No FPS tuning or backbuffer resolution edits were retained.
