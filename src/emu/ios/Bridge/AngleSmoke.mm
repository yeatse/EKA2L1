// Phase-0 ANGLE-Metal spike.
//
// Compiled only when EKA2L1_IOS_USE_ANGLE is ON. Proves that MetalANGLE
// (GLES -> Metal) initializes and runs on the GPU in the iOS Simulator (and on
// device): it creates a surfaceless GLES3 context via MetalANGLE's MGLContext,
// queries the GL strings, and logs GL_VENDOR / GL_RENDERER / GL_VERSION to both
// NSLog and Documents/angle_smoke.txt so the result is readable from the app
// container. A Metal renderer string here is the de-risk signal for the
// ANGLE-over-Metal route (see docs/ios_metal_angle_plan.md).
//
// This file is intentionally self-contained and side-effect-free w.r.t. the
// emulator: it only runs a one-shot diagnostic shortly after launch.

#import <Foundation/Foundation.h>

#import <MetalANGLE/MGLContext.h>
#import <MetalANGLE/GLES3/gl3.h>

static void eka2l1_ios_angle_smoke(void) {
    @autoreleasepool {
        MGLContext *ctx = [[MGLContext alloc] initWithAPI:kMGLRenderingAPIOpenGLES3];
        if (!ctx) {
            NSLog(@"ANGLE_SMOKE: FAILED to create MGLContext");
            return;
        }
        // Surfaceless make-current: MetalANGLE supports a current context with no
        // presentation layer (used here just to query the renderer).
        if (![MGLContext setCurrentContext:ctx]) {
            NSLog(@"ANGLE_SMOKE: FAILED setCurrentContext");
            return;
        }

        const GLubyte *vendor = glGetString(GL_VENDOR);
        const GLubyte *renderer = glGetString(GL_RENDERER);
        const GLubyte *version = glGetString(GL_VERSION);

        NSString *info = [NSString stringWithFormat:
            @"ANGLE_SMOKE: OK vendor='%s' renderer='%s' version='%s'",
            vendor ? (const char *)vendor : "?",
            renderer ? (const char *)renderer : "?",
            version ? (const char *)version : "?"];
        NSLog(@"%@", info);

        NSArray<NSString *> *docs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count) {
            NSString *path = [docs[0] stringByAppendingPathComponent:@"angle_smoke.txt"];
            [info writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        [MGLContext setCurrentContext:nil];
    }
}

__attribute__((constructor)) static void eka2l1_ios_angle_smoke_register(void) {
    // Defer slightly so the run loop / Metal stack are up before we poke them.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            eka2l1_ios_angle_smoke();
        });
}
