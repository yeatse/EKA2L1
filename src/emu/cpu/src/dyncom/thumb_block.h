// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#pragma once

#include <cstdlib>

#include <cpu/dyncom/armstate.h>
#include <cpu/dyncom/armsupp.h>

namespace eka2l1::arm::thumb_block {
    enum class opcode : std::uint8_t {
        lsl, lsr, asr, add, sub, add_imm, sub_imm, constant, cmp_imm,
        bit_and, bit_xor, bit_or, mul, load_word, load_half
    };

    struct operation {
        opcode code;
        std::uint8_t dst, lhs, rhs;
    };

    constexpr unsigned max_length = 16;

    inline bool decode(std::uint16_t hw, bool first, operation &op) {
        const auto rd = static_cast<std::uint8_t>(hw & 7);
        const auto rn = static_cast<std::uint8_t>((hw >> 3) & 7);
        const auto imm5 = static_cast<std::uint8_t>((hw >> 6) & 31);
        const auto rd8 = static_cast<std::uint8_t>((hw >> 8) & 7);
        const auto group = hw >> 11;
        if (hw < 0x1800) {
            constexpr opcode shifts[] = { opcode::lsl, opcode::lsr, opcode::asr };
            op = { shifts[hw >> 11], rd, rn, imm5 };
        } else if (hw < 0x2000) {
            constexpr opcode sums[] = { opcode::add, opcode::sub, opcode::add_imm, opcode::sub_imm };
            op = { sums[(hw >> 9) & 3], rd, rn, static_cast<std::uint8_t>(imm5 & 7) };
        } else if (hw < 0x4000) {
            constexpr opcode immediates[] = { opcode::constant, opcode::cmp_imm, opcode::add_imm, opcode::sub_imm };
            op = { immediates[(hw >> 11) & 3], rd8, rd8, static_cast<std::uint8_t>(hw) };
        } else if ((hw & 0xfc00) == 0x4000) {
            opcode kind;
            switch ((hw >> 6) & 15) {
            case 0: kind = opcode::bit_and; break;
            case 1: kind = opcode::bit_xor; break;
            case 12: kind = opcode::bit_or; break;
            case 13: kind = opcode::mul; break;
            default: return false;
            }
            op = { kind, rd, rd, rn };
        } else if (first && (group == 0x0d || group == 0x11)) {
            op = { group == 0x0d ? opcode::load_word : opcode::load_half, rd, rn, imm5 };
        } else if (first && group == 0x13) {
            op = { opcode::load_word, rd8, 13, static_cast<std::uint8_t>(hw) };
        } else {
            return false;
        }
        return true;
    }

    // A potentially faulting load is legal only at entry, with the original PC and flags.
    inline unsigned execute(ARMul_State &cpu, const operation *ops, unsigned length, unsigned retired) {
        auto &regs = cpu.Reg;
        unsigned i = 0;
        if (ops->code == opcode::load_word || ops->code == opcode::load_half) {
            const auto base = regs[ops->lhs];
            regs[ops->dst] = ops->code == opcode::load_word
                ? cpu.ReadMemory32(base + 4u * ops->rhs) : cpu.ReadMemory16(base + 2u * ops->rhs);
            regs[15] += 2;
            ++i;
        }
        const unsigned start = i;
        std::uint32_t result = 0;
        while (i < length && retired + i < cpu.NumInstrsToExecute) {
            const auto &op = ops[i++];
            const auto lhs = regs[op.lhs];
            const auto rhs = op.rhs;
            bool carry, overflow;
            switch (op.code) {
            case opcode::lsl:
                result = lhs << rhs;
                if (rhs) cpu.CFlag = (lhs >> (32 - rhs)) & 1;
                break;
            case opcode::lsr:
                result = rhs ? lhs >> rhs : 0;
                cpu.CFlag = (lhs >> (rhs ? rhs - 1 : 31)) & 1;
                break;
            case opcode::asr:
                result = static_cast<std::int32_t>(lhs) >> (rhs ? rhs : 31);
                cpu.CFlag = (lhs >> (rhs ? rhs - 1 : 31)) & 1;
                break;
            case opcode::add:
            case opcode::add_imm:
                result = AddWithCarry(lhs, op.code == opcode::add ? regs[rhs] : rhs, 0, &carry, &overflow);
                cpu.CFlag = carry;
                cpu.VFlag = overflow;
                break;
            case opcode::sub:
            case opcode::sub_imm:
            case opcode::cmp_imm:
                result = AddWithCarry(lhs, ~(op.code == opcode::sub ? regs[rhs] : std::uint32_t(rhs)), 1, &carry, &overflow);
                cpu.CFlag = carry;
                cpu.VFlag = overflow;
                if (op.code == opcode::cmp_imm) continue;
                break;
            case opcode::constant: result = rhs; break;
            case opcode::bit_and: result = lhs & regs[rhs]; break;
            case opcode::bit_or: result = lhs | regs[rhs]; break;
            case opcode::bit_xor: result = lhs ^ regs[rhs]; break;
            case opcode::mul: result = lhs * regs[rhs]; break;
            case opcode::load_word:
            case opcode::load_half: std::abort();
            }
            regs[op.dst] = result;
        }
        if (i > start) {
            cpu.NFlag = result >> 31;
            cpu.ZFlag = result == 0;
            regs[15] += 2 * (i - start);
        }
        return i;
    }
}
