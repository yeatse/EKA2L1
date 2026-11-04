// RFile sharing compatibility follows the public f32file.h promotion table.
// Claims belong to independently opened file objects, not to processes.
#pragma once

#include <array>
#include <cassert>
#include <cstdint>
#include <limits>

namespace eka2l1 {
    class file_share_state {
        // Exclusive, ReadersOnly, Any, optional reader, optional writer.
        std::array<std::uint32_t, 5> counts_{};

        static unsigned index(unsigned mode, bool write) {
            return mode == 3 ? (write ? 4 : 3) : mode;
        }

    public:
        std::uint32_t use_count{0};

        bool compatible(unsigned mode, bool write) const {
            if (mode > 3 || (mode == 1 && write))
                return false;
            if (!use_count)
                return true;
            if (!mode || counts_[0])
                return false;
            if (mode == 1)
                return !counts_[2] && !counts_[4];
            if (mode == 2 || write)
                return !counts_[1];
            return true;
        }

        bool can_acquire(unsigned mode, bool write) const {
            return compatible(mode, write)
                && use_count != std::numeric_limits<std::uint32_t>::max();
        }

        void acquire(unsigned mode, bool write) {
            assert(can_acquire(mode, write));
            ++counts_[index(mode, write)];
            ++use_count;
        }

        void release(unsigned mode, bool write) {
            assert(mode <= 3 && counts_[index(mode, write)] && use_count);
            --counts_[index(mode, write)];
            --use_count;
        }
    };
}
