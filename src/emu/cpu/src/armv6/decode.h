// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#pragma once
#include <bit>
#include <cstdint>
#include <cpu/dyncom/arm_dyncom_thumb.h>

namespace eka2l1::arm::armv6 {
    enum class opcode : std::uint8_t {
        empty,
        slow,
        data,
        transfer,
        multiple,
        branch,
        exchange,
        multiply,
        half,
        thumb_branch,
        thumb_prefix,
        thumb_call,
        supervisor,
        exclusive_read,
        exclusive_write,
        clear_exclusive,
        hint,
        read_status,
        write_flags,
        long_multiply,
        vfp_move,
        vfp_status,
        vfp_transfer,
        vfp_move_double,
        vfp_int_to_double,
        vfp_arithmetic,
        vfp_multiple
    };

    struct instruction {
        std::uint32_t bits;
        opcode op;
        std::uint8_t condition;
    };

    constexpr bool vfp_arithmetic(std::uint32_t bits) {
        if ((bits & 0x0f000e10) != 0x0e000a00)
            return false;
        const auto operation = (bits >> 20) & 11;
        if (operation < 4 || (operation == 8 && !(bits & 64)))
            return true;
        if (operation != 11 || !(bits & 64))
            return false;
        const auto kind = ((bits >> 15) & 30) | ((bits >> 7) & 1);
        return kind <= 3 || kind == 8 || kind == 9 || ((kind == 10 || kind == 11) && !(bits & 47))
            || kind == 15 || kind == 16 || kind == 17 || (kind >= 24 && kind <= 27);
    }

    constexpr bool vfp_multiple(std::uint32_t bits) {
        if ((bits & 0x0e000e00) != 0x0c000a00 || ((bits >> 16) & 15) == 15)
            return false;
        const bool up = bits & (1u << 23), pre = bits & (1u << 24), writeback = bits & (1u << 21);
        if (pre == up || (pre && !writeback))
            return false;
        const bool wide = bits & 256;
        const auto high = (bits >> 22) & 1;
        const auto first = 2 * ((bits >> 12) & 15) + (wide ? 32 * high : high);
        const auto words = bits & 255;
        return words && (!wide || (!(words & 1) && words <= 32)) && first + words <= (wide ? 64 : 32);
    }

    inline instruction decode(std::uint32_t bits, bool thumb) {
        if (thumb) {
            const auto half = static_cast<std::uint16_t>(bits);
            const auto group = half >> 11;
            if ((half >> 12) == 13 && ((half >> 8) & 15) < 14)
                return { half, opcode::thumb_branch, static_cast<std::uint8_t>((half >> 8) & 15) };
            if (group == 28)
                return { half, opcode::thumb_branch, 14 };
            if (group == 30)
                return { half, opcode::thumb_prefix, 14 };
            if (group == 31 || (group == 29 && !(half & 1)))
                return { half, opcode::thumb_call, 14 };
            if ((half & 0xff87) == 0x4780)
                return { 0xe12fff30u | ((half >> 3) & 15), opcode::exchange, 14 };
            std::uint32_t size;
            const auto status = TranslateThumbInstruction(0, half, &bits, &size);
            if (status == ThumbDecodeStatus::UNDEFINED || status == ThumbDecodeStatus::BRANCH)
                return { half, opcode::slow, 14 };
        }
        const auto cond = static_cast<std::uint8_t>(bits >> 28);
        auto op = opcode::slow;
        if (cond != 15) {
            if ((bits & 0x0ffffff0) == 0x012fff10 || (bits & 0x0ffffff0) == 0x012fff30)
                op = opcode::exchange;
            else if ((bits & 0x0fe00fd0) == 0x0c400b10 && ((bits >> 12) & 15) != 15 && ((bits >> 16) & 15) != 15)
                op = opcode::vfp_move_double;
            else if ((bits & 0x0fbf0f50) == 0x0eb80b40)
                op = opcode::vfp_int_to_double;
            else if (vfp_arithmetic(bits))
                op = opcode::vfp_arithmetic;
            else if (vfp_multiple(bits))
                op = opcode::vfp_multiple;
            else if ((bits & 0x0fe00f7f) == 0x0e000a10 && ((bits >> 12) & 15) != 15)
                op = opcode::vfp_move;
            else if ((bits & 0x0fef0fff) == 0x0ee10a10 && ((bits & (1u << 20)) || ((bits >> 12) & 15) != 15))
                op = opcode::vfp_status;
            else if ((bits & 0x0f200e00) == 0x0d000a00)
                op = opcode::vfp_transfer;
            else if ((bits & 0x0f900fff) == 0x01900f9f && ((bits >> 12) & 15) != 15)
                op = opcode::exclusive_read;
            else if ((bits & 0x0f900ff0) == 0x01800f90 && (bits & 15) != 15)
                op = opcode::exclusive_write;
            else if ((bits & 0x0fbf0fff) == 0x010f0000 && !(bits & 0x00400000))
                op = opcode::read_status;
            else if ((bits & 0x0ffff0f0) == 0x0128f000)
                op = opcode::write_flags;
            else if ((bits & 0x0f8000f0) == 0x00800090)
                op = opcode::long_multiply;
            else if ((bits & 0x0fc000f0) == 0x00000090)
                op = opcode::multiply;
            else if ((bits & 0x0e000090) == 0x00000090 && (bits & 0x01200000) != 0x00200000 && (bits & 0x60)
                && ((bits & (1u << 20)) || (bits & 0x60) == 0x20))
                op = opcode::half;
            else if ((bits & 0x0c000000) == 0 && ((bits >> 23 & 3) != 2 || (bits >> 20 & 1))
                && ((bits >> 25 & 1) || (bits & 0x90) != 0x90))
                op = opcode::data;
            else if ((bits & 0x0c000000) == 0x04000000 && (bits & 0x02000010) != 0x02000010)
                op = opcode::transfer;
            else if ((bits & 0x0e400000) == 0x08000000 && (bits & 0xffff))
                op = opcode::multiple;
            else if ((bits & 0x0f000000) == 0x0f000000)
                op = opcode::supervisor;
        }
        if ((bits & 0x0e000000) == 0x0a000000)
            op = opcode::branch;
        if ((bits & 0xfd70f000) == 0xf550f000 && (!(bits & (1u << 25)) || !(bits & 16)))
            op = opcode::hint;
        if (bits == 0xf57ff01f)
            op = opcode::clear_exclusive;
        if (op == opcode::data && (bits & 0x0010f000) == 0x0010f000)
            op = opcode::slow;
        return { bits, op, cond };
    }

