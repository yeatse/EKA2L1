# iOS Metal acceleration via ANGLE (GLES → Metal)

**Core conclusion:** keep EKA2L1's existing GLES command-list renderer and run it on
ANGLE's Metal backend through EGL. This hardware-accelerates **both the iOS
Simulator and the device** with no rewrite of the renderer, behind a build flag
with the existing EAGL/GLES path as fallback. Route chosen 2026-06-15 over a
native Metal backend (weeks, ~5k LOC) and MoltenVK/Vulkan (largest effort).

## Why (motivation)

Snakes 3D is render-fence-bound in the Simulator (see
[ios_snakes_perf.md](ios_snakes_perf.md)): Apple's GLES in the Simulator is
**software** (`GLRendererFloat` / `gldRenderFillTriangles`), capping ~38 FPS and
masking every CPU-side interpreter win. **Metal runs hardware-accelerated in the
iOS Simulator** (on the Mac GPU), so an ANGLE-Metal path:
- makes the Simulator hardware-accelerated → unblocks FPS measurement + a realistic
  dev loop;
- future-proofs against Apple's GLES deprecation;
- sheds some GLES driver overhead on device.

Honest benefit split: **Simulator = large**; **device = modest/neutral** (EAGL GLES
is already GPU-accelerated there) — device value is mostly future-proofing.

## Architecture facts this plan relies on

- One functional backend: `graphic_api::opengl`, a GLES command-list interpreter
  (`src/emu/drivers/src/graphics/backend/ogl/*`, ~4.9k LOC). Vulkan backend is an
  empty stub. **ANGLE keeps all of this unchanged** — no new `graphic_api` enum,
  no driver-selection plumbing.
- GPU context is abstracted behind `gl_context` (`drivers/graphics/context.h`:
  `make_current` / `swap_buffers` / `update` / `swapchain_framebuffer` /
  `create_shared_context`). iOS today = `gl_context_eagl` (EAGLContext +
  `CAEAGLLayer` + `presentRenderbuffer:`).
- Android already has an **EGL** context (`context_egl.cpp`:
  `eglGetDisplay`/`eglCreateContext`/`eglCreateWindowSurface`/`eglSwapBuffers`) —
  ANGLE exposes exactly this API, so the iOS ANGLE context is largely an
  adaptation of it.
- iOS `UIView` hard-declares `layerClass = CAEAGLLayer`
  (`EmulatorViewController.swift`), handed to the bridge via `attachLayer:`. ANGLE-
  Metal needs a `CAMetalLayer` as the EGL native window.
- The driver-side double-buffered present (`present_status` fences in
  `IosEmulator.mm`) is backend-agnostic and stays as-is.

## Phased plan (each phase has a gate)

**Phase 0 — Spike / de-risk — ✅ DONE (2026-06-15, simulator).** Vendored
**MetalANGLE `gles3-0.0.8`** (prebuilt; sourced + repackaged by
`scripts/fetch_metalangle.sh`). A surfaceless GLES3 `MGLContext` smoke
(`src/emu/ios/Bridge/AngleSmoke.mm`, gated by `EKA2L1_IOS_USE_ANGLE`) running in
the booted iOS 26.5 simulator reported:

> `vendor='Google Inc.'  renderer='ANGLE (Metal Renderer: Apple iOS simulator GPU)'  version='OpenGL ES 3.0.0 (ANGLE 2.1.0.850c87ba5b74)'`

i.e. GLES 3.0 on **hardware Metal in the simulator** — premise de-risked. Two
gotchas solved and captured in the fetch script / CMake: (1) the upstream arm64
*simulator* slice ships the legacy `LC_VERSION_MIN_IPHONEOS` load command so dyld
rejects it — fixed by `vtool -set-build-version 7 (iOS-Simulator)`; (2) the
embedded framework needs `@executable_path/Frameworks` on the app rpath. Device
slice (`ios-arm64`) is packaged but device-launch confirmation is deferred to
Phase 4. **Gate (sim): met.**

**Phase 1 — Dependency integration.** Vendor ANGLE as an xcframework (device-arm64
+ sim-arm64), embedded + signed. CMake/`scripts/build_ios.sh` flag
`EKA2L1_IOS_USE_ANGLE` (default OFF). **Gate:** app links both slices; binary-size
delta recorded.

**Phase 2 — Context + surface.** _Driver side ✅ (commit `84196e10c`):_
`gl_context_angle` (`src/emu/drivers/src/graphics/backend/context_angle.{h,mm}`)
backed by MetalANGLE's `MGLContext` + `MGLLayer` — MGL owns the default FBO,
depth/stencil and present, so `swapchain_framebuffer()` returns
`MGLLayer.defaultOpenGLFrameBufferID`. `make_gl_context` selects it when
`EKA2L1_IOS_ANGLE` is defined; the option moved to the root CMake so the `drivers`
lib gets the define + `-F` header path. It only adopts `render_surface` if it
`isKindOfClass:MGLLayer` (else headless), so an enabled build is crash-safe before
the view is switched. _Remaining:_ the frontend still hands a `CAEAGLLayer`; host
an `MGLLayer` for rendering (planned: create/own it in the ObjC++ bridge under
`#ifdef EKA2L1_IOS_ANGLE` and pass it as `render_surface` — avoids Swift/MetalANGLE
module-map friction), resize it on layout, route the present. **Gate:**
Snakes/Calculator render via ANGLE in the sim.

**Phase 3 — Shader/feature parity.** Verify GLSL-ES shaders + upscale shaders
(`resources/gles`, `resources/upscale`) compile through ANGLE's translator; check
resize (`update`/`update_surface`), viewport, framebuffer bind, texture formats
(incl. PVRTC path). **Gate:** `scripts/ios_regression_test.sh` 8/8 on ANGLE.

**Phase 4 — Measure + decide.** Snakes FPS A/B (overlay-crop method) ANGLE vs EAGL
in the sim — expect a real jump now that rendering is hardware, and the CPU work
(block-cursor etc.) should finally surface. Verify on iPhone Air (needs unlocked
device + visual confirmation; device can't be screenshotted via CLI). **Gate:** sim
FPS materially up, device non-regressed; keep ANGLE behind the flag until device-
confirmed, then flip the default.

## Risks / watch-items
ANGLE shader-translator edge cases; EGL config selection; present/vsync semantics
vs `CAEAGLLayer` (implicitly vsynced); embedded-dylib code signing; App Store binary
size. All testable behind the flag, EAGL/GLES always available as fallback.
