// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#import "IosEmulator.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <iomanip>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <tuple>
#include <vector>

#include <sys/stat.h>

#include <common/buffer.h>
#include <common/cvt.h>
#include <common/fileutils.h>
#include <common/log.h>
#include <common/path.h>
#include <common/pystr.h>
#include <common/version.h>
#include <config/app_settings.h>
#include <config/config.h>
#include <drivers/audio/audio.h>
#include <drivers/audio/dsp.h>
#include <drivers/audio/player.h>
#include <drivers/graphics/backend/emu_window_ios.h>
#include <drivers/graphics/graphics.h>
#include <drivers/input/common.h>
#include <drivers/itc.h>
#include <drivers/hwrm/vibration.h>
#include <services/window/screen.h>
#include <kernel/kernel.h>
#include <loader/mbm.h>
#include <loader/mif.h>
#include <loader/nvg.h>
#include <loader/svgb.h>
#include <package/manager.h>
#include <services/applist/applist.h>
#include <services/fbs/bitmap.h>
#include <services/fbs/fbs.h>
#include <services/window/window.h>
#include <system/devices.h>
#include <system/epoc.h>
#include <system/installation/common.h>
#include <system/installation/firmware.h>
#include <system/installation/rpkg.h>
#include <system/software.h>
#include <utils/apacmd.h>
#include <vfs/vfs.h>

#include <lunasvg.h>

@implementation EKA2L1AppEntry
@end

@implementation EKA2L1DeviceEntry
@end

namespace eka2l1::ios {
    static EKA2L1InstallResult map_install_result(eka2l1::device_installation_error err) {
        switch (err) {
            case eka2l1::device_installation_none: return EKA2L1InstallResultSuccess;
            case eka2l1::device_installation_not_exist: return EKA2L1InstallResultNotExist;
            case eka2l1::device_installation_insufficent: return EKA2L1InstallResultInsufficient;
            case eka2l1::device_installation_rpkg_corrupt: return EKA2L1InstallResultRpkgCorrupt;
            case eka2l1::device_installation_determine_product_failure: return EKA2L1InstallResultDetermineProductFailure;
            case eka2l1::device_installation_already_exist: return EKA2L1InstallResultAlreadyExist;
            case eka2l1::device_installation_general_failure: return EKA2L1InstallResultGeneralFailure;
            case eka2l1::device_installation_rom_fail_to_copy: return EKA2L1InstallResultRomFailToCopy;
            case eka2l1::device_installation_vpl_file_invalid: return EKA2L1InstallResultVplInvalid;
            case eka2l1::device_installation_rofs_corrupt: return EKA2L1InstallResultRofsCorrupt;
            case eka2l1::device_installation_rom_file_corrupt: return EKA2L1InstallResultRomCorrupt;
            case eka2l1::device_installation_fpsx_corrupt: return EKA2L1InstallResultFpsxCorrupt;
            default: return EKA2L1InstallResultGeneralFailure;
        }
    }
}

