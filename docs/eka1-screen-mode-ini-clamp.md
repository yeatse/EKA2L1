# Clamping EKA1 screens to 64K colours desynced the emulator from the device's own graphics stack

## Symptom

Nokia 6680 (rm-36, `epoc80`) → *Sky Force Reloaded*.

Once the game gets past [the debug write command bug](./debug-command-write-descriptor-bound.md)
it runs at a healthy 32 FPS, but every frame is a mess of fine vertical blue/magenta stripes,
roughly twice as wide as it should be, with the menu running off the right edge.

The original *Sky Force* on the same device renders perfectly. Both are Infinite Dreams titles,
both take the direct screen access path, both are 176x208.

## Narrowing down

### Measure the artifact first

Sampling one horizontal run of the screenshot shows the peaks repeat every ~13.7 screenshot pixels.
The guest screen is 176 px drawn across 1206 px, so one guest pixel is 6.85 px: the period is
exactly **two guest pixels**, alternating blue-heavy and red-heavy. Two output pixels per unit of
source data, each carrying different channels, is 32-bit pixels being consumed as pairs of 16-bit
ones.

### Dump the framebuffer instead of guessing

Writing the raw DSA chunk to a file and rendering it both ways is decisive, and worth doing for
*both* games:

| | bytes | second half of the chunk | coherent as |
|---|---|---|---|
| Sky Force | `f0 07 …` | untouched `0xff` fill | tight RGB565, `w*2` stride |
| Sky Force Reloaded | `f8 f8 f8 00 …` | fully written | 32-bit BGRX, `w*4` stride |

So on one device, in one display mode, the two games write **different pixel sizes**. That kills
any fix that hard-codes the transfer texture's depth — and it is exactly the trap to avoid here.
Making the DSA texture unconditionally 32-bit does fix Reloaded, and passes both the standard
(12/12) and angrybirds (5/5) suites, because **neither suite covers the 6680** — while silently
regressing the original Sky Force into a double-width, confetti-coloured mess.

### Neither game asks

Probing every channel that reports a display mode shows the game calls `UserSvr::ScreenInfo()`
seven times — which carries the framebuffer address and size but no depth — and never queries the
video-info HAL. The four `CWsScreenDevice::DisplayMode()` calls in the log come from AVKON during
startup, and appear identically in both games' runs. `sync_screen_buffer_data()` is not the source
either: it runs once, before the game starts, while the chunk is still the pristine `0xff` fill.

### The device already declares its mode

The answer is in the ROM. `z:\rm-36\system\data\wsini.ini` says:

```
WINDOWMODE COLOR16MU
```

32-bit. That is what the 6680's own graphics stack composes in, and the ROM's `CFbsDrawDevice`
duly writes 32-bit pixels into the framebuffer. But `window.cpp` overrode it:

```cpp
scr_mode_global = epoc::string_to_display_mode(modes[0]);
// It seems to be so!!! Since games still use metainfo hacks at the beginning of screen buffer
if (kern->is_eka1() && (epoc::get_bpp_from_display_mode(scr_mode_global) > 16)) {
    scr_mode_global = epoc::display_mode::color64k;
}
```

The ROM never learns about that clamp. So the guest's graphics stack ran at 32 bits while the
emulator composited, read back and uploaded the same memory at 16 — and `update_screen()` created
its transfer texture from the clamped mode.

## Fix

Delete the clamp and take the mode the device's own `wsini.ini` declares. `scr->disp_mode` then
agrees with the ROM, `update_screen()` builds a 32-bit transfer texture, and both games render.

Sky Force renders correctly either way, which is the useful part: it does not hard-code 16 bits,
it follows the window server's display mode, so it writes 16-bit pixels when the emulator claims
`EColor64K` and 32-bit pixels once the emulator stops lying. Only the clamp made the two games
disagree.

The blast radius is small and checkable. Of the installed devices only the 6680 is affected: the
N-Gage (`nem-4`) declares `COLOR64K`, so the clamp never fired for it — and being `epoc6` it takes
the ROM-header branch above rather than the ini branch anyway — and every other device
(`rm-320`, `rm-409`, `rm-507`, `rm-707`) is EKA2, where `is_eka1()` is false. The unrelated
`epoc6` ROM-header path that maps a 12bpp header to `EColor64K` (the N-Gage X-Plore
zero-byte-surface fix) is untouched.

## Worth remembering

A probe that fails to compile leaves the previous binary installed, and "the log shows nothing"
then looks exactly like a real answer. Two conclusions in this investigation — "`update_screen` is
never called" and "the game creates no bitmaps" — were both artifacts of a build error in the probe
itself. Check the build result before trusting silence.
