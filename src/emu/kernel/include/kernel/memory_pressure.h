#pragma once

#include <cstdint>

namespace eka2l1::kernel {
    // HLE free-memory notification watermarks.
    constexpr std::uint64_t memory_low_threshold = 8ULL * 1024 * 1024;
    constexpr std::uint64_t memory_good_threshold = 24ULL * 1024 * 1024;
    constexpr std::uint32_t changes_free_memory = 0x20;
    constexpr std::uint32_t changes_low_memory = 0x80;

    constexpr std::uint64_t remaining_guest_ram(std::uint64_t total, std::uint64_t committed) {
        // Reported free RAM saturates at zero.
        return committed < total ? total - committed : 0;
    }

    constexpr std::uint32_t memory_threshold_changes(std::uint64_t before, std::uint64_t after) {
        // Match K::CheckFreeMemoryLevel: low is exclusive, good is inclusive.
        if (before >= memory_low_threshold && after < memory_low_threshold)
            return changes_free_memory | changes_low_memory;
        if (before < memory_good_threshold && after >= memory_good_threshold)
            return changes_free_memory;
        return 0;
    }
}