namespace eka2l1::ios {
    // 3.6 icon decoder. Mirrors src/emu/android/.../launcher.cpp::get_app_icon
    // but writes the rendered RGBA buffer straight into a CFData → CGImage →
    // UIImage → PNG round-trip so SwiftUI can consume it as plain Data.
    //
    // Order of attempts matches the Android side:
    //   .mif → lunasvg (after svgb / nvg debinarization, cached to disk)
    //   .mbm → epoc::convert_to_rgba8888 against sbm header 0
    //   anything else → applist_server::get_icon -> bitwise_bitmap pair
    static NSData *encode_rgba_to_png(const std::uint8_t *pixels,
                                      std::size_t width, std::size_t height,
                                      std::size_t requested_side) {
        if (!pixels || width == 0 || height == 0) {
            return nil;
        }
        CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
        CGBitmapInfo bitmap_info = kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast;
        const std::size_t bpr = width * 4;
        CGContextRef src_ctx = CGBitmapContextCreate(const_cast<std::uint8_t *>(pixels),
            width, height, 8, bpr, color_space, bitmap_info);
        if (!src_ctx) {
            CGColorSpaceRelease(color_space);
            return nil;
        }
        CGImageRef src_image = CGBitmapContextCreateImage(src_ctx);
        CGContextRelease(src_ctx);
        if (!src_image) {
            CGColorSpaceRelease(color_space);
            return nil;
        }

        // Rescale into a square `requested_side` × `requested_side` so the
        // SwiftUI list cells get a predictable canvas; lunasvg renders at the
        // SVG's intrinsic size (often 88×88 or 176×176) and MBM dimensions
        // vary by app. Skip rescale if it already matches to save one draw.
        UIImage *image = nil;
        if (requested_side == width && requested_side == height) {
            image = [UIImage imageWithCGImage:src_image];
        } else {
            CGContextRef dst_ctx = CGBitmapContextCreate(nullptr,
                requested_side, requested_side, 8, requested_side * 4,
                color_space, bitmap_info);
            if (dst_ctx) {
                CGContextSetInterpolationQuality(dst_ctx, kCGInterpolationHigh);
                CGContextDrawImage(dst_ctx, CGRectMake(0, 0, requested_side, requested_side), src_image);
                CGImageRef dst_image = CGBitmapContextCreateImage(dst_ctx);
                CGContextRelease(dst_ctx);
                if (dst_image) {
                    image = [UIImage imageWithCGImage:dst_image];
                    CGImageRelease(dst_image);
                }
            }
        }
        CGImageRelease(src_image);
        CGColorSpaceRelease(color_space);
        if (!image) {
            return nil;
        }
        return UIImagePNGRepresentation(image);
    }

    static NSData *decode_mif_icon(eka2l1::apa_app_registry *reg,
                                   eka2l1::io_system *io,
                                   const std::string &cache_dir,
                                   std::size_t side) {
        eka2l1::symfile file_route = io->open_file(reg->icon_file_path, READ_MODE | BIN_MODE);
        if (!file_route) return nil;
        eka2l1::common::create_directories(cache_dir);

        const std::string app_name = eka2l1::common::ucs2_to_utf8(
            reg->mandatory_info.long_caption.to_std_string(nullptr));
        std::string sanitized = eka2l1::common::pystr(app_name).strip_reserverd().strip().std_str();
        if (sanitized.empty()) {
            std::ostringstream uid_name;
            uid_name << "uid_" << std::hex << std::uppercase << reg->mandatory_info.uid;
            sanitized = uid_name.str();
        }
        const std::string cached_path = cache_dir + "/debinarized_" + sanitized + ".svg";
        const std::uint64_t mif_last_modified = file_route->last_modify_since_0ad();

        std::unique_ptr<lunasvg::Document> document;
        if (eka2l1::common::exists(cached_path)) {
            const std::u16string cached_u16 = eka2l1::common::utf8_to_ucs2(cached_path);
            if (eka2l1::common::get_last_modifiy_since_ad(cached_u16) >= mif_last_modified) {
                document = lunasvg::Document::loadFromFile(cached_path.c_str());
            }
        }

        if (!document) {
            eka2l1::ro_file_stream rfs(file_route.get());
            eka2l1::loader::mif_file parser(reinterpret_cast<eka2l1::common::ro_stream *>(&rfs));
            if (parser.do_parse()) {
                int dest_size = 0;
                if (parser.read_mif_entry(0, nullptr, dest_size) && dest_size > 0) {
                    std::vector<std::uint8_t> data(dest_size);
                    parser.read_mif_entry(0, data.data(), dest_size);
                    eka2l1::common::ro_buf_stream inside(data.data(), data.size());
                    auto outfile = std::make_unique<eka2l1::common::wo_std_file_stream>(cached_path, true);

                    eka2l1::loader::mif_icon_header header;
                    inside.read(&header, sizeof(header));

                    std::vector<eka2l1::loader::svgb_convert_error_description> svgb_errors;
                    std::vector<eka2l1::loader::nvg_convert_error_description> nvg_errors;

                    if (header.type == eka2l1::loader::mif_icon_type_svg) {
                        if (!eka2l1::loader::convert_svgb_to_svg(inside, *outfile, svgb_errors)) {
                            if (!svgb_errors.empty()
                                && svgb_errors[0].reason_ == eka2l1::loader::svgb_convert_error_invalid_file) {
                                // SVGB conversion failed because the payload is already plain SVG.
                                outfile->write(reinterpret_cast<const char *>(data.data()) + sizeof(header),
                                    data.size() - sizeof(header));
                            }
                        }
                        outfile.reset();
                        document = lunasvg::Document::loadFromFile(cached_path.c_str());
                    } else {
                        inside = eka2l1::common::ro_buf_stream(data.data() + sizeof(header),
                            data.size() - sizeof(header));
                        if (eka2l1::loader::convert_nvg_to_svg(inside, *outfile, nvg_errors)) {
                            outfile.reset();
                            document = lunasvg::Document::loadFromFile(cached_path.c_str());
                        } else {
                            outfile.reset();
                            eka2l1::common::remove(cached_path);
                        }
                    }
                }
            }
        }

        if (!document) return nil;
        const std::uint32_t w = static_cast<std::uint32_t>(document->width());
        const std::uint32_t h = static_cast<std::uint32_t>(document->height());
        if (w == 0 || h == 0) return nil;

        std::vector<std::uint8_t> rgba(w * h * 4);
        auto bitmap = lunasvg::Bitmap(rgba.data(), w, h, w * 4);
        document->render(bitmap, lunasvg::Matrix{ 1, 0, 0, 1, 0, 0 });
        bitmap.convertToRGBA();
        return encode_rgba_to_png(rgba.data(), w, h, side);
    }

