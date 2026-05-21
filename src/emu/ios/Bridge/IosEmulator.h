// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Obj-C facade for the iOS-side emulator state. Mirrors the role
// `eka2l1::android::emulator` plays for the Android frontend but trimmed to
// stage-2 scope: no audio (cubeb absent), no sensors / camera / vibration,
// no SIS-install UI. Implemented on top of the C++ `eka2l1::ios::emulator`
// in IosEmulator.mm.

#import <Foundation/Foundation.h>
#import <QuartzCore/CAEAGLLayer.h>

NS_ASSUME_NONNULL_BEGIN

@interface EKA2L1AppEntry : NSObject
@property(nonatomic, assign) uint32_t uid;
@property(nonatomic, copy) NSString *name;
@end

@interface EKA2L1Emulator : NSObject

+ (instancetype)shared;

// Lifecycle ----------------------------------------------------------------
// Initialise the underlying eka2l1::system using the Documents directory at
// `documentsPath`. Creates roms/, data/, sis/ subfolders if missing.
- (BOOL)startWithDocumentsPath:(NSString *)documentsPath;

// Tear the system down. Called from the SwiftUI shutdown path.
- (void)shutdown;

// ROM + applist -----------------------------------------------------------
// Scan `<Documents>/roms` for sub-directories; each one is a candidate ROM
// folder. Returns folder names (e.g. "N95 8GB (S60v3 - FP1)").
- (NSArray<NSString *> *)availableRoms;

// Pick a ROM folder by name and mount it. Returns YES on success.
- (BOOL)mountRomNamed:(NSString *)romName;

// Trigger applist rescan + return the resulting (uid, name) list.
- (NSArray<EKA2L1AppEntry *> *)rescanApps;

// Launch a previously-listed app.
- (BOOL)launchAppWithUID:(uint32_t)uid;

// SIS install (stub for stage 2 acceptance, implementation in 2.6).
- (BOOL)installSisAtPath:(NSString *)sisPath;

// Render surface / lifecycle ----------------------------------------------
// Frontend hands the EAGLView's CAEAGLLayer here. Called from
// viewDidLayoutSubviews so re-orientation is handled.
- (void)attachLayer:(CAEAGLLayer *)layer
         pixelSize:(CGSize)pixelSize
              scale:(CGFloat)scale;

- (void)pause;
- (void)resume;

// Input -------------------------------------------------------------------
// Single-touch dispatch from EAGLView (task 2.8).
typedef NS_ENUM(NSInteger, EKA2L1PointerPhase) {
    EKA2L1PointerPhaseBegan = 0,
    EKA2L1PointerPhaseMoved = 1,
    EKA2L1PointerPhaseEnded = 2,
    EKA2L1PointerPhaseCancelled = 3,
};

- (void)submitPointerEventAtX:(CGFloat)x
                            y:(CGFloat)y
                        phase:(EKA2L1PointerPhase)phase
                    pointerId:(uintptr_t)pointerId;

@end

NS_ASSUME_NONNULL_END
