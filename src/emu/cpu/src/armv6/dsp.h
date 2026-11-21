// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#pragma once

#include <algorithm>
#include <array>
#include <bit>
#include <cstdint>
#include <limits>

namespace eka2l1::arm::armv6 {
    inline std::int32_t saturate_signed(std::int64_t value, std::uint32_t& cpsr) {
        const auto result = std::clamp<std::int64_t>(value, std::numeric_limits<std::int32_t>::min(),
            std::numeric_limits<std::int32_t>::max());
        if (result != value)
            cpsr |= 1u << 27;
        return static_cast<std::int32_t>(result);
    }

    inline void signed_multiply(std::uint32_t bits, std::array<std::uint32_t, 16>& regs, std::uint32_t& cpsr) {
        const unsigned dst = (bits >> 16) & 15, acc = (bits >> 12) & 15;
        const auto lhs = regs[bits & 15], rhs = regs[(bits >> 8) & 15];
        const auto half = [](std::uint32_t word, bool high) {
            return static_cast<std::int16_t>(high ? word >> 16 : word);
        };
        const auto kind = (bits >> 21) & 3;
        const auto multiplier = half(rhs, bits & 64);
        const std::int32_t product = kind == 1
            ? static_cast<std::int32_t>((std::int64_t(static_cast<std::int32_t>(lhs)) * multiplier) >> 16)
            : half(lhs, bits & 32) * multiplier;
        if (kind == 2) {
            auto sum = (std::uint64_t(regs[dst]) << 32) | regs[acc];
            sum += product;
            regs[acc] = static_cast<std::uint32_t>(sum);
            regs[dst] = static_cast<std::uint32_t>(sum >> 32);
        } else if (kind == 3 || (kind == 1 && (bits & 32))) {
            regs[dst] = product;
        } else {
            const auto sum = std::int64_t(static_cast<std::int32_t>(regs[acc])) + product;
            regs[dst] = static_cast<std::uint32_t>(sum);
            if (sum != static_cast<std::int32_t>(regs[dst]))
                cpsr |= 1u << 27;
        }
    }
}
