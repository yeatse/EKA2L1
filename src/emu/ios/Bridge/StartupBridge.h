// Minimal C-callable bridge between the SwiftUI shell and the EKA2L1 core
// static libraries. Stage-0 only exposes a single probe so we can verify the
// link graph end to end; subsequent stages will add launcher / state /
// emu_window / input_dialog symbols mirroring the Android JNI bridge under
// src/emu/android/app/src/main/cpp/.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Returns a NUL-terminated string owned by the bridge describing the linked
// EKA2L1 build. Safe to call from any thread; pointer stays valid for the
// lifetime of the process. Returns nullptr only if the bridge has not been
// initialized (currently it always returns a static literal).
const char *EKA2L1StartupProbe(void);

#ifdef __cplusplus
}
#endif