    static NSData *decode_mbm_icon(eka2l1::apa_app_registry *reg,
                                   eka2l1::fbs_server *fbsserv,
                                   eka2l1::io_system *io,
                                   std::size_t side) {
        eka2l1::symfile file_route = io->open_file(reg->icon_file_path, READ_MODE | BIN_MODE);
        if (!file_route) return nil;
        eka2l1::ro_file_stream rfs(file_route.get());
        eka2l1::loader::mbm_file parser(reinterpret_cast<eka2l1::common::ro_stream *>(&rfs));
        if (!parser.do_read_headers() || parser.sbm_headers.empty()) return nil;

        const auto &hdr = parser.sbm_headers[0];
        const std::size_t w = hdr.size_pixels.x;
        const std::size_t h = hdr.size_pixels.y;
        if (w == 0 || h == 0) return nil;

        std::vector<std::uint8_t> rgba(w * h * 4);
        eka2l1::common::wo_buf_stream dst(rgba.data(), rgba.size());
        if (!eka2l1::epoc::convert_to_rgba8888(fbsserv, parser, 0, dst)) {
            return nil;
        }
        return encode_rgba_to_png(rgba.data(), w, h, side);
    }

    static NSData *decode_bitwise_icon(eka2l1::apa_app_registry *reg,
                                       eka2l1::applist_server *alserv,
                                       eka2l1::fbs_server *fbsserv,
                                       std::size_t side) {
        auto icon_pair = alserv->get_icon(*reg, 0);
        if (!icon_pair.has_value() || !icon_pair->first) return nil;
        auto *bitmap = icon_pair->first;
        const std::size_t w = bitmap->header_.size_pixels.x;
        const std::size_t h = bitmap->header_.size_pixels.y;
        if (w == 0 || h == 0) return nil;

        std::vector<std::uint8_t> rgba(w * h * 4);
        eka2l1::common::wo_buf_stream dst(rgba.data(), rgba.size());
        if (!eka2l1::epoc::convert_to_rgba8888(fbsserv, bitmap, dst)) return nil;
        return encode_rgba_to_png(rgba.data(), w, h, side);
    }
}

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
        std::unique_ptr<drivers::audio_driver> audio_driver;

        config::state conf;
        window_server *winserv = nullptr;
        std::string documents_root;

        std::atomic<bool> running{false};
        std::atomic<bool> paused{false};
        // symsys->loop() must not run before bootDeviceAtIndex: completes —
        // kernel_system::crr_thread() dereferences a null thread_scheduler
        // otherwise. The os_thread idles until this flips true.
        std::atomic<bool> mounted{false};

        // Frame loop / lifecycle (task 2.9). Two threads sit behind the
        // singleton — one feeds drivers::graphics_driver::run() (must own
        // the EAGL context), the other ticks symsys->loop().
        std::unique_ptr<std::thread> os_thread;
        std::unique_ptr<std::thread> graphics_thread;

        // Held by os_thread around each symsys->loop() tick. Device install /
        // switch rebuilds symsys (or mutates device_manager) and must not race
        // a loop in flight, so those paths grab this between ticks.
        std::mutex loop_mutex;

        std::mutex layer_mutex;
        std::condition_variable layer_cv;
        bool layer_dirty = false;
        void *pending_layer = nullptr;
        std::uint32_t pending_width = 0;
        std::uint32_t pending_height = 0;
        float pending_scale = 1.0f;

        std::mutex icon_mutex;
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

    // 3.7: instantiate the cubeb iOS AudioUnit (RemoteIO) backend up front so
    // services that fan out audio_driver at startup (KeySound, MediaClient,
    // DSP shared streams) get a real instance instead of the nullptr the
    // stage-2 sandbox used. cubeb_init -> audiounit_init in the iOS shim
    // configures AVAudioSession (Playback category, mix-with-others) on the
    // first call.
    eka2l1::drivers::player_type midi_be = eka2l1::drivers::player_type_tsf;
    _state->audio_driver = eka2l1::drivers::make_audio_driver(
        eka2l1::drivers::audio_driver_backend::cubeb,
        _state->conf.audio_master_volume,
        midi_be);
    if (_state->audio_driver) {
        _state->audio_driver->set_bank_path(eka2l1::drivers::MIDI_BANK_TYPE_HSB,
            _state->conf.hsb_bank_path);
        _state->audio_driver->set_bank_path(eka2l1::drivers::MIDI_BANK_TYPE_SF2,
            _state->conf.sf2_bank_path);
    } else {
        LOG_WARN(eka2l1::FRONTEND_CMDLINE,
            "iOS audio: cubeb_audio_driver instance is null; services will fall back to silence");
    }

    eka2l1::system_create_components comp;
    comp.audio_ = _state->audio_driver.get();
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
                std::lock_guard<std::mutex> loop_lock(state->loop_mutex);
                state->symsys->loop();
            } catch (std::exception &exc) {
                LOG_ERROR(eka2l1::FRONTEND_CMDLINE, "Emu loop exception: {}", exc.what());
                state->running = false;
                break;
            }
        }
    });

    // If a device was previously installed, boot straight into it (restoring
    // the last-selected one from conf.device) so the frontend lands on the
    // app list rather than the empty-state import prompt.
    auto *dvc = _state->symsys->get_device_manager();
    if (dvc && dvc->total() > 0) {
        std::size_t want = static_cast<std::size_t>(std::max(0, _state->conf.device));
        if (want >= dvc->total()) {
            want = 0;
        }
        [self bootDeviceAtIndex:want];
    }

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
    _state->audio_driver.reset();
    _state->window.reset();
    _state->settings.reset();
    _state.reset();
}

