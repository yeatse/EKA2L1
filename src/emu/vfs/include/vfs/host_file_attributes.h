// Persist the supported Symbian read-only bit in the mapped host file itself.
// Check permission bits, not access(W_OK): an elevated host may still write a
// read-only file, whereas the guest file-server contract must deny that open.
#pragma once

#include <filesystem>
#include <optional>
#include <system_error>

namespace eka2l1 {
    inline std::optional<bool> host_file_is_read_only(const std::filesystem::path &path) {
        std::error_code error;
        const auto status = std::filesystem::status(path, error);
        if (error || !std::filesystem::exists(status)
            || status.permissions() == std::filesystem::perms::unknown)
            return std::nullopt;
        constexpr auto writes = std::filesystem::perms::owner_write
            | std::filesystem::perms::group_write | std::filesystem::perms::others_write;
        return (status.permissions() & writes) == std::filesystem::perms::none;
    }

    inline bool set_host_file_read_only(const std::filesystem::path &path, bool read_only) {
        std::error_code error;
        const auto status = std::filesystem::status(path, error);
        if (error || !std::filesystem::exists(status)
            || status.permissions() == std::filesystem::perms::unknown)
            return false;
        constexpr auto writes = std::filesystem::perms::owner_write
            | std::filesystem::perms::group_write | std::filesystem::perms::others_write;
        const auto desired = read_only ? status.permissions() & ~writes
            : status.permissions() | std::filesystem::perms::owner_write;
        std::filesystem::permissions(path, desired, std::filesystem::perm_options::replace, error);
        return !error;
    }
}
