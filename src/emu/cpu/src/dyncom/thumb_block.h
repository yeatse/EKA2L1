// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#pragma once

#include <bit>

#include <cpu/dyncom/armstate.h>
#include <cpu/dyncom/armsupp.h>

namespace eka2l1::arm::thumb_block {
    enum class opcode : std::uint8_t {
        lsl, lsr, asr, add, sub, add_imm, sub_imm, constant, cmp_imm,
        bit_and, bit_xor, bit_or, mul, load_word, load_half, store_word, store_half,
        load_word_reg, load_half_reg, store_word_reg, store_half_reg, move_reg, add_reg_no_flags,
        load_post, store_post, load_literal,
        lsr_and, lsl_lsr, mul_lsr, sub_mul, add_and, and_lsr
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
        } else if (group == 24 || group == 25) {
            const auto mask = static_cast<std::uint8_t>(hw);
            if (!std::has_single_bit(mask) || (mask & (1u << rd8)))
                return false;
            op = { group == 24 ? opcode::store_post : opcode::load_post,
                static_cast<std::uint8_t>(std::countr_zero(mask)), rd8, 0 };
        } else if (group == 9) {
            op = { opcode::load_literal, rd8, 0, static_cast<std::uint8_t>(hw) };
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

    // Keep the second operation intact so a quantum may end between the two writes.
    inline void fuse(operation *ops, unsigned length) {
        for (unsigned i = 1; i < length; ++i) {
            auto &left = ops[i - 1];
            const auto next = ops[i].code;
            if (left.code == opcode::lsr && next == opcode::bit_and)
                left.code = opcode::lsr_and;
            else if (left.code == opcode::lsl && next == opcode::lsr)
                left.code = opcode::lsl_lsr;
            else if (left.code == opcode::mul && next == opcode::lsr)
                left.code = opcode::mul_lsr;
            else if (left.code == opcode::sub && next == opcode::mul)
                left.code = opcode::sub_mul;
            else if (left.code == opcode::add && next == opcode::bit_and)
                left.code = opcode::add_and;
            else if (left.code == opcode::bit_and && next == opcode::lsr)
                left.code = opcode::and_lsr;
            else
                continue;
            ++i;
        }
    }

    template <opcode kind>
    inline std::uint32_t binary(ARMul_State &cpu, const operation &op) {
        const auto lhs = cpu.Reg[op.lhs];
        const auto rhs = op.rhs;
        if constexpr (kind == opcode::lsl) {
            if (rhs) cpu.CFlag = (lhs >> (32 - rhs)) & 1;
            return lhs << rhs;
        } else if constexpr (kind == opcode::lsr) {
            cpu.CFlag = (lhs >> (rhs ? rhs - 1 : 31)) & 1;
            return rhs ? lhs >> rhs : 0;
        } else if constexpr (kind == opcode::bit_and) {
            return lhs & cpu.Reg[rhs];
        } else if constexpr (kind == opcode::mul) {
            return lhs * cpu.Reg[rhs];
        } else {
            static_assert(kind == opcode::add || kind == opcode::sub);
            bool carry, overflow;
            const auto result = AddWithCarry(lhs, kind == opcode::add ? cpu.Reg[rhs] : ~cpu.Reg[rhs],
                kind == opcode::sub, &carry, &overflow);
            cpu.CFlag = carry;
            cpu.VFlag = overflow;
            return result;
        }
    }

    template <opcode first, opcode second>
    inline std::uint32_t execute_pair(ARMul_State &cpu, const operation *ops, unsigned &i, unsigned retired) {
        const auto &left = ops[i - 1];
        const auto result = binary<first>(cpu, left);
        cpu.Reg[left.dst] = result;
        if (retired + i >= cpu.NumInstrsToExecute)
            return result;
        const auto &right = ops[i++];
        return cpu.Reg[right.dst] = binary<second>(cpu, right);
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
            // A TLB miss can enter a callback that observes the faulting instruction.
            auto before_miss = [&] { synchronize(i - 1); };
            bool carry, overflow;
            switch (op.code) {
            case opcode::lsr_and:
                result = execute_pair<opcode::lsr, opcode::bit_and>(cpu, ops, i, retired);
                pending_nz = true;
                continue;
            case opcode::lsl_lsr:
                result = execute_pair<opcode::lsl, opcode::lsr>(cpu, ops, i, retired);
                pending_nz = true;
                continue;
            case opcode::mul_lsr:
                result = execute_pair<opcode::mul, opcode::lsr>(cpu, ops, i, retired);
                pending_nz = true;
                continue;
            case opcode::sub_mul:
                result = execute_pair<opcode::sub, opcode::mul>(cpu, ops, i, retired);
                pending_nz = true;
                continue;
            case opcode::add_and:
                result = execute_pair<opcode::add, opcode::bit_and>(cpu, ops, i, retired);
                pending_nz = true;
                continue;
            case opcode::and_lsr:
                result = execute_pair<opcode::bit_and, opcode::lsr>(cpu, ops, i, retired);
                pending_nz = true;
                continue;
            case opcode::lsl: result = binary<opcode::lsl>(cpu, op); break;
            case opcode::lsr: result = binary<opcode::lsr>(cpu, op); break;
            case opcode::asr:
                result = static_cast<std::int32_t>(lhs) >> (rhs ? rhs : 31);
                cpu.CFlag = (lhs >> (rhs ? rhs - 1 : 31)) & 1;
                break;
            case opcode::add: result = binary<opcode::add>(cpu, op); break;
            case opcode::add_imm:
                result = AddWithCarry(lhs, rhs, 0, &carry, &overflow);
                cpu.CFlag = carry;
                cpu.VFlag = overflow;
                break;
            case opcode::sub: result = binary<opcode::sub>(cpu, op); break;
            case opcode::sub_imm:
            case opcode::cmp_imm:
                result = AddWithCarry(lhs, ~std::uint32_t(rhs), 1, &carry, &overflow);
                cpu.CFlag = carry;
                cpu.VFlag = overflow;
                break;
            case opcode::constant: result = rhs; break;
            case opcode::bit_and: result = binary<opcode::bit_and>(cpu, op); break;
            case opcode::bit_or: result = lhs | regs[rhs]; break;
            case opcode::bit_xor: result = lhs ^ regs[rhs]; break;
            case opcode::mul: result = binary<opcode::mul>(cpu, op); break;
            case opcode::move_reg: regs[op.dst] = lhs; continue;
            case opcode::add_reg_no_flags: regs[op.dst] += lhs; continue;
            case opcode::load_literal: {
                const auto pc = regs[15] + 2 * (i - 1 - pc_index);
                const auto address = ((pc + 4) & ~3u) + 4u * rhs;
                regs[op.dst] = cpu.ReadMemory32(address, before_miss);
                continue;
            }
            case opcode::load_post:
            case opcode::store_post: {
                const auto address = lhs;
                regs[op.lhs] += 4;
                if (op.code == opcode::load_post)
                    regs[op.dst] = cpu.ReadMemory32(address, before_miss);
                else
                    cpu.WriteMemory32(address, regs[op.dst], before_miss);
                continue;
            }
            case opcode::load_word: regs[op.dst] = cpu.ReadMemory32(lhs + 4u * rhs, before_miss); continue;
            case opcode::load_half: regs[op.dst] = cpu.ReadMemory16(lhs + 2u * rhs, before_miss); continue;
            case opcode::store_word: cpu.WriteMemory32(lhs + 4u * rhs, regs[op.dst], before_miss); continue;
            case opcode::store_half: cpu.WriteMemory16(lhs + 2u * rhs, regs[op.dst], before_miss); continue;
            case opcode::load_word_reg: regs[op.dst] = cpu.ReadMemory32(lhs + regs[rhs], before_miss); continue;
            case opcode::load_half_reg: regs[op.dst] = cpu.ReadMemory16(lhs + regs[rhs], before_miss); continue;
            case opcode::store_word_reg: cpu.WriteMemory32(lhs + regs[rhs], regs[op.dst], before_miss); continue;
            case opcode::store_half_reg: cpu.WriteMemory16(lhs + regs[rhs], regs[op.dst], before_miss); continue;
            }
            pending_nz = true;
            if (op.code != opcode::cmp_imm)
                regs[op.dst] = result;
        }
        synchronize(i);
        return i;
    }
}