- (NSArray<EKA2L1DeviceEntry *> *)installedDevices {
    NSMutableArray<EKA2L1DeviceEntry *> *out = [NSMutableArray array];
    if (!_state || !_state->symsys) {
        return out;
    }
    auto *dvc = _state->symsys->get_device_manager();
    if (!dvc) {
        return out;
    }
    std::lock_guard<std::mutex> dvc_lock(dvc->lock);
    auto &devices = dvc->get_devices();
    for (std::size_t i = 0; i < devices.size(); i++) {
        EKA2L1DeviceEntry *entry = [[EKA2L1DeviceEntry alloc] init];
        entry.index = i;
        entry.firmwareCode = [NSString stringWithUTF8String:devices[i].firmware_code.c_str()];
        entry.manufacturer = [NSString stringWithUTF8String:devices[i].manufacturer.c_str()];
        entry.model = [NSString stringWithUTF8String:devices[i].model.c_str()];
        [out addObject:entry];
    }
    return out;
}

- (NSInteger)currentDeviceIndex {
    if (!_state || !_state->mounted || !_state->symsys) {
        return -1;
    }
    auto *dvc = _state->symsys->get_device_manager();
    if (!dvc) {
        return -1;
    }
    return static_cast<NSInteger>(dvc->get_current_index());
}

