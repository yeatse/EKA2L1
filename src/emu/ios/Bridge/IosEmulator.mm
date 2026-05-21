// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#import "IosEmulator.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <exception>
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
#include <drivers/itc.h>
#include <services/window/screen.h>
#include <kernel/kernel.h>
#include <package/manager.h>
#include <services/applist/applist.h>
#include <services/window/window.h>
#include <system/devices.h>
#include <system/epoc.h>
#include <utils/apacmd.h>

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
        // symsys->loop() must not run before mountRomNamed: completes —
        // kernel_system::crr_thread() dereferences a null thread_scheduler
        // otherwise. The os_thread idles until this flips true.
        std::atomic<bool> mounted{false};

        // Frame loop / lifecycle (task 2.9). Two threads sit behind the
        // singleton — one feeds drivers::graphics_driver::run() (must own
        // the EAGL context), the other ticks symsys->loop().
        std::unique_ptr<std::thread> os_thread;
        std::unique_ptr<std::thread> graphics_thread;

        std::mutex layer_mutex;
        std::condition_variable layer_cv;
        bool layer_dirty = false;
        void *pending_layer = nullptr;
        std::uint32_t pending_width = 0;
        std::uint32_t pending_height = 0;
        float pending_scale = 1.0f;

        std::vector<std::size_t> screen_redraw_handles;
        int present_status = 0;
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

    auto *state = _state.get();
    _state->graphics_thread = std::make_unique<std::thread>([state]() {
        // Wait for the EAGLView to publish its CAEAGLLayer; the EAGL context
        // can't be created without a drawable. attachLayer:pixelSize:scale:
        // flips layer_dirty under layer_mutex.
        std::unique_lock<std::mutex> lock(state->layer_mutex);
        state->layer_cv.wait(lock, [state]() {
            return !state->running || state->pending_layer != nullptr;
        });
        if (!state->running) {
            return;
        }
        state->window->surface_changed(state->pending_layer, state->pending_width,
            state->pending_height, state->pending_scale);
        state->layer_dirty = false;
        lock.unlock();

        // Build the graphics driver on this thread so the EAGL context is
        // current here. The OGL driver's run() loop owns the thread until
        // the symsys / driver tear down.
        state->graphics_driver = eka2l1::drivers::create_graphics_driver(
            eka2l1::drivers::graphic_api::opengl,
            state->window->get_window_system_info());
        if (!state->graphics_driver) {
            LOG_ERROR(eka2l1::DRIVER_GRAPHICS, "iOS graphics driver creation failed");
            return;
        }
        state->symsys->set_graphics_driver(state->graphics_driver.get());

        state->window->surface_change_hook = [state](void *new_surface) {
            state->graphics_driver->update_surface(new_surface);
        };
        state->graphics_driver->set_display_hook([]() {
            // CAEAGLLayer presentation is implicit in gl_context_eagl::
            // swap_buffers; nothing extra to poll here. iOS lifecycle hooks
            // gate pause/resume via context::pause()/resume().
        });

        state->graphics_driver->run();
    });

    _state->os_thread = std::make_unique<std::thread>([state]() {
        while (state->running) {
            if (state->paused || !state->mounted.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(16));
                continue;
            }
            try {
                state->symsys->loop();
            } catch (std::exception &exc) {
                LOG_ERROR(eka2l1::FRONTEND_CMDLINE, "Emu loop exception: {}", exc.what());
                state->running = false;
                break;
            }
        }
    });

    return YES;
}

