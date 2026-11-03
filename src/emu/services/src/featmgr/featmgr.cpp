/*
 * Copyright (c) 2018 EKA2L1 Team
 * 
 * This file is part of EKA2L1 project
 * (see bentokun.github.com/EKA2L1).
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#include <common/cvt.h>
#include <common/log.h>

#include <services/context.h>
#include <services/featmgr/featmgr.h>
#include <services/featmgr/op.h>
#include <system/epoc.h>
#include <utils/des.h>
#include <utils/err.h>
#include <vfs/vfs.h>

#include <algorithm>
#include <cstring>

namespace eka2l1 {
    featmgr_server::featmgr_server(system *sys)
        : service::server(sys->get_kernel_system(), sys, nullptr, "!FeatMgrServer", true) {
        REGISTER_IPC(featmgr_server, feature_supported, EFeatMgrFeatureSupported, "FeatMgr::FeatureSupported");
    }

    enum feature_id : epoc::uid {
        feature_id_opengl_es_3d_api = 10,
        feature_id_svgt = 77,
        feature_id_side_volume_key = 207,
        feature_id_pen = 410,
        feature_id_vibra = 411,
        feature_id_korean = 180,
        feature_id_japanese = 1080,
        feature_id_thai = 1081,
        feature_id_chinese = 1096,
        feature_id_flash_lite_viewer = 1145,
        feature_id_flash_lite_browser_plugin = 1146,
        feature_id_pen_calibration = 1658,
        feature_id_tactile_feedback = 1718,
        feature_id_help = 1012
    };

    void featmgr_server::do_feature_scanning(system *sys) {
        // TODO: There is a lot of features.
        // See in here: https://github.com/SymbianSource/oss.FCL.sf.os.deviceplatformrelease/blob/master/foundation_system/sf_config/config/inc/publicruntimeids.hrh

        // 1. We always welcome rendering with OpenGL ES and Flash
        enable_features.push_back(feature_id_opengl_es_3d_api);
        enable_features.push_back(feature_id_flash_lite_viewer);
        enable_features.push_back(feature_id_side_volume_key);
        enable_features.push_back(feature_id_pen);
        enable_features.push_back(feature_id_vibra);
        enable_features.push_back(feature_id_pen_calibration);

        // Every S60 device ships the help application, and AVKON adjusts a menu pane
        // depending on whether it is there. A ROM's featreg.cfg is usually near-empty
        // here, so anything not listed reads as unsupported: the Calculator's Options
        // menu then panics with EIKCOCTL 8 instead of opening.
        enable_features.push_back(feature_id_help);

        // Browser-hosted Flash Lite is a separate feature from the standalone viewer
        // below, so report it only when the ROM carries the browser plug-in itself.
        if (sys->get_io_system()->exist(u"z:\\sys\\bin\\npflashlite.dll")) {
            enable_features.push_back(feature_id_flash_lite_browser_plugin);
        }

        // 2. Are we welcoming SVG? Check for OpenVG, cause it should be there if this feature is available
        if (sys->get_io_system()->exist(u"z:\\sys\\bin\\libopenvg.dll")) {
            enable_features.push_back(feature_id_svgt);
        }

        // 3. Check for system language. User have responsibility to be honest :D
        // I like automatic detection, but it's not really easy thogh
        switch (sys->get_system_language()) {
        case language::zh: {
            enable_features.push_back(feature_id_chinese);
            break;
        }

        case language::jp: {
            enable_features.push_back(feature_id_japanese);
            break;
        }

        case language::ko: {
            enable_features.push_back(feature_id_korean);
            break;
        }

        case language::th: {
            enable_features.push_back(feature_id_thai);
            break;
        }

        default:
            break;
        }

        // 4: Add stuff you like here.
    }

    bool featmgr_server::load_featmgr_configs(io_system *io) {
        symfile cfg_file = io->open_file(u"Z:\\private\\102744CA\\featreg.cfg", READ_MODE | BIN_MODE);

        if (!cfg_file) {
            LOG_WARN(SERVICE_FEATMGR, "Feature registration config file not present!");
            return false;
        }

        featmgr_config_header header;
        cfg_file->read_file(&header, 1, sizeof(featmgr_config_header));

        // Check magic header
        if (strncmp(header.magic, "feat", 4) != 0) {
            return false;
        }

        {
            featmgr_config_entry temp_entry;

            for (uint32_t i = 0; i < header.num_entry; i++) {
                cfg_file->read_file(&temp_entry, 1, sizeof(featmgr_config_entry));

                if (temp_entry.info > 0) {
                    enable_features.push_back(temp_entry.uid);
                }
            }
        }

        {
            featmgr_config_range temp_range;

            for (uint32_t i = 0; i < header.num_range; i++) {
                cfg_file->read_file(&temp_range, 1, sizeof(featmgr_config_entry));
                enable_feature_ranges.push_back(temp_range);
            }
        }

        return true;
    }

    bool featmgr_server::load_feature_files(io_system *io) {
        // Symbian^3 FeatMgrServer reads every Z:\private\10205054\feature* file in name order;
        // a later file's entry replaces an earlier one with the same UID.
        auto dir = io->open_dir(u"Z:\\private\\10205054\\feature*", {}, io_attrib_include_file);
        if (!dir) {
            return false;
        }

        std::vector<std::string> paths;
        while (std::optional<entry_info> info = dir->get_next_entry()) {
            paths.push_back(info->full_path);
        }

        std::sort(paths.begin(), paths.end());

        static constexpr std::uint32_t FEATURE_FLAG_SUPPORTED = 1 << 0;
        static constexpr std::uint32_t FEATURE_FLAG_UNINITIALIZED = 1 << 4;

        bool loaded = false;

        for (const std::string &path : paths) {
            symfile file = io->open_file(common::utf8_to_ucs2(path), READ_MODE | BIN_MODE);
            if (!file) {
                continue;
            }

            featmgr_config_header header;
            if ((file->read_file(&header, 1, sizeof(header)) != sizeof(header)) || (strncmp(header.magic, "feat", 4) != 0)
                || (header.unk1 != 1)) {
                LOG_WARN(SERVICE_FEATMGR, "Feature file {} has an invalid header", path);
                continue;
            }

            std::vector<feature_file_entry> entries(header.num_entry);
            std::vector<featmgr_config_range> ranges(header.num_range);

            const std::size_t entries_size = entries.size() * sizeof(feature_file_entry);
            const std::size_t ranges_size = ranges.size() * sizeof(featmgr_config_range);

            if ((file->read_file(entries.data(), 1, static_cast<std::uint32_t>(entries_size)) != entries_size)
                || (file->read_file(ranges.data(), 1, static_cast<std::uint32_t>(ranges_size)) != ranges_size)) {
                LOG_WARN(SERVICE_FEATMGR, "Feature file {} is truncated", path);
                continue;
            }

            for (const feature_file_entry &entry : entries) {
                // An uninitialised feature is answered with KErrNotReady, which clients read as unsupported.
                listed_features[entry.uid] = (entry.flags & FEATURE_FLAG_SUPPORTED) && !(entry.flags & FEATURE_FLAG_UNINITIALIZED);
            }

            enable_feature_ranges.insert(enable_feature_ranges.end(), ranges.begin(), ranges.end());
            loaded = true;
        }

        return loaded;
    }

    void featmgr_server::ensure_config_loaded(system *sys) {
        if (config_loaded) {
            return;
        }

        const bool has_feature_files = load_feature_files(sys->get_io_system());

        if (!load_featmgr_configs(sys->get_io_system()) && !has_feature_files) {
            LOG_ERROR(SERVICE_FEATMGR, "Error loading feature manager server config!");
        }

        do_feature_scanning(sys);
        std::sort(enable_features.begin(), enable_features.end());

        config_loaded = true;
    }

    bool featmgr_server::lookup_feature(const epoc::uid feature_id) const {
        if (auto listed = listed_features.find(feature_id); listed != listed_features.end()) {
            return listed->second;
        }

        if (std::binary_search(enable_features.begin(), enable_features.end(), feature_id)) {
            return true;
        }

        for (const auto &feature_range : enable_feature_ranges) {
            if ((feature_range.low_uid <= feature_id) && (feature_id <= feature_range.high_uid)) {
                return true;
            }
        }

        return false;
    }

    bool featmgr_server::is_feature_supported(system *sys, const epoc::uid feature_id) {
        ensure_config_loaded(sys);
        return lookup_feature(feature_id);
    }

    void featmgr_server::feature_supported(service::ipc_context &ctx) {
        ensure_config_loaded(ctx.sys);

        epoc::uid feature_id = 0;

        // NOTE: Newer version of this server use TFeatureEntry struct. Care about this note when this server
        // mess things up.
        if (ctx.sys->get_symbian_version_use() >= epocver::epoc95) {
            std::optional<feature_entry> entry = ctx.get_argument_data_from_descriptor<feature_entry>(0);
            if (!entry.has_value()) {
                ctx.complete(epoc::error_argument);
                return;
            }

            feature_id = entry->feature_id_;
        } else {
            feature_id = *ctx.get_argument_value<epoc::uid>(0);
        }

        const int result = lookup_feature(feature_id) ? 1 : 0;
        ctx.write_data_to_descriptor_argument(1, result);
        ctx.complete(epoc::error_none);
    }
}
