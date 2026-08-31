# EKA1 direct screen access: guests hardcode different framebuffer depths, and no single setting suits them all

## Status

**Resolved** (2026-08-31), by measuring the depth instead of declaring it. Two attempted fixes are
recorded here, both of which regressed another title; a third section at the end records what
finally worked and which premise in this document was wrong. The write-up of the fix lives in
[Four N-Gage titles on the N70](./n70-eka1-exec-and-framebuffer-depth.md).

## Symptom

Nokia 6680 (rm-36, `epoc80`) → *Sky Force Reloaded*. The game runs at 32 FPS but draws every frame
as fine vertical blue/magenta stripes, about twice as wide as they should be, with the menu running
off the right edge.

## What is actually going on

Sampling one horizontal run of the screenshot shows the value peaks repeat every two guest pixels,
alternating blue-heavy and red-heavy: 32-bit pixels being consumed as pairs of 16-bit ones.

Dumping the direct screen access chunk and rendering it at both depths is the decisive measurement,
and it has to be done for more than one game:

| game | chunk contents | second half of chunk | coherent as |
|---|---|---|---|
| 黄泉道 | — | — | 16bpp (breaks at 32) |
| Sky Force | `f0 07 …` | untouched `0xff` fill | tight RGB565, `w*2` stride |
| Sky Force Reloaded | `f8 f8 f8 00 …` | fully written | 32-bit BGRX, `w*4` stride |

**On one device, in one display mode, different guests write different pixel sizes.** Neither game
asks the emulator what to use: both take the framebuffer address from `UserSvr::ScreenInfo()`, which
carries no depth, and neither queries the video-info HAL. The four `CWsScreenDevice::DisplayMode()`
calls that show up in the log come from AVKON during startup and are identical across both games.

Sky Force is the odd one out: it follows the window server's display mode, so it writes 16-bit
pixels when the emulator reports `EColor64K` and 32-bit pixels when it reports `EColor16MU`. That
makes it useless as a control — it passes under either policy and hides the disagreement.

## Attempt 1 — force the DSA transfer texture to 32-bit (regressed Sky Force)

`update_screen()` in `dispatch/screen.cpp` builds its transfer texture from `scr->disp_mode`. Since
`create_screen_buffer_for_dsa()` allocates the chunk as `w * h * 4` and every pitch in
`update_screen()` already assumes four bytes per pixel, hardcoding the texture to 32-bit looks
principled.

It fixes Reloaded. It also regresses the original Sky Force into a double-width, confetti-coloured
mess, because that game was writing 16-bit pixels under the then-current `EColor64K` report.

## Attempt 2 — honour the device's declared window mode (regressed 黄泉道)

`z:\rm-36\system\data\wsini.ini` says `WINDOWMODE COLOR16MU` — 32-bit — while `window.cpp` clamped
any EKA1 mode deeper than 16 bits down to `EColor64K`. Removing the clamp makes `scr->disp_mode`
agree with the ROM, and both Sky Force titles then render correctly (Reloaded because the texture
becomes 32-bit, Sky Force because it follows the report and switches to 32-bit too).

It regresses **黄泉道**, which hardcodes 16-bit writes into the DSA framebuffer regardless of what
the window server reports: its screen collapses to black with tiny red/cyan-fringed sprite fragments
and a stretched ground band. Reverted in favour of the pre-existing behaviour.

Note `WINDOWMODE` describes the mode WSERV composes in. It is not evidence about the format of the
physical framebuffer that `UserSvr::ScreenInfo()` hands to DSA clients, which is what these games
write into — that conflation is what made attempt 2 look justified.

## Attempt 3 — measure what the guest writes (this is the one that worked)

The paragraph that used to stand here proposed recording the `TDisplayMode` the guest passes to
scdv's `CFbsDrawDevice::NewScreenDeviceL`, on the premise that EKA2L1 neither implements nor
intercepts that export. **That premise is wrong.** `scdv_v81a.dll` is installed as a patch DLL for
these devices, and with `log-filter: "*:trace"` its `RDebug` lines ("A new 16 bit screen device has
been instantiated") appear in the emulator log. Driving all three titles past that call shows the
argument is simply a copy of whatever mode the window server reported — 16-bit under the clamp,
24-bit unsigned byte without it — for 黄泉道 as much as for the two Sky Force titles. It is a mirror
of the report, so it carries no independent information and cannot separate them.

What does separate them is the chunk itself, which is always allocated for 32-bit pixels and handed
to the guest pre-filled with `0xFF`. A 16-bit writer only ever touches the first `w * h * 2` bytes.
`epoc::screen` now keeps `dsa_disp_mode` alongside `disp_mode`: the declared mode drives every
guest-visible surface, while the DSA upload starts at 16 bits on EKA1 devices that declare more and
widens to the declared mode the first frame anything appears past the halfway mark. The marker is
repainted when a new client takes direct screen access, and `sync_screen_buffer_data()` writes back
at the measured depth so the emulator cannot fabricate its own evidence.

With that in place the clamp on `disp_mode` is gone — which is what the N70 titles needed — and
Sky Force Reloaded renders correctly while 黄泉道 stays pixel-identical to the clamped build.

## Verification notes

- The automated suites cannot catch any of this: the standard suite covers Final Battle, Calculator
  and the N95 Calculator, and angrybirds covers the X7 — **all EKA2 devices**. Both attempts passed
  12/12 and 5/5 while regressing a 6680 title. Anything touching the EKA1 screen path has to be
  driven per-app on the 6680 by hand.
- 6680 apps worth checking: 黄泉道, Tetris3D, skyforce, Ashen, Asphalt 2, skyforcereloaded,
  dragonworld, X-plore. `-LaunchAppUID` does not work for all of them (Sky Force's `0x10105B92` is
  silently ignored); drive them with `xcodebuildmcp ui-automation snapshot-ui` then
  `tap --elementRef`, taking the snapshot and the tap in the *same* invocation because refs go stale.
- Tetris3D's garbled strip below the help text is pre-existing; it reproduces identically on an
  unmodified build.
- A probe that fails to compile leaves the previous binary installed, and "the log shows nothing"
  then looks exactly like a real answer. Two conclusions here — "`update_screen` is never called"
  and "the game creates no bitmaps" — were both artifacts of a build error in the probe itself.
