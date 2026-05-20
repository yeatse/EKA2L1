// Stage-0 implementation. The only job here is to import a real symbol from
// the EKA2L1 core libraries so the linker keeps them in the final bundle
// even though the SwiftUI shell does not yet drive the emulator. Replace the
// probe with real bridge entry points (launcher, state, emu_window, ...) in
// stage 2.

#import <Foundation/Foundation.h>

#include "StartupBridge.h"

#include <common/version.h>

namespace {
    // Touch a function from common so the static library is dragged into the
    // bundle. Returning the version string also gives the SwiftUI shell
    // something tangible to display.
    const char *build_banner() {
        static NSString *cached = [NSString stringWithFormat:
            @"EKA2L1 iOS stage-0 · %s@%s",
            GIT_BRANCH, GIT_COMMIT_HASH];
        return cached.UTF8String;
    }
}

extern "C" const char *EKA2L1StartupProbe(void) {
    return build_banner();
}
