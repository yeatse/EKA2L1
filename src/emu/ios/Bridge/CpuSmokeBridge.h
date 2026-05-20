// Stage-1 CPU smoke bridge. Constructs a dyncom arm::core, runs the small
// A32 blob in CpuSmokeBlob.h, and surfaces a structured result the SwiftUI
// shell can render. The bridge owns nothing across calls -- each invocation
// builds and tears down its own core, page buffer, and callbacks.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Mirrors arm::arm_emulator_type but kept narrow on purpose: stage 1 only
// exposes the two values the SwiftUI shell needs to talk about.
typedef NS_ENUM(NSInteger, EKA2L1SmokeBackend) {
    EKA2L1SmokeBackendDyncom = 0,
    EKA2L1SmokeBackendDynarmic = 1,
};

@interface EKA2L1CpuSmokeResult : NSObject
@property (nonatomic, assign) EKA2L1SmokeBackend requestedBackend;
@property (nonatomic, assign) EKA2L1SmokeBackend resolvedBackend;
@property (nonatomic, copy, nullable) NSString *fallbackReason;  // nil if no downgrade happened
@property (nonatomic, assign) BOOL pass;
@property (nonatomic, assign) uint32_t instructionsExecuted;
// 13 NSNumber<uint32_t> for r0..r12 captured at exception time.
@property (nonatomic, copy) NSArray<NSNumber *> *registers;
@property (nonatomic, assign) uint32_t pc;
@property (nonatomic, assign) uint32_t sp;
@property (nonatomic, assign) uint32_t lr;
@property (nonatomic, assign) uint32_t cpsr;
// Multi-line diff string when pass==NO; nil when pass==YES.
@property (nonatomic, copy, nullable) NSString *diff;
@end

@interface EKA2L1CpuSmokeBridge : NSObject
// Runs the blob with the requested backend. Resolution happens via
// arm::resolve_emulator_type so a request that the host cannot honor
// (e.g. dynarmic on iOS in stage 1) is downgraded with a recorded
// reason. Safe to call from any thread; performs blocking work and
// is intended to be invoked off the main thread.
+ (EKA2L1CpuSmokeResult *)runWithBackend:(EKA2L1SmokeBackend)backend;
@end

NS_ASSUME_NONNULL_END