- (EKA2L1InstallResult)installDeviceWithRomPath:(NSString *)romPath
                                       rpkgPath:(NSString *)rpkgPath {
    if (!_state || !_state->symsys) {
        return EKA2L1InstallResultGeneralFailure;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:romPath]) {
        return EKA2L1InstallResultNotExist;
    }

    // Installing mutates device_manager + the sandbox storage tree; stop the
    // os_thread from ticking symsys->loop() while we work, then wait out any
    // in-flight tick before touching shared state. On a failed install the
    // installers revert their own changes, so restore the previous run state
    // (a device may already be booted) and let it keep ticking. On success the
    // frontend boots the new device, which rebuilds the system and remounts.
    const bool was_mounted = _state->mounted;
    _state->mounted = false;
    std::lock_guard<std::mutex> loop_lock(_state->loop_mutex);

    auto *sys = _state->symsys.get();
    auto *dvc = sys->get_device_manager();
    if (!dvc) {
        _state->mounted = was_mounted;
        return EKA2L1InstallResultGeneralFailure;
    }

    const std::string storage = _state->conf.storage;
    const std::string root_z_path = eka2l1::add_path(storage, "drives/z/");
    const std::string rom_resident_path = eka2l1::add_path(storage, "roms/");
    eka2l1::common::create_directories(rom_resident_path);

    const std::string rom_std = romPath.UTF8String;
    eka2l1::device_installation_error result = eka2l1::device_installation_general_failure;
    bool need_add_rpkg = false;
    std::string firmware_code;

    // Mirror launcher::install_device: a raw ROM that the loader flags as
    // needing an RPKG must be paired with one; otherwise install_rom alone
    // covers the dump.
    if (eka2l1::loader::should_install_requires_additional_rpkg(rom_std)) {
        if (!rpkgPath || ![fm fileExistsAtPath:rpkgPath]) {
            _state->mounted = was_mounted;
            return EKA2L1InstallResultNeedRpkg;
        }
        result = eka2l1::loader::install_rpkg(dvc, rpkgPath.UTF8String, root_z_path,
            firmware_code, nullptr, nullptr);
        need_add_rpkg = true;
    } else {
        result = eka2l1::loader::install_rom(dvc, rom_std, rom_resident_path, root_z_path,
            nullptr, nullptr);
    }

    if (result != eka2l1::device_installation_none) {
        _state->mounted = was_mounted;
        return eka2l1::ios::map_install_result(result);
    }

    dvc->save_devices();

    if (need_add_rpkg) {
        const std::string rom_directory = eka2l1::add_path(rom_resident_path,
            eka2l1::common::lowercase_string(firmware_code) + "/");
        eka2l1::common::create_directories(rom_directory);
        eka2l1::common::copy_file(rom_std, eka2l1::add_path(rom_directory, "SYM.ROM"), true);
    }

    return EKA2L1InstallResultSuccess;
}