- (void)shutdown {
    if (!_state) {
        return;
    }
    _state->running = false;
    {
        std::lock_guard<std::mutex> lk(_state->layer_mutex);
        _state->layer_cv.notify_all();
    }
    if (_state->graphics_driver) {
        _state->graphics_driver->abort();
    }
    if (_state->os_thread && _state->os_thread->joinable()) {
        _state->os_thread->join();
    }
    if (_state->graphics_thread && _state->graphics_thread->joinable()) {
        _state->graphics_thread->join();
    }
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
    if (!_state || !_state->symsys) {
        return NO;
    }
    // ROMs that live under Documents/roms/<name>/ are expected to already be
    // a fully-extracted Symbian Z drive (i.e. a "device folder" produced by
    // the desktop installer). Stage 2 just rsyncs that tree into the Z drive
    // mount point under data/, then asks the system to rescan + pick the
    // first matching device.
    NSString *romsRoot = [@(_state->documents_root.c_str()) stringByAppendingPathComponent:@"roms"];
    NSString *romPath = [romsRoot stringByAppendingPathComponent:romName];
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:romPath isDirectory:&isDir] || !isDir) {
        return NO;
    }

    auto *sys = _state->symsys.get();
    const std::string storage = _state->conf.storage;

    // Make sure the Z mount point exists and ensure the ROM contents are
    // visible through it. We avoid copying — symlink the folder for cheap.
    NSString *zPath = [@(storage.c_str()) stringByAppendingPathComponent:@"drives/z"];
    [NSFileManager.defaultManager removeItemAtPath:zPath error:nil];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:zPath
                                       withDestinationPath:romPath
                                                     error:nil];

    sys->rescan_devices(drive_z);
    sys->startup();
    if (sys->get_device_manager()->total() == 0) {
        return NO;
    }
    sys->set_device(0);
    sys->mount(drive_c, drive_media::physical, eka2l1::add_path(storage, "/drives/c/"), io_attrib_internal);
    sys->mount(drive_d, drive_media::physical, eka2l1::add_path(storage, "/drives/d/"), io_attrib_internal);
    sys->mount(drive_e, drive_media::physical, eka2l1::add_path(storage, "/drives/e/"), io_attrib_removeable);
    sys->mount(drive_z, drive_media::rom, eka2l1::add_path(storage, "/drives/z/"),
        io_attrib_internal | io_attrib_write_protected);

    sys->initialize_user_parties();

    auto *kern = sys->get_kernel_system();
    _state->winserv = reinterpret_cast<eka2l1::window_server *>(
        kern->get_by_name<eka2l1::service::server>(
            eka2l1::get_winserv_name_by_epocver(sys->get_symbian_version_use())));

    _state->mounted = true;

    // Register a per-screen redraw callback so each frame produced by the
    // Symbian window server triggers a swap on the EAGL context. The
    // launcher.draw() composition layer from the Android frontend is not
    // ported in stage 2 — see "已知风险" — so content drawing depends on the
    // standard graphics_driver command pipeline alone.
    if (_state->winserv) {
        auto *state = _state.get();
        eka2l1::epoc::screen *screens = _state->winserv->get_screens();
        while (screens) {
            std::size_t handle = screens->add_screen_redraw_callback(state,
                [](void *userdata, eka2l1::epoc::screen * /*scr*/, const bool /*is_dsa*/) {
                    auto *st = reinterpret_cast<eka2l1::ios::emulator *>(userdata);
                    if (!st->graphics_driver) {
                        return;
                    }
                    st->graphics_driver->wait_for(&st->present_status);
                    eka2l1::drivers::graphics_command_builder builder;
                    st->present_status = -100;
                    builder.present(&st->present_status);
                    eka2l1::drivers::command_list retrieved = builder.retrieve_command_list();
                    st->graphics_driver->submit_command_list(retrieved);
                });
            _state->screen_redraw_handles.push_back(handle);
            screens = screens->next;
        }
    }

    return YES;
}

- (NSArray<EKA2L1AppEntry *> *)rescanApps {
    NSMutableArray<EKA2L1AppEntry *> *out = [NSMutableArray array];
    if (!_state || !_state->symsys) {
        return out;
    }
    auto *kern = _state->symsys->get_kernel_system();
    if (!kern) {
        return out;
    }
    auto *alserv = reinterpret_cast<eka2l1::applist_server *>(
        kern->get_by_name<eka2l1::service::server>(
            eka2l1::get_app_list_server_name_by_epocver(kern->get_epoc_version())));
    if (!alserv) {
        return out;
    }
    alserv->rescan_registries(_state->symsys->get_io_system());
    for (auto &reg : alserv->get_registerations()) {
        if (reg.caps.is_hidden) {
            continue;
        }
        EKA2L1AppEntry *entry = [[EKA2L1AppEntry alloc] init];
        entry.uid = reg.mandatory_info.uid;
        std::string name = eka2l1::common::ucs2_to_utf8(reg.mandatory_info.long_caption.to_std_string(nullptr));
        entry.name = [NSString stringWithUTF8String:name.c_str()];
        [out addObject:entry];
    }
    return out;
}

