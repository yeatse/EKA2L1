// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#import "IosEmulator.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <common/cvt.h>
#include <common/fileutils.h>
#include <common/log.h>
#include <common/path.h>
#include <common/version.h>
#include <config/app_settings.h>
#include <config/config.h>
#include <drivers/graphics/backend/emu_window_ios.h>
#include <drivers/graphics/graphics.h>
#include <drivers/input/common.h>
#include <package/manager.h>
#include <services/applist/applist.h>
#include <services/window/window.h>
#include <system/devices.h>
#include <system/epoc.h>

@implementation EKA2L1AppEntry
@end

namespace eka2l1::ios {
    // C++ side of the iOS emulator state. Lives behind the Obj-C facade
    // EKA2L1Emulator so SwiftUI never sees the C++ types directly.
    //
    // Stage-2 scope (see IOS_PORTING_TASKS.md): no audio, sensor, vibration
    // or camera drivers — those land in stage 3. This struct only wires what
    // is needed for "select ROM → applist scan → launch app → render → tap".
    struct emulator {
        std::unique_ptr<eka2l1::system> symsys;
        std::unique_ptr<config::app_settings> settings;
        std::unique_ptr<drivers::emu_window_ios> window;
        drivers::graphics_driver_ptr graphics_driver;

        config::state conf;
        window_server *winserv = nullptr;
        std::string documents_root;

        std::atomic<bool> running{false};
        std::atomic<bool> paused{false};

        std::mutex layer_mutex;
        void *pending_layer = nullptr;
        std::uint32_t pending_width = 0;
        std::uint32_t pending_height = 0;
        float pending_scale = 1.0f;
    };
}

@implementation EKA2L1Emulator {
    std::unique_ptr<eka2l1::ios::emulator> _state;
}

+ (instancetype)shared {
    static EKA2L1Emulator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[EKA2L1Emulator alloc] init];
    });
    return instance;
}

- (BOOL)startWithDocumentsPath:(NSString *)documentsPath {
    if (_state && _state->running) {
        return YES;
    }

    _state = std::make_unique<eka2l1::ios::emulator>();
    _state->documents_root = documentsPath.UTF8String;

    // Build the sandbox layout up front so later steps can rely on it.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *subdirs = @[@"roms", @"data", @"sis",
                                      @"data/drives/c", @"data/drives/d",
                                      @"data/drives/e", @"data/drives/z",
                                      @"data/compat"];
    for (NSString *sub in subdirs) {
        NSString *path = [documentsPath stringByAppendingPathComponent:sub];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Run the emulator with cwd = Documents/data so the config / drive paths
    // resolve into the sandbox rather than the (read-only) bundle.
    NSString *dataRoot = [documentsPath stringByAppendingPathComponent:@"data"];
    chdir(dataRoot.UTF8String);

    eka2l1::log::setup_log(nullptr);
    LOG_INFO(eka2l1::FRONTEND_CMDLINE, "EKA2L1 iOS v0.0.1 ({}-{})", GIT_BRANCH, GIT_COMMIT_HASH);

    _state->conf.deserialize();
    _state->conf.storage = dataRoot.UTF8String;
    _state->settings = std::make_unique<eka2l1::config::app_settings>(&_state->conf);

    eka2l1::system_create_components comp;
    comp.audio_ = nullptr;
    comp.graphics_ = nullptr;
    comp.conf_ = &_state->conf;
    comp.settings_ = _state->settings.get();

    _state->symsys = std::make_unique<eka2l1::system>(comp);
    _state->window = std::make_unique<eka2l1::drivers::emu_window_ios>();

    _state->running = true;
    return YES;
}

- (void)shutdown {
    if (!_state) {
        return;
    }
    _state->running = false;
    _state->graphics_driver.reset();
    _state->symsys.reset();
    _state->window.reset();
    _state->settings.reset();
    _state.reset();
}

- (NSArray<NSString *> *)availableRoms {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (!_state) {
        return out;
    }
    NSString *romsRoot = [@(_state->documents_root.c_str()) stringByAppendingPathComponent:@"roms"];
    NSError *err = nil;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:romsRoot error:&err];
    for (NSString *entry in entries) {
        BOOL isDir = NO;
        NSString *full = [romsRoot stringByAppendingPathComponent:entry];
        if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [out addObject:entry];
        }
    }
    return out;
}

- (BOOL)mountRomNamed:(NSString *)romName {
    // Implementation lands in task 2.6 (ROM mount & applist scan).
    (void)romName;
    return NO;
}

- (NSArray<EKA2L1AppEntry *> *)rescanApps {
    // Implementation lands in task 2.6.
    return @[];
}

- (BOOL)launchAppWithUID:(uint32_t)uid {
    // Implementation lands in task 2.6.
    (void)uid;
    return NO;
}

- (BOOL)installSisAtPath:(NSString *)sisPath {
    // Stage 3 plugs in UIDocumentPicker; stage 2 leaves manual file copy.
    (void)sisPath;
    return NO;
}

- (void)attachLayer:(CAEAGLLayer *)layer
         pixelSize:(CGSize)pixelSize
              scale:(CGFloat)scale {
    if (!_state || !_state->window) {
        return;
    }
    _state->window->surface_changed((__bridge void *)layer,
        static_cast<int>(pixelSize.width),
        static_cast<int>(pixelSize.height),
        static_cast<float>(scale));
    // graphics_driver bootstrap and per-frame loop land in task 2.9.
}

- (void)pause {
    if (!_state) return;
    _state->paused = true;
}

- (void)resume {
    if (!_state) return;
    _state->paused = false;
}

- (void)submitPointerEventAtX:(CGFloat)x
                            y:(CGFloat)y
                        phase:(EKA2L1PointerPhase)phase
                    pointerId:(uintptr_t)pointerId {
    // Real dispatch into window_server lands in task 2.8.
    (void)x; (void)y; (void)phase; (void)pointerId;
}

@end