- (BOOL)bootDeviceAtIndex:(NSUInteger)index {
    if (!_state) {
        return NO;
    }
    const std::string storage = _state->conf.storage;

    // Rebuild the system so device_manager reloads devices.yml fresh and the
    // kernel comes up clean for the selected device. device_manager only
    // reads devices.yml on construction. Stop + drain the os_thread first so
    // the symsys reset below doesn't race a loop in flight.
    _state->mounted = false;
    std::lock_guard<std::mutex> loop_lock(_state->loop_mutex);
    _state->winserv = nullptr;
    _state->screen_redraw_handles.clear();

    eka2l1::system_create_components comp;
    comp.audio_ = _state->audio_driver.get();
    comp.graphics_ = nullptr;
    comp.conf_ = &_state->conf;
    comp.settings_ = _state->settings.get();
    _state->symsys = std::make_unique<eka2l1::system>(comp);
    auto *sys = _state->symsys.get();

    sys->startup();
    auto *dvc = sys->get_device_manager();
    if (!dvc || index >= dvc->total()) {
        return NO;
    }
    if (!sys->set_device(static_cast<std::uint8_t>(index))) {
        return NO;
    }
    _state->conf.device = static_cast<int>(index);
    _state->conf.serialize();

    sys->mount(drive_c, drive_media::physical, eka2l1::add_path(storage, "/drives/c/"), io_attrib_internal);
    sys->mount(drive_d, drive_media::physical, eka2l1::add_path(storage, "/drives/d/"), io_attrib_internal);
    sys->mount(drive_e, drive_media::physical, eka2l1::add_path(storage, "/drives/e/"), io_attrib_removeable);
    sys->mount(drive_z, drive_media::rom, eka2l1::add_path(storage, "/drives/z/"),
        io_attrib_internal | io_attrib_write_protected);

    if (_state->graphics_driver) {
        sys->set_graphics_driver(_state->graphics_driver.get());
    }
    if (_state->audio_driver) {
        sys->set_audio_driver(_state->audio_driver.get());
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
    // Symbian window server triggers a swap on the EAGL context.
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
    // 3.7: drop the AVAudioSession activation while we're in the background
    // so the system can route audio to whatever's actually frontmost. The
    // session reactivates on resume below; the AURemoteIO units themselves
    // are left untouched — the data callback simply stops being invoked
    // until the session is active again.
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:&err];
    if (err) {
        LOG_WARN(eka2l1::FRONTEND_CMDLINE, "iOS audio: setActive:NO failed: {}",
            err.localizedDescription.UTF8String ?: "unknown");
    }
}

- (void)resume {
    if (!_state) return;
    _state->paused = false;
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
    if (err) {
        LOG_WARN(eka2l1::FRONTEND_CMDLINE, "iOS audio: setActive:YES failed: {}",
            err.localizedDescription.UTF8String ?: "unknown");
    }
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

- (void)submitRawKey:(uint32_t)scanCode pressed:(BOOL)pressed {
    if (!_state || !_state->winserv) {
        return;
    }
    eka2l1::drivers::input_event evt;
    evt.type_ = eka2l1::drivers::input_event_type::key_raw;
    evt.time_ = 0;
    evt.key_.code_ = static_cast<int>(scanCode);
    evt.key_.state_ = pressed ? eka2l1::drivers::key_state::pressed : eka2l1::drivers::key_state::released;
    _state->winserv->queue_input_from_driver(evt);
}

- (void)tapRawKey:(uint32_t)scanCode {
    [self submitRawKey:scanCode pressed:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(60 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self submitRawKey:scanCode pressed:NO];
    });
}

- (NSDictionary<NSString *, id> *)currentConfigSnapshot {
    if (!_state) {
        return @{};
    }
    return @{
        @"audioMasterVolume": @(_state->conf.audio_master_volume),
        @"integerScaling": @(_state->conf.integer_scaling),
        @"nearestNeighborFiltering": @(_state->conf.nearest_neighbor_filtering),
        @"hideSystemApps": @(_state->conf.hide_system_apps),
        @"extensiveLogging": @(_state->conf.extensive_logging),
        @"cpuBackend": [NSString stringWithUTF8String:_state->conf.cpu_backend.c_str()],
        @"deviceDisplayName": [NSString stringWithUTF8String:_state->conf.device_display_name.c_str()],
        @"logFilter": [NSString stringWithUTF8String:_state->conf.log_filter.c_str()]
    };
}