- (BOOL)launchAppWithUID:(uint32_t)uid {
    if (!_state || !_state->symsys) {
        return NO;
    }
    auto *kern = _state->symsys->get_kernel_system();
    auto *alserv = reinterpret_cast<eka2l1::applist_server *>(
        kern->get_by_name<eka2l1::service::server>(
            eka2l1::get_app_list_server_name_by_epocver(kern->get_epoc_version())));
    if (!alserv) {
        return NO;
    }
    auto *reg = alserv->get_registration(uid);
    if (!reg) {
        return NO;
    }
    eka2l1::epoc::apa::command_line cmdline;
    cmdline.launch_cmd_ = eka2l1::epoc::apa::command_create;

    kern->lock();
    bool launched = alserv->launch_app(*reg, cmdline, nullptr, nullptr);
    kern->unlock();
    return launched ? YES : NO;
}

- (BOOL)installSisAtPath:(NSString *)sisPath {
    if (!_state || !_state->symsys) {
        return NO;
    }
    std::u16string upath = eka2l1::common::utf8_to_ucs2(sisPath.UTF8String);
    drive_number install_drive = _state->symsys->is_s80_device_active()
        ? drive_number::drive_d
        : drive_number::drive_e;
    auto result = static_cast<eka2l1::package::installation_result>(
        _state->symsys->install_package(upath, install_drive));
    return result == eka2l1::package::installation_result_success ? YES : NO;
}

- (void)attachLayer:(CAEAGLLayer *)layer
         pixelSize:(CGSize)pixelSize
              scale:(CGFloat)scale {
    if (!_state) {
        return;
    }
    {
        std::lock_guard<std::mutex> lk(_state->layer_mutex);
        _state->pending_layer = (__bridge void *)layer;
        _state->pending_width = static_cast<std::uint32_t>(pixelSize.width);
        _state->pending_height = static_cast<std::uint32_t>(pixelSize.height);
        _state->pending_scale = static_cast<float>(scale);
        _state->layer_dirty = true;
        _state->layer_cv.notify_all();
    }
    // Once the graphics thread has consumed the first layer, subsequent
    // changes flow through surface_change_hook → driver->update_surface.
    if (_state->window && _state->graphics_driver) {
        _state->window->surface_changed((__bridge void *)layer,
            static_cast<int>(pixelSize.width),
            static_cast<int>(pixelSize.height),
            static_cast<float>(scale));
    }
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
    if (!_state || !_state->winserv) {
        return;
    }
    eka2l1::drivers::input_event evt;
    evt.type_ = eka2l1::drivers::input_event_type::touch;
    evt.time_ = 0;
    evt.mouse_.pos_x_ = static_cast<int>(x);
    evt.mouse_.pos_y_ = static_cast<int>(y);
    evt.mouse_.pos_z_ = 0;
    evt.mouse_.button_ = eka2l1::drivers::mouse_button_left;
    evt.mouse_.raw_screen_pos_ = true;
    // Single-touch in stage 2; the UITouch pointer hash maps to a mouse_id
    // so window_server can still tell separate gestures apart later.
    evt.mouse_.mouse_id = static_cast<std::uint32_t>(pointerId & 0xFFFFFFFFu);
    switch (phase) {
        case EKA2L1PointerPhaseBegan:     evt.mouse_.action_ = eka2l1::drivers::mouse_action_press; break;
        case EKA2L1PointerPhaseMoved:     evt.mouse_.action_ = eka2l1::drivers::mouse_action_repeat; break;
        case EKA2L1PointerPhaseEnded:     evt.mouse_.action_ = eka2l1::drivers::mouse_action_release; break;
        case EKA2L1PointerPhaseCancelled: evt.mouse_.action_ = eka2l1::drivers::mouse_action_release; break;
    }
    _state->winserv->queue_input_from_driver(evt);
}

@end
