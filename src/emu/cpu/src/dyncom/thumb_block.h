// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#pragma once

#include <cpu/dyncom/armstate.h>
#include <cpu/dyncom/armsupp.h>

namespace eka2l1::arm::thumb_block {
    enum class opcode : std::uint8_t {
        lsl, lsr, asr, add, sub, add_imm, sub_imm, constant, cmp_imm,
        bit_and, bit_xor, bit_or, mul, load_word, load_half, store_word, store_half,
        load_word_reg, load_half_reg, store_word_reg, store_half_reg, move_reg, add_reg_no_flags
    };

    struct operation {
        opcode code;
        std::uint8_t dst, lhs, rhs;
    };

    constexpr unsigned max_length = 16;

    inline bool decode(std::uint16_t hw, operation &op) {
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
        } else if ((hw & 0xff00) == 0x4600 || (hw & 0xff00) == 0x4400) {
            const auto dst = static_cast<std::uint8_t>(rd | ((hw >> 4) & 8));
            const auto src = static_cast<std::uint8_t>((hw >> 3) & 15);
            if (dst == 15 || src == 15 || (dst < 8 && src < 8))
                return false;
            op = { (hw & 0x0200) ? opcode::move_reg : opcode::add_reg_no_flags, dst, src, 0 };
        } else if ((hw & 0xf400) == 0x5000) {
            constexpr opcode transfers[] = { opcode::store_word_reg, opcode::store_half_reg,
                opcode::load_word_reg, opcode::load_half_reg };
            const auto index = ((hw >> 9) & 1) | ((hw >> 10) & 2);
            op = { transfers[index], rd, rn, static_cast<std::uint8_t>((hw >> 6) & 7) };
        } else if (group == 0x0c || group == 0x0d || group == 0x10 || group == 0x11) {
            constexpr opcode transfers[] = { opcode::store_word, opcode::load_word, opcode::store_half, opcode::load_half };
            op = { transfers[(group >= 0x10 ? 2 : 0) + (group & 1)], rd, rn, imm5 };
        } else if (group == 0x12 || group == 0x13) {
            op = { group == 0x13 ? opcode::load_word : opcode::store_word, rd8, 13,
                static_cast<std::uint8_t>(hw) };
        } else {
            return false;
        }
        return true;
    }

    inline unsigned execute(ARMul_State &cpu, const operation *ops, unsigned length, unsigned retired) {
        auto &regs = cpu.Reg;
        unsigned i = 0;
        std::uint32_t result = 0;
        unsigned pc_index = 0;
        bool pending_nz = false;
        auto synchronize = [&](unsigned index) {
            regs[15] += 2 * (index - pc_index);
            pc_index = index;
            if (pending_nz) {
                cpu.NFlag = result >> 31;
                cpu.ZFlag = result == 0;
                pending_nz = false;
            }
        };
        while (i < length && retired + i < cpu.NumInstrsToExecute) {
            const auto &op = ops[i++];
            const auto lhs = regs[op.lhs];
            const auto rhs = op.rhs;
            auto transfer_address = [&](std::uint32_t offset) {
                // Slow-path callbacks see the context at the faulting instruction.
                synchronize(i - 1);
                return lhs + offset;
            };
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
                break;
            case opcode::constant: result = rhs; break;
            case opcode::bit_and: result = lhs & regs[rhs]; break;
            case opcode::bit_or: result = lhs | regs[rhs]; break;
            case opcode::bit_xor: result = lhs ^ regs[rhs]; break;
            case opcode::mul: result = lhs * regs[rhs]; break;
            case opcode::move_reg: regs[op.dst] = lhs; continue;
            case opcode::add_reg_no_flags: regs[op.dst] += lhs; continue;
            case opcode::load_word: regs[op.dst] = cpu.ReadMemory32(transfer_address(4u * rhs)); continue;
            case opcode::load_half: regs[op.dst] = cpu.ReadMemory16(transfer_address(2u * rhs)); continue;
            case opcode::store_word: cpu.WriteMemory32(transfer_address(4u * rhs), regs[op.dst]); continue;
            case opcode::store_half: cpu.WriteMemory16(transfer_address(2u * rhs), regs[op.dst]); continue;
            case opcode::load_word_reg: regs[op.dst] = cpu.ReadMemory32(transfer_address(regs[rhs])); continue;
            case opcode::load_half_reg: regs[op.dst] = cpu.ReadMemory16(transfer_address(regs[rhs])); continue;
            case opcode::store_word_reg: cpu.WriteMemory32(transfer_address(regs[rhs]), regs[op.dst]); continue;
            case opcode::store_half_reg: cpu.WriteMemory16(transfer_address(regs[rhs]), regs[op.dst]); continue;
            }
            pending_nz = true;
            if (op.code != opcode::cmp_imm)
                regs[op.dst] = result;
        }
        synchronize(i);
        return i;
    }
}
