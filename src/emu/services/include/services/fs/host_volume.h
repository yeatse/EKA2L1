// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <utils/err.h>

#include <cstdint>
#include <filesystem>
#include <limits>
#include <optional>
#include <string_view>
#include <system_error>

namespace eka2l1::epoc::fs {
    inline std::optional<std::int32_t> volume_session_drive(std::u16string_view path) {
        if (path.size() < 3 || path[1] != u':' || (path[2] != u'\\' && path[2] != u'/'))
            return std::nullopt;
        if (path[0] >= u'A' && path[0] <= u'Z')
            return path[0] - u'A';
        if (path[0] >= u'a' && path[0] <= u'z')
            return path[0] - u'a';
        return std::nullopt;
    }

    struct host_volume_space {
        std::int32_t error = epoc::error_none;
        std::int64_t capacity = 0;
        std::int64_t available = 0;
    };

    inline std::int32_t host_volume_error(const std::error_code &error) {
        if (error == std::errc::no_such_file_or_directory || error == std::errc::not_a_directory
            || error == std::errc::no_such_device || error == std::errc::no_such_device_or_address)
            return epoc::error_not_ready;
        if (error == std::errc::permission_denied || error == std::errc::operation_not_permitted)
            return epoc::error_access_denied;
        if (error == std::errc::value_too_large)
            return epoc::error_overflow;
        return epoc::error_general;
    }

    inline host_volume_space checked_host_volume_space(const std::filesystem::space_info &space, bool read_only) {
        constexpr auto limit = static_cast<std::uintmax_t>(std::numeric_limits<std::int64_t>::max());
        // TVolumeInfo uses signed TInt64 fields. Never narrow a host size to 32
        // bits or turn an unknown/overflowing size into a successful quota.
        if (space.capacity > limit || (!read_only && space.available > limit))
            return { epoc::error_overflow };
        if (!read_only && space.available > space.capacity)
            return { epoc::error_general };
        return { epoc::error_none, static_cast<std::int64_t>(space.capacity),
            read_only ? 0 : static_cast<std::int64_t>(space.available) };
    }

    inline host_volume_space query_host_volume(const std::filesystem::path &mapped_root, bool read_only) {
        // No fallback to the current directory: an absent mount must fail.
        if (mapped_root.empty())
            return { epoc::error_not_ready };
        std::error_code error;
        const auto status = std::filesystem::status(mapped_root, error);
        if (error)
            return { host_volume_error(error) };
        if (!std::filesystem::is_directory(status))
            return { epoc::error_not_ready };
        const auto space = std::filesystem::space(mapped_root, error);
        if (error)
            return { host_volume_error(error) };
        // available, not free: exclude blocks reserved from this host user.
        return checked_host_volume_space(space, read_only);
    }
}
