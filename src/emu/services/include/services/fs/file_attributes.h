#pragma once

#include <cstdint>

namespace eka2l1 {
    enum class read_only_change { invalid, unsupported, unchanged, set, clear };

    inline read_only_change requested_read_only_change(std::uint32_t set, std::uint32_t clear) {
        // f32file.h: Dir, Volume and Remote cannot be changed through SetAtt.
        constexpr std::uint32_t ignored = 0x10 | 0x08 | 0x100;
        constexpr std::uint32_t read_only = 0x01;
        if (set & clear)
            return read_only_change::invalid;
        if ((set | clear) & ~(ignored | read_only))
            return read_only_change::unsupported;
        if (set & read_only)
            return read_only_change::set;
        if (clear & read_only)
            return read_only_change::clear;
        return read_only_change::unchanged;
    }
}