    enum class arm_code : std::uint8_t {
        other,
        add_i,
        add_lsl,
        sub_i,
        mov_i,
        mov_lsl,
        cmp_r,
        cmp_i,
        branch,
        ldr,
        str,
        ldrb,
        strb,
        ldr_index,
        str_index,
        ldr_post,
        str_post,
        ldm,
        stm,
        call,
        bx,
        blx,
        ldr_pc_literal,
        ands_i
    };
    struct arm_op {
        arm_code code {};
        std::uint8_t d {}, a {}, b {}, shift {}, flags {}, cond {};
        std::uint32_t value {};
    };
    inline arm_op decode_arm_page(std::uint32_t bits) {
        auto ins = decode(bits, false);
        arm_op op;
        op.a = (bits >> 16) & 15;
        op.b = bits & 15;
        op.d = (bits >> 12) & 15;
        op.shift = (bits >> 7) & 31;
        op.cond = ins.condition;
        if (ins.op == opcode::exchange && op.b != 15) {
            op.code = bits & 32 ? arm_code::blx : arm_code::bx;
            return op;
        }
        if ((bits & 0x0f7ff000) == 0x051ff000 && ins.condition != 15) {
            op.code = arm_code::ldr_pc_literal;
            op.value = bits & (1u << 23) ? 8 + (bits & 4095) : 8 - (bits & 4095);
            return op;
        }
        if (ins.op == opcode::branch && ins.condition != 15) {
            op.code = bits & (1u << 24) ? arm_code::call : arm_code::branch;
            op.value = 2 + (static_cast<std::int32_t>(bits << 8) >> 8);
            return op;
        }
        if (ins.condition == 15 || op.a == 15 || op.d == 15)
            return op;
        const bool load = bits & (1 << 20);
        if (ins.op == opcode::data) {
            const unsigned kind = (bits >> 21) & 15;
            const bool imm = bits & (1 << 25);
            if (!imm && ((bits & 0x70) || op.b == 15))
                return op;
            if (kind == 10 && (imm || !op.shift))
                op.code = imm ? arm_code::cmp_i : arm_code::cmp_r;
            else if (load && kind == 0 && imm) {
                op.code = arm_code::ands_i;
                op.flags = (bits >> 8) & 15;
            } else if (!load && kind == 4)
                op.code = imm ? arm_code::add_i : arm_code::add_lsl;
            else if (!load && kind == 2 && imm)
                op.code = arm_code::sub_i;
            else if (!load && kind == 13)
                op.code = imm ? arm_code::mov_i : arm_code::mov_lsl;
            op.value = std::rotr(bits & 255u, static_cast<int>((bits >> 7) & 30));
        } else if (ins.op == opcode::multiple && !(bits & (1 << 21)) && !(bits & 0x8000)) {
            op.code = load ? arm_code::ldm : arm_code::stm;
            op.value = bits & 65535;
            op.shift = std::popcount(op.value);
            const bool up = bits & (1u << 23), pre = bits & (1u << 24);
            op.flags = up ? pre * 4 : (op.shift - !pre) * 4;
            if (!up)
                op.flags = -op.flags;
        } else if (ins.op == opcode::transfer) {
            bool imm = !(bits & (1 << 25)), pre = bits & (1 << 24), byte = bits & (1 << 22);
            bool up = bits & (1 << 23), wb = bits & (1 << 21);
            op.value = up ? bits & 4095 : -(bits & 4095);
            if (imm && pre && !wb)
                op.code = byte ? (load ? arm_code::ldrb : arm_code::strb) : (load ? arm_code::ldr : arm_code::str);
            else if (imm && !pre && !wb && !byte && op.a != op.d)
                op.code = load ? arm_code::ldr_post : arm_code::str_post;
            else if (!imm && pre && up && !byte && !(bits & 0x70) && op.b != 15 && (!wb || op.a != op.d)) {
                op.code = load ? arm_code::ldr_index : arm_code::str_index;
                op.flags = wb;
            }
        }
        return op;
    }
}
