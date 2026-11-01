# Direct screen bitmap region semantics (Belle)

This module replaces only scdv.dll's CDirectScreenBitmap constructors on epoc100.
The existing scdv patch still supplies the draw-device exports. Patch maps may
name a common `target`, and all matching non-overlapping routes are applied.

`Create(rect)` defines the returned bitmap's local origin and size. `EndUpdate`
rectangles remain absolute screen coordinates. See SymbianSource's
`graphicsdeviceinterface/screendriver/tsrc/TDirectScreenBitmap.cpp`, particularly
CCommonInterfaces::DrawColor, and the partner `inc/cdsb.h` contract. The prior
implementation discarded Create's rectangle and returned the HAL panel size,
which remains portrait when the current mode is landscape.

The source builds with hpnkv/symbian-platform v0.3.0 on Linux. Configure this
folder with its cmake/symbian-arm.cmake toolchain, SYMBIAN_SDK_PREFIX, Release,
and its bundled Ninja, then build. Copy scdv_cdsb_general.dll into group/.
Alternatively EKA2L1_BUILD_PATCH=ON with EKA2L1_SYMBIAN_SDK_PREFIX uses that build
for this module; existing modules retain their legacy Symbian SDK build path.
Normal emulator builds use the checked-in prebuilt (SHA-256
598847d6a71abc2a0c38d5cf7664427df9e93e66d46bc94f77ea95b2e7bc65ea).

On X7, a guest Create(640x360) / BeginUpdate now reports 640x360 rather than
360x640. The installer eventually uses ordinary window/bitmap APIs, so it does
not depend on this patch or add a private emulator dispatch dependency.
