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

// An installed Symbian device (firmware). `index` matches device_manager's
// ordering so it can be passed straight back to bootDeviceAtIndex:.
@interface EKA2L1DeviceEntry : NSObject
@property(nonatomic, assign) NSUInteger index;
@property(nonatomic, copy) NSString *firmwareCode;
@property(nonatomic, copy) NSString *manufacturer;
@property(nonatomic, copy) NSString *model;
@end

// Mirrors eka2l1::device_installation_error 1:1, plus an iOS-only `NeedRpkg`
// case the bridge raises when a ROM dump requires an additional RPKG file but
// none was supplied. Frontend maps these to the Android-sourced strings.
typedef NS_ENUM(NSInteger, EKA2L1InstallResult) {
    EKA2L1InstallResultSuccess = 0,
    EKA2L1InstallResultNotExist,
    EKA2L1InstallResultInsufficient,
    EKA2L1InstallResultRpkgCorrupt,
    EKA2L1InstallResultDetermineProductFailure,
    EKA2L1InstallResultAlreadyExist,
    EKA2L1InstallResultGeneralFailure,
    EKA2L1InstallResultRomFailToCopy,
    EKA2L1InstallResultVplInvalid,
    EKA2L1InstallResultRofsCorrupt,
    EKA2L1InstallResultRomCorrupt,
    EKA2L1InstallResultFpsxCorrupt,
    EKA2L1InstallResultNeedRpkg,
};

@interface EKA2L1Emulator : NSObject

+ (instancetype)shared;

// Lifecycle ----------------------------------------------------------------
// Initialise the underlying eka2l1::system using the Documents directory at
// `documentsPath`. Creates roms/, data/, sis/ subfolders if missing.
- (BOOL)startWithDocumentsPath:(NSString *)documentsPath;

// Tear the system down. Called from the SwiftUI shutdown path.
- (void)shutdown;

// Devices + applist -------------------------------------------------------
// List installed Symbian devices (from device_manager). Empty until the user
// installs one via installDeviceWithRomPath:rpkgPath:.
- (NSArray<EKA2L1DeviceEntry *> *)installedDevices;

// Index of the currently-booted device, or -1 if none is booted yet.
- (NSInteger)currentDeviceIndex;

// Install a device from a raw ROM dump (and optionally an RPKG file). Mirrors
// the Android launcher::install_device path: install_rpkg when the ROM needs
// it, else install_rom. Writes into the sandbox storage and persists
// devices.yml. Does NOT boot the device — call bootDeviceAtIndex: after.
- (EKA2L1InstallResult)installDeviceWithRomPath:(NSString *)romPath
                                       rpkgPath:(nullable NSString *)rpkgPath
    NS_SWIFT_NAME(installDevice(romPath:rpkgPath:));

// Boot a previously-installed device by index: (re)builds the system, sets
// the device, mounts drives, binds the graphics driver. Returns YES on
// success.
- (BOOL)bootDeviceAtIndex:(NSUInteger)index;

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
              scale:(CGFloat)scale NS_SWIFT_NAME(attach(layer:pixelSize:scale:));

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
	                    pointerId:(uintptr_t)pointerId NS_SWIFT_NAME(submitPointer(x:y:phase:pointerId:));

- (void)submitRawKey:(uint32_t)scanCode pressed:(BOOL)pressed;
- (void)tapRawKey:(uint32_t)scanCode;

- (NSDictionary<NSString *, id> *)currentConfigSnapshot;
- (BOOL)applyConfigSnapshot:(NSDictionary<NSString *, id> *)snapshot;
- (void)testVibration;

// 3.6: decode an app's registered icon (MIF / MBM / NVG / SVGB / SVG)
// and return a square RGBA PNG sized `sizePx` per side. Returns nil if
// the registration has no icon or all decode attempts fail. Safe to
// call from a background queue; SwiftUI consumes the NSData via
// `UIImage(data:)`.
- (nullable NSData *)iconPNGDataForUID:(uint32_t)uid sizePx:(NSUInteger)sizePx;

@end

NS_ASSUME_NONNULL_END