- (BOOL)applyConfigSnapshot:(NSDictionary<NSString *, id> *)snapshot {
    if (!_state) {
        return NO;
    }

    NSNumber *volume = snapshot[@"audioMasterVolume"];
    if (volume) {
        _state->conf.audio_master_volume = std::clamp(volume.intValue, 0, 100);
        if (_state->audio_driver) {
            _state->audio_driver->master_volume(_state->conf.audio_master_volume);
        }
    }
    NSNumber *integerScaling = snapshot[@"integerScaling"];
    if (integerScaling) {
        _state->conf.integer_scaling = integerScaling.boolValue;
    }
    NSNumber *nearest = snapshot[@"nearestNeighborFiltering"];
    if (nearest) {
        _state->conf.nearest_neighbor_filtering = nearest.boolValue;
    }
    NSNumber *hideSystemApps = snapshot[@"hideSystemApps"];
    if (hideSystemApps) {
        _state->conf.hide_system_apps = hideSystemApps.boolValue;
    }
    NSNumber *extensive = snapshot[@"extensiveLogging"];
    if (extensive) {
        _state->conf.extensive_logging = extensive.boolValue;
    }
    NSString *cpuBackend = snapshot[@"cpuBackend"];
    if ([cpuBackend isKindOfClass:NSString.class]) {
        _state->conf.cpu_backend = cpuBackend.UTF8String;
    }
    NSString *deviceDisplayName = snapshot[@"deviceDisplayName"];
    if ([deviceDisplayName isKindOfClass:NSString.class]) {
        _state->conf.device_display_name = deviceDisplayName.UTF8String;
    }
    NSString *logFilter = snapshot[@"logFilter"];
    if ([logFilter isKindOfClass:NSString.class]) {
        _state->conf.log_filter = logFilter.UTF8String;
    }

    _state->conf.serialize();
    return YES;
}

- (void)testVibration {
    auto vibrator = eka2l1::drivers::hwrm::make_suitable_vibrator();
    if (vibrator) {
        vibrator->vibrate(180, 70);
    }
}

- (nullable NSData *)iconPNGDataForUID:(uint32_t)uid sizePx:(NSUInteger)sizePx {
    if (!_state || !_state->symsys || sizePx == 0) {
        return nil;
    }
    std::lock_guard<std::mutex> icon_lock(_state->icon_mutex);
    auto *kern = _state->symsys->get_kernel_system();
    if (!kern) return nil;
    auto *alserv = reinterpret_cast<eka2l1::applist_server *>(
        kern->get_by_name<eka2l1::service::server>(
            eka2l1::get_app_list_server_name_by_epocver(kern->get_epoc_version())));
    auto *fbsserv = reinterpret_cast<eka2l1::fbs_server *>(
        kern->get_by_name<eka2l1::service::server>(
            eka2l1::epoc::get_fbs_server_name_by_epocver(kern->get_epoc_version())));
    if (!alserv) return nil;
    auto *reg = alserv->get_registration(uid);
    if (!reg) return nil;

    auto *io = _state->symsys->get_io_system();
    const std::u16string ext = eka2l1::common::lowercase_ucs2_string(
        eka2l1::path_extension(reg->icon_file_path));

    const std::string cache_dir = eka2l1::add_path(_state->documents_root, "data/cache/icons");
    const std::size_t side = static_cast<std::size_t>(sizePx);

    NSData *out = nil;
    if (ext == u".mif") {
        out = eka2l1::ios::decode_mif_icon(reg, io, cache_dir, side);
    } else if (ext == u".mbm") {
        if (fbsserv) out = eka2l1::ios::decode_mbm_icon(reg, fbsserv, io, side);
    } else {
        if (fbsserv) out = eka2l1::ios::decode_bitwise_icon(reg, alserv, fbsserv, side);
    }
    // If the registered icon type didn't yield anything, try the bitwise
    // fallback too — some apps point .mif at corrupt blobs but still expose a
    // bitwise icon via the applist server.
    if (!out && fbsserv && (ext == u".mif" || ext == u".mbm")) {
        out = eka2l1::ios::decode_bitwise_icon(reg, alserv, fbsserv, side);
    }
    return out;
}

@end
