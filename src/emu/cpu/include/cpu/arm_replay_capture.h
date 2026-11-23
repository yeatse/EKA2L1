// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#pragma once

#include <cpu/arm_interface.h>

#include <cstdint>
#include <functional>
#include <string>

namespace eka2l1::arm {
    // Returns the host address of the 4 KiB guest page at `base`, or nullptr when it is not mapped.
    using replay_page_lookup = std::function<const std::uint8_t *(address base)>;

    /**
     * Runs `budget` instructions from `initial` on a private reference core and writes an
     * arm_replay snapshot to `path`. Live memory is only read. Returns false without writing
     * when the interval needs a syscall, an exception, an exclusive access or an unmapped page.
     */
    bool capture_replay_snapshot(const core::thread_context &initial, const replay_page_lookup &lookup,
        std::uint32_t budget, const std::string &path);
}
