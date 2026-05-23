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
#include <tuple>
#include <vector>

#include <sys/stat.h>

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
#include <system/software.h>
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

    static bool wait_for_graphics_driver(emulator *state, const std::chrono::milliseconds timeout) {
        if (!state) {
            return false;
        }
        std::unique_lock<std::mutex> lock(state->layer_mutex);
        return state->layer_cv.wait_for(lock, timeout, [state]() {
            return !state->running || state->graphics_driver != nullptr;
        }) && state->graphics_driver != nullptr;
    }

    static bool bind_graphics_driver(emulator *state) {
        if (!state || !state->symsys || !state->graphics_driver) {
            return false;
        }

        state->symsys->set_graphics_driver(state->graphics_driver.get());
        auto *kern = state->symsys->get_kernel_system();
        if (!state->winserv && kern) {
            state->winserv = reinterpret_cast<eka2l1::window_server *>(
                kern->get_by_name<eka2l1::service::server>(
                    eka2l1::get_winserv_name_by_epocver(kern->get_epoc_version())));
        }
        if (state->winserv) {
            for (eka2l1::epoc::screen *scr = state->winserv->get_screens(); scr; scr = scr->next) {
                if (!scr->screen_texture) {
                    scr->set_screen_mode(state->winserv, state->graphics_driver.get(), scr->crr_mode);
                }
            }
        }
        return true;
    }

    static void submit_screen_frame(emulator *state, eka2l1::epoc::screen *scr) {
        if (!state || !state->graphics_driver || !state->window) {
            return;
        }
        if (!scr || !scr->screen_texture) {
            return;
        }

        // Same semantics as the Qt / Android frontends: wait_for blocks
        // while present_status == -100 (in-flight) and returns immediately
        // once the driver thread has called finish(). Initial 0 also
        // returns immediately. Only set -100 right before submitting the
        // next present.
        state->graphics_driver->wait_for(&state->present_status);

        eka2l1::drivers::graphics_command_builder builder;
        const eka2l1::vec2 swapchain_size = state->window->window_fb_size();
        builder.set_swapchain_size(swapchain_size);
        builder.backup_state();
        builder.bind_bitmap(0);
        builder.set_feature(eka2l1::drivers::graphics_feature::cull, false);
        builder.set_feature(eka2l1::drivers::graphics_feature::depth_test, false);
        builder.set_feature(eka2l1::drivers::graphics_feature::blend, false);
        builder.set_feature(eka2l1::drivers::graphics_feature::clipping, false);
        builder.set_feature(eka2l1::drivers::graphics_feature::stencil_test, false);

        eka2l1::rect viewport;
        viewport.size = swapchain_size;
        builder.set_viewport(viewport);
        builder.clear({ 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f },
            eka2l1::drivers::draw_buffer_bit_color_buffer);

        if (scr) {
            auto &mode = scr->current_mode();
            eka2l1::rect src;
            src.size = mode.size;

            float width = static_cast<float>(swapchain_size.x);
            float height = mode.size.y * width / mode.size.x;
            if (height > swapchain_size.y) {
                height = static_cast<float>(swapchain_size.y);
                width = mode.size.x * height / mode.size.y;
            }

            eka2l1::rect dest;
            dest.top.x = static_cast<int>((swapchain_size.x - width) / 2.0f);
            dest.top.y = static_cast<int>((swapchain_size.y - height) / 2.0f);
            dest.size.x = static_cast<int>(width);
            dest.size.y = static_cast<int>(height);

            const float scale_x = width / static_cast<float>(mode.size.x);
            const float scale_y = height / static_cast<float>(mode.size.y);
            scr->set_native_scale_factor(state->graphics_driver.get(), scale_x, scale_y);
            scr->absolute_pos = dest.top;

            eka2l1::drivers::advance_draw_pos_around_origin(dest, scr->ui_rotation);
            if (scr->ui_rotation % 180 != 0) {
                std::swap(dest.size.x, dest.size.y);
                std::swap(src.size.x, src.size.y);
            }
            src.size *= scr->display_scale_factor;

            std::uint32_t flags = 0;
            if (scr->flags_ & eka2l1::epoc::screen::FLAG_SCREEN_UPSCALE_FACTOR_LOCK) {
                flags |= eka2l1::drivers::bitmap_draw_flag_use_upscale_shader;
            }

            if (scr->screen_texture) {
                builder.set_texture_filter(scr->screen_texture, true, eka2l1::drivers::filter_option::linear);
                builder.set_texture_filter(scr->screen_texture, false, eka2l1::drivers::filter_option::linear);
                builder.draw_bitmap(scr->screen_texture, 0, dest, src, eka2l1::vec2(0, 0),
                    static_cast<float>(scr->ui_rotation), flags);
            }
        }

        builder.load_backup_state();
        state->present_status = -100;
        builder.present(&state->present_status);
        eka2l1::drivers::command_list commands = builder.retrieve_command_list();
        state->graphics_driver->submit_command_list(commands);
    }

    static void install_required_rom_patches(emulator *state) {
        if (!state || !state->symsys) {
            return;
        }

        auto *io = state->symsys->get_io_system();
        const std::string patch_dir = eka2l1::add_path(state->documents_root, "data/patch");
        const std::vector<std::tuple<std::u16string, std::string, epocver>> dlls_need_to_copy = {
            { u"Z:\\sys\\bin\\goommonitor.dll", "goommonitor_general.dll", epocver::epoc94 },
            { u"Z:\\sys\\bin\\avkonfep.dll", "avkonfep_general.dll", epocver::epoc93fp1 }
        };

        for (const auto &entry : dlls_need_to_copy) {
            if (state->symsys->get_symbian_version_use() < std::get<2>(entry)) {
                continue;
            }

            auto destination = io->get_raw_path(std::get<0>(entry));
            if (!destination.has_value()) {
                continue;
            }

            const std::string source = eka2l1::add_path(patch_dir, std::get<1>(entry));
            const std::string dest = common::ucs2_to_utf8(destination.value());
            if (!common::exists(source)) {
                continue;
            }

            const std::string backup = dest + ".bak";
            if (common::exists(dest) && !common::exists(backup)) {
                common::move_file(dest, backup);
            }
            common::copy_file(source, dest, true);
        }
    }
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
    // Drive letters mirror Symbian's uppercase convention. iOS app data
    // containers are case-sensitive (despite the host APFS volume being
    // case-insensitive), so rescan_devices()'s "drives/Z/" probe and the
    // mount() calls below have to find these exact names on disk.
    // Use lowercase drive letters and firmcode dir names throughout. The
    // system code paths that read the ROM / Z drive build their paths via
    // common::lowercase_string(firmcode) and lowercase drive letters, and
    // the iOS sim's runtime presents the app with a case-sensitive view of
    // the host APFS volume (which itself is case-insensitive, so we can
    // only ever have one entry per case-insensitive name on disk). Naming
    // everything lowercase ensures both views agree.
    NSArray<NSString *> *subdirs = @[@"roms", @"data", @"sis",
                                      @"data/drives/c", @"data/drives/d",
                                      @"data/drives/e", @"data/drives/z",
                                      @"data/compat"];
    for (NSString *sub in subdirs) {
        NSString *path = [documentsPath stringByAppendingPathComponent:sub];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *bundleShaders = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"resources"];
    NSString *dataShaders = [[documentsPath stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:@"resources"];
    NSString *sourceShaders = [[[@(__FILE__) stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"../../drivers/resources/gles"] stringByStandardizingPath];
    NSString *shaderSource = [fm fileExistsAtPath:bundleShaders] ? bundleShaders : sourceShaders;
    if ([fm fileExistsAtPath:shaderSource]) {
        [fm removeItemAtPath:dataShaders error:nil];
        [fm copyItemAtPath:shaderSource toPath:dataShaders error:nil];
    }

    NSString *dataPatch = [[documentsPath stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:@"patch"];
    NSString *sourcePatch = [[[@(__FILE__) stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"../../../patch"] stringByStandardizingPath];
    if ([fm fileExistsAtPath:sourcePatch]) {
        [fm removeItemAtPath:dataPatch error:nil];
        [fm createDirectoryAtPath:dataPatch withIntermediateDirectories:YES attributes:nil error:nil];
        NSDirectoryEnumerator<NSString *> *patchEnum = [fm enumeratorAtPath:sourcePatch];
        for (NSString *relative in patchEnum) {
            if (![relative containsString:@"/group/"]) {
                continue;
            }
            NSString *name = relative.lastPathComponent;
            if (![name hasSuffix:@".map"] && ![name hasSuffix:@"_general.dll"]) {
                continue;
            }
            NSString *src = [sourcePatch stringByAppendingPathComponent:relative];
            NSString *dst = [dataPatch stringByAppendingPathComponent:name];
            [fm copyItemAtPath:src toPath:dst error:nil];
        }
    }

    // Run the emulator with cwd = Documents/data so the config / drive paths
    // resolve into the sandbox rather than the (read-only) bundle.
    NSString *dataRoot = [documentsPath stringByAppendingPathComponent:@"data"];
    chdir(dataRoot.UTF8String);

    eka2l1::log::setup_log(nullptr);
    LOG_INFO(eka2l1::FRONTEND_CMDLINE, "EKA2L1 iOS v0.0.1 ({}-{})", GIT_BRANCH, GIT_COMMIT_HASH);


    _state->conf.deserialize();
    _state->conf.storage = dataRoot.UTF8String;
    _state->conf.cpu_load_save = false;
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
        auto graphics_driver = eka2l1::drivers::create_graphics_driver(
            eka2l1::drivers::graphic_api::opengl,
            state->window->get_window_system_info());
        if (!graphics_driver) {
            LOG_ERROR(eka2l1::DRIVER_GRAPHICS, "iOS graphics driver creation failed");
            state->layer_cv.notify_all();
            return;
        }
        {
            std::lock_guard<std::mutex> publish_lock(state->layer_mutex);
            state->graphics_driver = std::move(graphics_driver);
        }
        state->layer_cv.notify_all();

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
    NSString *romsRoot = [@(_state->documents_root.c_str()) stringByAppendingPathComponent:@"roms"];
    NSString *romPath = [romsRoot stringByAppendingPathComponent:romName];
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:romPath isDirectory:&isDir] || !isDir) {
        return NO;
    }

    auto *sys = _state->symsys.get();
    const std::string storage = _state->conf.storage;
    NSFileManager *fm = NSFileManager.defaultManager;

    // The user-supplied ROM bundle ships as a desktop storage tree:
    //   <romPath>/data/drives/z/<firm>/...   Symbian Z-drive filesystem
    //   <romPath>/data/roms/<firm>/SYM.rom   raw ROM image (case-sensitive!)
    // We stage it into the live sandbox so the running system finds it at
    // both upper- and lower-case firmcode paths.
    NSString *zSrc = [romPath stringByAppendingPathComponent:@"data/drives/z"];
    NSString *romSrc = [romPath stringByAppendingPathComponent:@"data/roms"];
    if (![fm fileExistsAtPath:zSrc isDirectory:&isDir] || !isDir ||
        ![fm fileExistsAtPath:romSrc isDirectory:&isDir] || !isDir) {
        return NO;
    }

    // Generate a devices.yml entry for each firm we find. device_manager
    // only re-reads this on construction, so we have to write it BEFORE
    // restarting / rebuilding system. For stage 2 we already created system
    // in start(); to pick up devices we'll rewrite devices.yml and recreate
    // system. That's a heavy hammer, but the alternative (calling
    // rescan_devices) recurses into symlinked content and can destroy the
    // user's bundle if the SYM.ROM probe fails.
    NSMutableString *yaml = [NSMutableString string];
    NSString *zDst = [@(storage.c_str()) stringByAppendingPathComponent:@"drives/z"];
    NSString *romDst = [@(storage.c_str()) stringByAppendingPathComponent:@"roms"];
    for (NSString *firm in [fm contentsOfDirectoryAtPath:zSrc error:nil]) {
        NSString *firmZSrc = [zSrc stringByAppendingPathComponent:firm];
        std::string manufacturer = "Nokia";
        std::string firmCode = firm.UTF8String;
        std::string model = firmCode;
        epocver version = eka2l1::loader::determine_rpkg_symbian_version(firmZSrc.UTF8String);
        eka2l1::loader::determine_rpkg_product_info(firmZSrc.UTF8String, manufacturer, firmCode, model);
        NSString *systemInstall = [firmZSrc stringByAppendingPathComponent:@"system/Install"];
        if (![fm fileExistsAtPath:systemInstall isDirectory:&isDir] || !isDir) {
            systemInstall = [firmZSrc stringByAppendingPathComponent:@"System/Install"];
        }
        if (version == epocver::epoc94) {
            if ([fm fileExistsAtPath:[systemInstall stringByAppendingPathComponent:@"Series60v3.1.sis"]]) {
                version = epocver::epoc93fp1;
            } else if ([fm fileExistsAtPath:[systemInstall stringByAppendingPathComponent:@"Series60v3.2.sis"]]) {
                version = epocver::epoc93fp2;
            }
        }

        const std::string firmLowerUtf8 = eka2l1::common::lowercase_string(firmCode);
        NSString *firmLower = [NSString stringWithUTF8String:firmLowerUtf8.c_str()];
        NSString *firmZDst = [zDst stringByAppendingPathComponent:firmLower];
        unlink(firmZDst.UTF8String);
        symlink(firmZSrc.UTF8String, firmZDst.UTF8String);

        NSString *romFirmSrc = [romSrc stringByAppendingPathComponent:firm];
        NSString *romFirmDst = [romDst stringByAppendingPathComponent:firmLower];
        [fm removeItemAtPath:romFirmDst error:nil];
        [fm createDirectoryAtPath:romFirmDst withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *fname in [fm contentsOfDirectoryAtPath:romFirmSrc error:nil]) {
            NSString *src = [romFirmSrc stringByAppendingPathComponent:fname];
            // rescan/load_rom probes literal uppercase "SYM.ROM".
            NSString *targetName = ([fname caseInsensitiveCompare:@"SYM.ROM"] == NSOrderedSame)
                ? @"SYM.ROM" : fname;
            NSString *dst = [romFirmDst stringByAppendingPathComponent:targetName];
            unlink(dst.UTF8String);
            symlink(src.UTF8String, dst.UTF8String);
        }

        [yaml appendFormat:@"%s:\n  platver: %s\n  manufacturer: %s\n  firmcode: %s\n  model: %s\n  machine-uid: 0\n",
            firmCode.c_str(), epocver_to_string(version), manufacturer.c_str(), firmCode.c_str(), model.c_str()];
    }
    if (yaml.length == 0) {
        return NO;
    }

    // Write devices.yml then re-instantiate system so device_manager picks
    // up the new entries (constructor calls load_devices()).
    NSString *yamlPath = [@(storage.c_str()) stringByAppendingPathComponent:@"devices.yml"];
    [yaml writeToFile:yamlPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    eka2l1::system_create_components comp;
    comp.audio_ = nullptr;
    comp.graphics_ = nullptr;
    comp.conf_ = &_state->conf;
    comp.settings_ = _state->settings.get();
    _state->symsys = std::make_unique<eka2l1::system>(comp);
    sys = _state->symsys.get();

    sys->startup();
    if (sys->get_device_manager()->total() == 0) {
        return NO;
    }
    if (!sys->set_device(0)) {
        return NO;
    }
    sys->mount(drive_c, drive_media::physical, eka2l1::add_path(storage, "/drives/c/"), io_attrib_internal);
    sys->mount(drive_d, drive_media::physical, eka2l1::add_path(storage, "/drives/d/"), io_attrib_internal);
    sys->mount(drive_e, drive_media::physical, eka2l1::add_path(storage, "/drives/e/"), io_attrib_removeable);
    sys->mount(drive_z, drive_media::rom, eka2l1::add_path(storage, "/drives/z/"),
        io_attrib_internal | io_attrib_write_protected);

    if (_state->graphics_driver) {
        sys->set_graphics_driver(_state->graphics_driver.get());
    }
    sys->initialize_user_parties();
    if (_state->graphics_driver) {
        sys->set_graphics_driver(_state->graphics_driver.get());
    }
    eka2l1::ios::install_required_rom_patches(_state.get());
    sys->get_packages()->load_registries();
    sys->get_packages()->migrate_legacy_registries();

    auto *kern = sys->get_kernel_system();
    _state->winserv = reinterpret_cast<eka2l1::window_server *>(
        kern->get_by_name<eka2l1::service::server>(
            eka2l1::get_winserv_name_by_epocver(kern->get_epoc_version())));

    _state->mounted = true;
    eka2l1::ios::bind_graphics_driver(_state.get());

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
                [](void *userdata, eka2l1::epoc::screen *scr, const bool /*is_dsa*/) {
                    auto *st = reinterpret_cast<eka2l1::ios::emulator *>(userdata);
                    if (!st->graphics_driver) {
                        return;
                    }
                    eka2l1::ios::submit_screen_frame(st, scr);
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
    if (!eka2l1::ios::wait_for_graphics_driver(_state.get(), std::chrono::seconds(5))) {
        LOG_ERROR(eka2l1::DRIVER_GRAPHICS, "iOS graphics driver was not ready before app launch");
        return NO;
    }
    eka2l1::ios::bind_graphics_driver(_state.get());

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

    eka2l1::kernel::uid launched_thread_id = 0;
    kern->lock();
    bool launched = alserv->launch_app(*reg, cmdline, &launched_thread_id, nullptr);
    if (launched) {
        kern->stop_cores_idling();
    }
    kern->unlock();
    if (!_state->winserv) {
        _state->winserv = reinterpret_cast<eka2l1::window_server *>(
            kern->get_by_name<eka2l1::service::server>(
                eka2l1::get_winserv_name_by_epocver(kern->get_epoc_version())));
    }
    if (launched && _state->winserv) {
        auto *state = _state.get();
        eka2l1::epoc::screen *immediate_scr = state->winserv ? state->winserv->get_screens() : nullptr;
        if (immediate_scr && !immediate_scr->screen_texture && state->graphics_driver) {
            immediate_scr->set_screen_mode(state->winserv, state->graphics_driver.get(), immediate_scr->crr_mode);
        }
        eka2l1::ios::submit_screen_frame(state, immediate_scr);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.5 * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                eka2l1::epoc::screen *scr = state->winserv ? state->winserv->get_screens() : nullptr;
                if (scr && !scr->screen_texture && state->graphics_driver) {
                    scr->set_screen_mode(state->winserv, state->graphics_driver.get(), scr->crr_mode);
                }
                if (scr && state->graphics_driver) {
                    scr->redraw(state->graphics_driver.get());
                }
                eka2l1::ios::submit_screen_frame(state, scr);
            });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(1.5 * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                eka2l1::epoc::screen *scr = state->winserv ? state->winserv->get_screens() : nullptr;
                if (scr && !scr->screen_texture && state->graphics_driver) {
                    scr->set_screen_mode(state->winserv, state->graphics_driver.get(), scr->crr_mode);
                }
                if (scr && state->graphics_driver) {
                    scr->redraw(state->graphics_driver.get());
                }
                eka2l1::ios::submit_screen_frame(state, scr);
            });
    }
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
