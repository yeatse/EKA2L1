// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#include "decode.h"
#include "thumb.h"
#include <atomic>
#include <bit>
#include <cpu/12l1r/tlb.h>
#include <cpu/armv6.h>
#include <cpu/vfp.h>
#include <cpu/dyncom/arm_dyncom.h>
#include <cstring>
#include <unordered_map>

namespace eka2l1::arm {
    namespace {
        using namespace armv6;
        constexpr std::uint32_t N = 1u << 31, Z = 1u << 30, C = 1u << 29, V = 1u << 28, T = 1u << 5;

        bool passes(unsigned cond, std::uint32_t flags) {
            bool take;
            switch (cond >> 1) {
            case 0:
                take = flags & Z;
                break;
            case 1:
                take = flags & C;
                break;
            case 2:
                take = flags & N;
                break;
            case 3:
                take = flags & V;
                break;
            case 4:
                take = (flags & (C | Z)) == C;
                break;
            case 5:
                take = !((flags ^ (flags << 3)) & N);
                break;
            default:
                take = !(flags & Z) && !((flags ^ (flags << 3)) & N);
                break;
            }
            return take != static_cast<bool>(cond & 1);
        }

        std::uint32_t shift(std::uint32_t value, unsigned type, unsigned n, bool immediate, bool& carry) {
            if (!n && (!immediate || type == 0))
                return value;
            switch (type) {
            case 0:
                carry = n <= 32 && ((value >> (32 - n)) & 1);
                return n < 32 ? value << n : 0;
            case 1:
                if (!n)
                    n = 32;
                carry = n <= 32 && ((value >> (n - 1)) & 1);
                return n < 32 ? value >> n : 0;
            case 2:
                if (!n || n > 32)
                    n = 32;
                carry = (value >> (n - 1)) & 1;
                return static_cast<std::int32_t>(value) >> std::min(n, 31u);
            default:
                if (!n) {
                    const auto high = static_cast<std::uint32_t>(carry) << 31;
                    carry = value & 1;
                    return high | (value >> 1);
                }
                value = std::rotr(value, static_cast<int>(n));
                carry = value >> 31;
                return value;
            }
        }

        class interpreter final : public core {
            struct code_page {
                std::uint64_t key;
                std::unique_ptr<instruction[]> entries;
                std::unique_ptr<arm_op[]> arm_ops;
                std::unique_ptr<thumb::op[]> thumb_ops;
            };
            std::unordered_map<std::uint64_t, code_page> pages_;
            std::array<code_page*, 512> recent_ {};
            thread_context state_ {};
            r12l1::tlb tlb_ { 12 };
            exclusive_monitor* monitor_;
            std::unique_ptr<dyncom_core> slow_;
            std::uint32_t asid_ {}, retired_ {};
            bool tagged_ {}, in_slow_ {};
            std::atomic<bool> stopped_ {};

            void exchange(std::uint32_t target) {
                const bool thumb = target & 1;
                state_.cpsr = (state_.cpsr & ~T) | (thumb ? T : 0);
                state_.set_pc(target & (thumb ? ~1u : ~3u));
            }

            template <typename U, typename Callback>
            U access(address addr, U value, Callback& callback, bool write, bool code = false) {
                auto& entry = tlb_.entries[(addr >> 12) & r12l1::TLB_ENTRY_MASK];
                const auto tag = code ? entry.execute_addr : write ? entry.write_addr : entry.read_addr;
                const auto offset = addr & 4095;
                if (tag == (addr & ~4095u) && offset <= 4096 - sizeof(U)) {
                    if (write)
                        std::memcpy(entry.host_base + offset, &value, sizeof(U));
                    else
                        std::memcpy(&value, entry.host_base + offset, sizeof(U));
                } else if (!callback(addr, &value)
                    && exception_handler(
                        write ? exception_type_access_violation_write : exception_type_access_violation_read, addr)) {
                    callback(addr, &value);
                }
                return value;
            }

            template <typename U> U memory(address addr, bool load, U value = 0) {
                if constexpr (sizeof(U) == 1)
                    return access(addr, value, load ? read_8bit : write_8bit, !load);
                else if constexpr (sizeof(U) == 2)
                    return access(addr, value, load ? read_16bit : write_16bit, !load);
                else
                    return access(addr, value, load ? read_32bit : write_32bit, !load);
            }

            unsigned page_slot(std::uint32_t page, bool thumb) const {
                return ((page * 0x9e3779b9u) >> 23) ^ ((asid_ * 31u + thumb) & 511);
            }

            code_page& lookup_page(std::uint32_t page, bool thumb) {
                const auto key = (std::uint64_t(asid_) << 21) | (page << 1) | unsigned(thumb);
                auto& recent = recent_[page_slot(page, thumb)];
                if (recent && recent->key == key)
                    return *recent;
                auto found = pages_.find(key);
                if (found == pages_.end()) {
                    if (pages_.size() == 512) {
                        recent_.fill(nullptr);
                        pages_.clear();
                    }
                    found = pages_.try_emplace(key).first;
                    found->second.key = key;
                }
                recent = &found->second;
                return *recent;
            }

            instruction fetch(address pc, bool thumb) {
                const auto page = pc >> 12;
                const auto index = (pc & 4095) >> (thumb ? 1 : 2);
                auto& cached = lookup_page(page, thumb);
                if (cached.entries && cached.entries[index].op != opcode::empty)
                    return cached.entries[index];
                const auto word = access(pc & ~3u, 0u, read_code, false, true);
                const auto op = decode(thumb && (pc & 2) ? word >> 16 : word, thumb);
                auto& dest = lookup_page(page, thumb);
                if (!dest.entries)
                    dest.entries = std::make_unique<instruction[]>(thumb ? 2048 : 1024);
                dest.entries[index] = op;
                return op;
            }

            void run_arm_page(std::uint32_t budget);
            void run_thumb_page(std::uint32_t budget);

            void slow_step() {
                if (!slow_) {
                    slow_ = std::make_unique<dyncom_core>(monitor_, 12);
                    slow_->set_asid(asid_);
                    slow_->read_code = [this](auto... args) { return read_code(args...); };
                    slow_->read_8bit = [this](auto... args) { return read_8bit(args...); };
                    slow_->read_16bit = [this](auto... args) { return read_16bit(args...); };
                    slow_->read_32bit = [this](auto... args) { return read_32bit(args...); };
                    slow_->read_64bit = [this](auto... args) { return read_64bit(args...); };
                    slow_->write_8bit = [this](auto... args) { return write_8bit(args...); };
                    slow_->write_16bit = [this](auto... args) { return write_16bit(args...); };
                    slow_->write_32bit = [this](auto... args) { return write_32bit(args...); };
                    slow_->write_64bit = [this](auto... args) { return write_64bit(args...); };
                    slow_->exclusive_write_8bit = [this](auto... args) { return exclusive_write_8bit(args...); };
                    slow_->exclusive_write_16bit = [this](auto... args) { return exclusive_write_16bit(args...); };
                    slow_->exclusive_write_32bit = [this](auto... args) { return exclusive_write_32bit(args...); };
                    slow_->exclusive_write_64bit = [this](auto... args) { return exclusive_write_64bit(args...); };
                    slow_->system_call_handler = [this](auto... args) { return system_call_handler(args...); };
                    slow_->exception_handler = [this](exception_type type, address addr) {
                        if (type == exception_type_undefined_inst)
                            stop();
                        return exception_handler(type, addr);
                    };
                }
                slow_->set_core_number(core_number());
                slow_->load_context(state_);
                in_slow_ = true;
                slow_->step();
                slow_->save_context(state_);
                in_slow_ = false;
            }

            void execute(instruction op, std::uint32_t pc, unsigned size);

        public:
            explicit interpreter(exclusive_monitor* monitor)
                : monitor_(monitor) {
                state_.cpsr = 0x10;
                state_.set_sp(0x10000000);
            }
            void run(std::uint32_t budget) override {
                stopped_ = false;
                retired_ = 0;
                while (!stopped_ && retired_ < budget) {
                    const bool thumb = state_.cpsr & T;
                    const auto pc = state_.get_pc() & (thumb ? ~1u : ~3u);
                    state_.set_pc(pc);
                    if (!(state_.cpsr & 0x200)) {
                        auto limit = retired_ + std::min(budget - retired_, 256u);
                        if (thumb)
                            run_thumb_page(limit);
                        else
                            run_arm_page(limit);
                        if (retired_ == budget || stopped_ || state_.get_pc() != pc || bool(state_.cpsr & T) != thumb)
                            continue;
                    }
                    auto op = fetch(pc, thumb);
                    if (stopped_)
                        break;
                    ++retired_;
                    if (op.condition < 14 && !passes(op.condition, state_.cpsr))
                        state_.set_pc(pc + (thumb ? 2 : 4));
                    else if (state_.cpsr & 0x200)
                        slow_step();
                    else
                        execute(op, pc, thumb ? 2 : 4);
                }
            }
            void stop() override {
                stopped_ = true;
                if (in_slow_)
                    slow_->stop();
            }
            void step() override { run(1); }
            void save_context(thread_context& ctx) override {
                if (in_slow_)
                    slow_->save_context(ctx);
                else
                    ctx = state_;
            }
            void load_context(const thread_context& ctx) override {
                state_ = ctx;
                if (in_slow_)
                    slow_->load_context(ctx);
                if (!tagged_)
                    clear_instruction_cache();
            }
            void set_asid(std::uint32_t asid) override {
                asid_ = asid;
                tagged_ = true;
                if (slow_)
                    slow_->set_asid(asid);
            }
            void clear_instruction_cache() override {
                recent_.fill(nullptr);
                pages_.clear();
                if (slow_)
                    slow_->clear_instruction_cache();
            }
            void imb_range(address addr, std::size_t size) override { clear_instruction_cache(); }
            void flush_tlb() override {
                tlb_.flush();
                if (slow_)
                    slow_->flush_tlb();
            }
            void set_tlb_page(address addr, std::uint8_t* ptr, prot perm) override {
                tlb_.add(addr, ptr, perm);
                if (slow_)
                    slow_->set_tlb_page(addr, ptr, perm);
            }
            void dirty_tlb_page(address addr) override {
                tlb_.make_dirty(addr);
                if (slow_)
                    slow_->dirty_tlb_page(addr);
            }
            bool should_clear_old_memory_map() const override { return false; }
            std::uint32_t get_num_instruction_executed() override { return retired_; }
            std::uint32_t get_pc() override { return get_reg(15); }
            std::uint32_t get_lr() override { return get_reg(14); }
            std::uint32_t get_sp() override { return get_reg(13); }
            void set_pc(std::uint32_t v) override { set_reg(15, v); }
            void set_lr(std::uint32_t v) override { set_reg(14, v); }
            void set_sp(std::uint32_t v) override { set_reg(13, v); }
            bool is_thumb_mode() override { return get_cpsr() & T; }
            std::uint32_t get_reg(std::size_t i) override {
                return in_slow_ ? slow_->get_reg(i) : state_.cpu_registers[i];
            }
            void set_reg(std::size_t i, std::uint32_t v) override {
                if (in_slow_)
                    slow_->set_reg(i, v);
                else
                    state_.cpu_registers[i] = v;
            }
            std::uint32_t get_cpsr() override { return in_slow_ ? slow_->get_cpsr() : state_.cpsr; }
            void set_cpsr(std::uint32_t v) override {
                if (in_slow_)
                    slow_->set_cpsr(v);
                else
                    state_.cpsr = v;
            }
            std::uint32_t get_fpscr() override { return in_slow_ ? slow_->get_fpscr() : state_.fpscr; }
            void set_fpscr(std::uint32_t v) override {
                if (in_slow_)
                    slow_->set_fpscr(v);
                else
                    state_.fpscr = v;
            }
            std::uint32_t get_vfp(std::size_t i) override {
                return in_slow_ ? slow_->get_vfp(i) : state_.fpu_registers[i];
            }
            void set_vfp(std::size_t i, std::uint32_t v) override {
                if (in_slow_)
                    slow_->set_vfp(i, v);
                else
                    state_.fpu_registers[i] = v;
            }
        };

        void interpreter::run_arm_page(std::uint32_t budget) {
            const auto start = state_.get_pc(), base = start & ~4095u;
            auto& slot = lookup_page(base >> 12, false);
            if (!slot.arm_ops) {
                auto& entry = tlb_.entries[(base >> 12) & r12l1::TLB_ENTRY_MASK];
                if (entry.execute_addr != base)
                    return;
                slot.arm_ops = std::make_unique_for_overwrite<arm_op[]>(1024);
                for (unsigned i = 0; i < 1024; ++i) {
                    std::uint32_t bits;
                    std::memcpy(&bits, entry.host_base + 4 * i, 4);
                    slot.arm_ops[i] = decode_arm_page(bits);
                }
            }
            const auto* ops = slot.arm_ops.get();
            auto& regs = state_.cpu_registers;
            auto index = (start & 4095) >> 2;
            auto remaining = budget - retired_;
            auto flags = state_.cpsr;
            auto ptr = [&](unsigned addr, unsigned size, bool write) -> std::uint8_t* {
                auto& entry = tlb_.entries[(addr >> 12) & r12l1::TLB_ENTRY_MASK];
                if ((write ? entry.write_addr : entry.read_addr) != (addr & ~4095u) || (addr & 4095) > 4096 - size)
                    return nullptr;
                return entry.host_base + (addr & 4095);
            };
            auto transfer = [&]<bool write, bool byte>(unsigned addr, std::uint32_t& value) {
                auto* p = ptr(addr, byte ? 1 : 4, write);
                if (!p)
                    return false;
                if constexpr (write && byte)
                    *p = static_cast<std::uint8_t>(value);
                else if constexpr (write)
                    std::memcpy(p, &value, 4);
                else if constexpr (byte)
                    value = *p;
                else
                    std::memcpy(&value, p, 4);
                return true;
            };
            while (index < 1024 && remaining) {
                const auto op = ops[index];
                using enum arm_code;
                auto a = regs[op.a];
                auto& d = regs[op.d];
                if (op.cond < 14 && !passes(op.cond, flags))
                    goto advance_arm;
                switch (op.code) {
                case other:
                    goto done;
                case add_i:
                    d = a + op.value;
                    break;
                case sub_i:
                    d = a - op.value;
                    break;
                case add_lsl:
                    d = a + (regs[op.b] << op.shift);
                    break;
                case mov_i:
                    d = op.value;
                    break;
                case mov_lsl:
                    d = regs[op.b] << op.shift;
                    break;
                case cmp_i:
                case cmp_r: {
                    auto b = op.code == cmp_i ? op.value : regs[op.b];
                    auto r = a - b;
                    flags = (flags & 0x0fffffffu) | (r & N) | (r ? 0 : Z) | (a >= b ? C : 0)
                        | (((a ^ b) & (a ^ r)) >> 31 ? V : 0);
                    break;
                }
                case ands_i:
                    d = a & op.value;
                    flags = (flags & ~(N | Z)) | (d & N) | (d ? 0 : Z);
                    if (op.flags)
                        flags = (flags & ~C) | ((op.value & N) ? C : 0);
                    break;
                case call:
                    regs[14] = base + 4 * index + 4;
                    [[fallthrough]];
                case branch:
                    index += op.value - 1;
                    break;
                case blx:
                case bx:
                case ldr_pc_literal: {
                    auto target = regs[op.b];
                    if (op.code == ldr_pc_literal
                        && !transfer.template operator()<false, false>(base + 4 * index + op.value, target))
                        goto done;
                    if (op.code == blx)
                        regs[14] = base + 4 * index + 4;
                    if (target & 1) {
                        retired_ = budget - remaining + 1;
                        state_.cpsr = flags | T;
                        state_.set_pc(target & ~1u);
                        return;
                    }
                    index = ((target - base) >> 2) - 1;
                    break;
                }
                case ldr: {
                    const auto updated = a + op.value;
                    if (!transfer.template operator()<false, false>(updated, d))
                        goto done;
                    break;
                }
                case str: {
                    const auto updated = a + op.value;
                    if (!transfer.template operator()<true, false>(updated, d))
                        goto done;
                    break;
                }
                case ldrb: {
                    const auto updated = a + op.value;
                    if (!transfer.template operator()<false, true>(updated, d))
                        goto done;
                    break;
                }
                case strb: {
                    const auto updated = a + op.value;
                    if (!transfer.template operator()<true, true>(updated, d))
                        goto done;
                    break;
                }
                case ldr_index: {
                    const auto updated = a + (regs[op.b] << op.shift);
                    if (!transfer.template operator()<false, false>(updated, d))
                        goto done;
                    if (op.flags)
                        regs[op.a] = updated;
                    break;
                }
                case str_index: {
                    const auto updated = a + (regs[op.b] << op.shift);
                    if (!transfer.template operator()<true, false>(updated, d))
                        goto done;
                    if (op.flags)
                        regs[op.a] = updated;
                    break;
                }
                case ldr_post: {
                    const auto updated = a + op.value;
                    if (!transfer.template operator()<false, false>(a, d))
                        goto done;
                    regs[op.a] = updated;
                    break;
                }
                case str_post: {
                    const auto updated = a + op.value;
                    if (!transfer.template operator()<true, false>(a, d))
                        goto done;
                    regs[op.a] = updated;
                    break;
                }
                case ldm:
                case stm: {
                    const bool store = op.code == stm;
                    auto* p = ptr(a + static_cast<std::int8_t>(op.flags), 4 * op.shift, store);
                    if (!p)
                        goto done;
                    for (auto mask = op.value; mask; mask &= mask - 1, p += 4) {
                        auto& r = regs[std::countr_zero(mask)];
                        if (store)
                            std::memcpy(p, &r, 4);
                        else
                            std::memcpy(&r, p, 4);
                    }
                    break;
                }
                }
            advance_arm:
                ++index;
                --remaining;
            }
        done:
            retired_ = budget - remaining;
            state_.cpsr = flags;
            state_.set_pc(base + 4 * index);
        }

        void interpreter::run_thumb_page(std::uint32_t budget) {
            const auto start = state_.get_pc();
            const auto base = start & ~4095u;
            auto& slot = lookup_page(base >> 12, true);
            if (!slot.thumb_ops) {
                auto& entry = tlb_.entries[(base >> 12) & r12l1::TLB_ENTRY_MASK];
                if (entry.execute_addr != base)
                    return;
                slot.thumb_ops = std::make_unique_for_overwrite<thumb::op[]>(2048);
                for (unsigned i = 0; i < 2048; ++i) {
                    std::uint16_t bits;
                    std::memcpy(&bits, entry.host_base + 2 * i, sizeof(bits));
                    slot.thumb_ops[i] = thumb::decode(bits);
                    if (i)
                        thumb::fuse(slot.thumb_ops[i - 1], slot.thumb_ops[i]);
                }
            }
            auto& regs = state_.cpu_registers;
            const auto* ops = slot.thumb_ops.get();
            unsigned index = (start & 4095) >> 1;
            bool n = state_.cpsr & N, z = state_.cpsr & Z, c = state_.cpsr & C, v = state_.cpsr & V;
            auto commit = [&] {
                state_.set_pc(base + 2 * index);
                state_.cpsr = (state_.cpsr & ~(N | Z | C | V)) | (n ? N : 0) | (z ? Z : 0) | (c ? C : 0) | (v ? V : 0);
            };
            auto add_flags = [&](std::uint32_t a, std::uint32_t b) {
                const auto r = a + b;
                c = r < a;
                v = (~(a ^ b) & (a ^ r)) >> 31;
                return r;
            };
            auto sub_flags = [&](std::uint32_t a, std::uint32_t b) {
                const auto r = a - b;
                c = a >= b;
                v = ((a ^ b) & (a ^ r)) >> 31;
                return r;
            };
            auto transfer = [&]<typename U, bool store>(address addr, unsigned dst) {
                const auto& entry = tlb_.entries[(addr >> 12) & r12l1::TLB_ENTRY_MASK];
                const auto offset = addr & 4095;
                if ((store ? entry.write_addr : entry.read_addr) != (addr & ~4095u) || offset > 4096 - sizeof(U))
                    return false;
                auto* ptr = entry.host_base + offset;
                U value;
                if constexpr (store) {
                    value = static_cast<U>(regs[dst]);
                    std::memcpy(ptr, &value, sizeof(U));
                } else {
                    std::memcpy(&value, ptr, sizeof(U));
                    regs[dst] = value;
                }
                return true;
            };
            auto remaining = budget - retired_;
            while (index < 2048 && remaining) {
                const auto op = ops[index];
                using enum thumb::code;
                auto lhs = regs[op.lhs];
                const unsigned rhs = op.rhs;
                std::uint32_t result;
                switch (op.kind) {
                case mov_lsl:
                    result = lhs;
                    if (remaining > 1) {
                        const auto amount = ops[++index].rhs;
                        c = (lhs >> (32 - amount)) & 1;
                        result <<= amount;
                        --remaining;
                    }
                    break;
                case cmp_branch: {
                    const auto right = regs[rhs];
                    result = sub_flags(lhs, right);
                    n = result >> 31;
                    z = result == 0;
                    if (remaining > 1) {
                        const auto branch = ops[++index];
                        bool take;
                        switch (branch.dst >> 1) {
                        case 0:
                            take = z;
                            break;
                        case 1:
                            take = c;
                            break;
                        case 2:
                            take = n;
                            break;
                        case 3:
                            take = v;
                            break;
                        case 4:
                            take = lhs > right;
                            break;
                        case 5:
                            take = static_cast<std::int32_t>(lhs) >= static_cast<std::int32_t>(right);
                            break;
                        default:
                            take = static_cast<std::int32_t>(lhs) > static_cast<std::int32_t>(right);
                            break;
                        }
                        if (take != bool(branch.dst & 1))
                            index += 1 + static_cast<std::int8_t>(branch.rhs);
                        --remaining;
                    }
                    goto advance;
                }
                case mov_i:
                    result = rhs;
                    break;
                case lsl:
                    result = lhs << rhs;
                    if (rhs)
                        c = (lhs >> (32 - rhs)) & 1;
                    break;
                case lsr:
                case asr:
                    result = shift(lhs, op.kind == lsr ? 1 : 2, rhs, true, c);
                    break;
                case lsl_r:
                case lsr_r:
                case asr_r:
                case ror: {
                    unsigned type = op.kind == ror ? 3 : static_cast<unsigned>(op.kind) - static_cast<unsigned>(lsl_r);
                    result = shift(lhs, type, regs[rhs] & 255, false, c);
                    break;
                }
                case add_i:
                    result = add_flags(lhs, rhs);
                    break;
                case sub_i:
                case cmp_i:
                    result = sub_flags(lhs, rhs);
                    break;
                case thumb::code::add:
                    result = add_flags(lhs, regs[rhs]);
                    break;
                case thumb::code::sub:
                case cmp:
                case cmp_high:
                    result = sub_flags(lhs, regs[rhs]);
                    break;
                case neg:
                    result = sub_flags(0, regs[rhs]);
                    break;
                case cmn:
                    result = add_flags(lhs, regs[rhs]);
                    break;
                case mul:
                    result = lhs * regs[rhs];
                    break;
                case bit_and:
                case tst:
                    result = lhs & regs[rhs];
                    break;
                case bit_xor:
                    result = lhs ^ regs[rhs];
                    break;
                case bit_or:
                    result = lhs | regs[rhs];
                    break;
                case mvn:
                    result = ~regs[rhs];
                    break;
                case bic:
                    result = lhs & ~regs[rhs];
                    break;
                case mov:
                    regs[op.dst] = regs[rhs];
                    goto advance;
                case add_high:
                    regs[op.dst] += regs[rhs];
                    goto advance;
                case adr:
                    regs[op.dst] = (op.lhs == 15 ? (base + 2 * index + 4) & ~3u : lhs) + 4 * rhs;
                    goto advance;
                case sp_add:
                    regs[13] += 4 * rhs;
                    goto advance;
                case sp_sub:
                    regs[13] -= 4 * rhs;
                    goto advance;
                case call_hi:
                    regs[14] = base + 2 * index + 4 + (static_cast<std::uint32_t>((op.lhs << 8) | rhs) << 12);
                    if (op.lhs & 4)
                        regs[14] -= 1u << 23;
                    goto advance;
                case call_lo: {
                    const auto target = regs[14] + (((op.lhs << 8) | rhs) << 1);
                    regs[14] = (base + 2 * index + 2) | 1;
                    index = (target - base) / 2 - 1;
                    goto advance;
                }
                case multi_load:
                case multi_store: {
                    const bool stack = op.lhs == 13;
                    const bool load = op.kind == multi_load;
                    const unsigned mask = rhs | (op.dst << (load ? 15 : 14));
                    const auto bytes = 4u * std::popcount(mask);
                    const auto address = stack && !load ? lhs - bytes : lhs;
                    const auto offset = address & 4095;
                    const auto& entry = tlb_.entries[(address >> 12) & r12l1::TLB_ENTRY_MASK];
                    if ((load ? entry.read_addr : entry.write_addr) != (address & ~4095u) || offset + bytes > 4096)
                        goto done;
                    auto* ptr = entry.host_base + offset;
                    regs[op.lhs] = stack && !load ? address : lhs + bytes;
                    for (auto pending = mask; pending; pending &= pending - 1, ptr += 4) {
                        const auto r = std::countr_zero(pending);
                        if (load)
                            std::memcpy(&regs[r], ptr, 4);
                        else
                            std::memcpy(ptr, &regs[r], 4);
                    }
                    if (load && (mask & 0x8000)) {
                        auto target = regs[15];
                        --remaining;
                        retired_ = budget - remaining;
                        commit();
                        exchange(target);
                        return;
                    }
                    goto advance;
                }
                case branch_cond: {
                    bool taken;
                    switch (op.dst >> 1) {
                    case 0:
                        taken = z;
                        break;
                    case 1:
                        taken = c;
                        break;
                    case 2:
                        taken = n;
                        break;
                    case 3:
                        taken = v;
                        break;
                    case 4:
                        taken = c && !z;
                        break;
                    case 5:
                        taken = n == v;
                        break;
                    default:
                        taken = !z && n == v;
                        break;
                    }
                    if (taken != bool(op.dst & 1))
                        index += 1 + static_cast<std::int8_t>(rhs);
                    goto advance;
                }
                case branch:
                    index += 1 + (static_cast<std::int32_t>(((op.lhs << 8) | rhs) << 21) >> 21);
                    goto advance;
                case ldr_pc:
                    lhs = (base + 2 * index + 4) & ~3u;
                    [[fallthrough]];
                case ldr:
                    if (!transfer.template operator()<std::uint32_t, false>(lhs + 4 * rhs, op.dst))
                        goto done;
                    goto advance;
                case str:
                    if (!transfer.template operator()<std::uint32_t, true>(lhs + 4 * rhs, op.dst))
                        goto done;
                    goto advance;
                case ldrb:
                    if (!transfer.template operator()<std::uint8_t, false>(lhs + rhs, op.dst))
                        goto done;
                    goto advance;
                case strb:
                    if (!transfer.template operator()<std::uint8_t, true>(lhs + rhs, op.dst))
                        goto done;
                    goto advance;
                case ldrh:
                    if (!transfer.template operator()<std::uint16_t, false>(lhs + 2 * rhs, op.dst))
                        goto done;
                    goto advance;
                case strh:
                    if (!transfer.template operator()<std::uint16_t, true>(lhs + 2 * rhs, op.dst))
                        goto done;
                    goto advance;
                case ldr_r:
                    if (!transfer.template operator()<std::uint32_t, false>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                case str_r:
                    if (!transfer.template operator()<std::uint32_t, true>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                case ldrb_r:
                    if (!transfer.template operator()<std::uint8_t, false>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                case strb_r:
                    if (!transfer.template operator()<std::uint8_t, true>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                case ldrh_r:
                    if (!transfer.template operator()<std::uint16_t, false>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                case strh_r:
                    if (!transfer.template operator()<std::uint16_t, true>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                case ldrsb_r:
                    if (!transfer.template operator()<std::int8_t, false>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                case ldrsh_r:
                    if (!transfer.template operator()<std::int16_t, false>(lhs + regs[rhs], op.dst))
                        goto done;
                    goto advance;
                default:
                    goto done;
                }
                n = result >> 31;
                z = result == 0;
                if (op.kind != cmp && op.kind != cmp_i && op.kind != cmp_high && op.kind != tst && op.kind != cmn)
                    regs[op.dst] = result;
            advance:
                ++index;
                --remaining;
            }
        done:
            retired_ = budget - remaining;
            commit();
        }

        void interpreter::execute(instruction op, std::uint32_t pc, unsigned size) {
            const auto bits = op.bits;
            const unsigned rn = bits >> 16 & 15, rd = bits >> 12 & 15, rm = bits & 15;
            auto& regs = state_.cpu_registers;
            const auto next = pc + size;
            auto reg = [&](unsigned index) { return index == 15 ? pc + 2 * size : regs[index]; };
            auto& flags = state_.cpsr;
            auto nz = [&](std::uint32_t value) { flags = (flags & ~(N | Z)) | (value & N) | (value ? 0 : Z); };
            switch (op.op) {
            case opcode::thumb_prefix:
                regs[14] = pc + 4 + (static_cast<std::uint32_t>(static_cast<std::int32_t>(bits << 21) >> 21) << 12);
                break;
            case opcode::thumb_call: {
                auto target = regs[14] + ((bits & 2047) << 1);
                regs[14] = next | 1;
                exchange((bits >> 11) == 31 ? target | 1 : target & ~3u);
                return;
            }
            case opcode::thumb_branch: {
                const auto off = (bits >> 11) == 28 ? static_cast<std::int32_t>(bits << 21) >> 20
                                                    : static_cast<std::int32_t>(bits << 24) >> 23;
                regs[15] = pc + 4 + off;
                return;
            }
            case opcode::branch: {
                auto target = pc + 8 + (static_cast<std::int32_t>(bits << 8) >> 6);
                if (op.condition == 15) {
                    regs[14] = next;
                    exchange(target | ((bits >> 23) & 2) | 1);
                } else {
                    if (bits & (1 << 24))
                        regs[14] = next;
                    regs[15] = target;
                }
                return;
            }
            case opcode::exchange: {
                const auto target = reg(rm);
                if (bits & 0x20)
                    regs[14] = next | (size == 2);
                exchange(target);
                return;
            }
            case opcode::hint:
                break;
            case opcode::read_status:
                regs[rd] = flags;
                break;
            case opcode::write_flags:
                flags = (flags & ~0xf8000000u) | (regs[rm] & 0xf8000000u);
                break;
            case opcode::long_multiply: {
                const auto a = regs[rm], b = regs[bits >> 8 & 15];
                std::uint64_t value = bits & (1u << 22)
                    ? static_cast<std::uint64_t>(
                          std::int64_t(static_cast<std::int32_t>(a)) * static_cast<std::int32_t>(b))
                    : std::uint64_t(a) * b;
                if (bits & (1u << 21))
                    value += (std::uint64_t(regs[rn]) << 32) | regs[rd];
                regs[rd] = static_cast<std::uint32_t>(value);
                regs[rn] = static_cast<std::uint32_t>(value >> 32);
                if (bits & (1u << 20))
                    flags = (flags & ~(N | Z)) | (regs[rn] & N) | (value ? 0 : Z);
                break;
            }
            case opcode::vfp_arithmetic: {
                vfp_register_view view { state_.fpu_registers };
                const auto exceptions = bits & (1u << 8) ? vfp_double_cpdo(&view, bits, state_.fpscr)
                                                         : vfp_single_cpdo(&view, bits, state_.fpscr, true);
                if (exceptions)
                    state_.fpscr = vfp_apply_exceptions(exceptions, bits, state_.fpscr);
                break;
            }
            case opcode::vfp_move_double: {
                const unsigned first = 2 * rm + ((bits & 32) ? 32 : 0);
                if (bits & (1u << 20)) {
                    regs[rd] = state_.fpu_registers[first];
                    regs[rn] = state_.fpu_registers[first + 1];
                } else {
                    state_.fpu_registers[first] = regs[rd];
                    state_.fpu_registers[first + 1] = regs[rn];
                }
                break;
            }
            case opcode::vfp_int_to_double: {
                if (state_.fpscr & (7u << 16)) {
                    slow_step();
                    return;
                }
                const auto raw = state_.fpu_registers[2 * rm + ((bits >> 5) & 1)];
                // Every signed and unsigned 32-bit integer is exactly representable in binary64.
                const double value = bits & 128 ? double(static_cast<std::int32_t>(raw)) : double(raw);
                const auto pair = std::bit_cast<std::uint64_t>(value);
                const unsigned first = 2 * rd + ((bits & (1u << 22)) ? 32 : 0);
                state_.fpu_registers[first] = static_cast<std::uint32_t>(pair);
                state_.fpu_registers[first + 1] = static_cast<std::uint32_t>(pair >> 32);
                break;
            }
            case opcode::vfp_move: {
                auto& single = state_.fpu_registers[2 * rn + ((bits >> 7) & 1)];
                if (bits & (1u << 20))
                    regs[rd] = single;
                else
                    single = regs[rd];
                break;
            }
            case opcode::vfp_status:
                if (!(bits & (1u << 20)))
                    state_.fpscr = regs[rd];
                else if (rd == 15)
                    flags = (flags & 0x0fffffffu) | (state_.fpscr & 0xf0000000u);
                else
                    regs[rd] = state_.fpscr;
                break;
            case opcode::vfp_multiple:
            case opcode::vfp_transfer: {
                const bool multiple = op.op == opcode::vfp_multiple;
                const bool load = bits & (1u << 20), wide = bits & (1u << 8);
                const unsigned high = (bits >> 22) & 1;
                const unsigned first = 2 * rd + (wide ? 32 * high : high);
                const auto offset = (bits & 255) * 4;
                const auto base = rn == 15 ? reg(rn) & ~3u : reg(rn);
                const auto updated = bits & (1u << 23) ? base + offset : base - offset;
                const auto addr = multiple && (bits & (1u << 23)) ? base : updated;
                const auto count = multiple ? bits & 255 : wide ? 2u : 1u;
                auto* words = state_.fpu_registers.data() + first;
                const auto& entry = tlb_.entries[(addr >> 12) & r12l1::TLB_ENTRY_MASK];
                if ((load ? entry.read_addr : entry.write_addr) == (addr & ~4095u) && (addr & 4095) + count * 4 <= 4096) {
                    auto* host = entry.host_base + (addr & 4095);
                    if (load)
                        std::memcpy(words, host, 4 * count);
                    else
                        std::memcpy(host, words, 4 * count);
                } else {
                    for (unsigned i = 0; i < count; ++i) {
                        if (load)
                            words[i] = memory<std::uint32_t>(addr + 4 * i, true);
                        else
                            memory<std::uint32_t>(addr + 4 * i, false, words[i]);
                    }
                }
                if (multiple && (bits & (1u << 21)))
                    regs[rn] = updated;
                break;
            }
            case opcode::clear_exclusive:
                monitor_->clear_exclusive();
                break;
            case opcode::exclusive_read: {
                const auto addr = regs[rn];
                switch ((bits >> 21) & 3) {
                case 0:
                    regs[rd] = monitor_->exclusive_read32(this, addr);
                    break;
                case 1: {
                    const auto value = monitor_->exclusive_read64(this, addr);
                    regs[rd] = static_cast<std::uint32_t>(value);
                    regs[rd + 1] = static_cast<std::uint32_t>(value >> 32);
                    break;
                }
                case 2:
                    regs[rd] = monitor_->exclusive_read8(this, addr);
                    break;
                case 3:
                    regs[rd] = monitor_->exclusive_read16(this, addr);
                    break;
                }
                break;
            }
            case opcode::exclusive_write: {
                const auto addr = regs[rn];
                bool success;
                switch ((bits >> 21) & 3) {
                case 0:
                    success = monitor_->exclusive_write32(this, addr, regs[rm]);
                    break;
                case 1:
                    success = monitor_->exclusive_write64(this, addr, (std::uint64_t(regs[rm + 1]) << 32) | regs[rm]);
                    break;
                case 2:
                    success = monitor_->exclusive_write8(this, addr, static_cast<std::uint8_t>(regs[rm]));
                    break;
                default:
                    success = monitor_->exclusive_write16(this, addr, static_cast<std::uint16_t>(regs[rm]));
                    break;
                }
                regs[rd] = !success;
                break;
            }
            case opcode::supervisor:
                regs[15] = next;
                system_call_handler(bits & 0xffffff);
                monitor_->clear_exclusive();
                return;
            case opcode::data: {
                const unsigned kind = bits >> 21 & 15;
                bool carry = flags & C;
                const bool cin = carry;
                std::uint32_t rhs;
                if (bits & (1 << 25)) {
                    const auto rotate = (bits >> 7) & 30;
                    rhs = std::rotr(bits & 255u, static_cast<int>(rotate));
                    if (rotate)
                        carry = rhs >> 31;
                } else {
                    const bool immediate = !(bits & 16);
                    const auto amount = immediate ? (bits >> 7 & 31) : (reg(bits >> 8 & 15) & 255);
                    rhs = shift(reg(rm) + (!immediate && rm == 15 ? size : 0), bits >> 5 & 3, amount, immediate, carry);
                }
                auto lhs = reg(rn);
                if (size == 2 && rn == 15 && (bits & (1 << 25)))
                    lhs &= ~3u;
                std::uint32_t result;
                bool overflow = flags & V;
                switch (kind) {
                case 0:
                case 8:
                    result = lhs & rhs;
                    break;
                case 1:
                case 9:
                    result = lhs ^ rhs;
                    break;
                case 12:
                    result = lhs | rhs;
                    break;
                case 13:
                    result = rhs;
                    break;
                case 14:
                    result = lhs & ~rhs;
                    break;
                case 15:
                    result = ~rhs;
                    break;
                default: {
                    if (kind == 3 || kind == 7)
                        std::swap(lhs, rhs);
                    const bool sub = kind == 2 || kind == 3 || kind == 6 || kind == 7 || kind == 10;
                    if (sub)
                        rhs = ~rhs;
                    const bool extra = kind >= 5 && kind <= 7 ? cin : sub;
                    const auto sum = static_cast<std::uint64_t>(lhs) + rhs + extra;
                    result = static_cast<std::uint32_t>(sum);
                    carry = sum >> 32;
                    overflow = (~(lhs ^ rhs) & (lhs ^ result)) >> 31;
                    break;
                }
                }
                if (bits & (1 << 20)) {
                    nz(result);
                    flags = (flags & ~(C | V)) | (carry ? C : 0) | (overflow ? V : 0);
                }
                if (kind < 8 || kind > 11) {
                    if (rd == 15) {
                        regs[15] = result & ~(size - 1);
                        return;
                    }
                    regs[rd] = result;
                }
                break;
            }
            case opcode::multiply: {
                auto result = regs[rm] * regs[bits >> 8 & 15];
                if (bits & (1 << 21))
                    result += regs[rd];
                regs[rn] = result;
                if (bits & (1 << 20))
                    nz(result);
                break;
            }
            case opcode::transfer:
            case opcode::half: {
                const bool half = op.op == opcode::half, load = bits & (1 << 20);
                const bool pre = bits & (1 << 24), wb = !pre || (bits & (1 << 21));
                std::uint32_t offset;
                if (half)
                    offset = bits & (1 << 22) ? ((bits >> 4) & 0xf0) | rm : regs[rm];
                else if (bits & (1 << 25)) {
                    bool carry = flags & C;
                    offset = shift(reg(rm), bits >> 5 & 3, bits >> 7 & 31, true, carry);
                } else
                    offset = bits & 4095;
                auto base = reg(rn);
                if (rn == 15 && size == 2)
                    base &= ~3u;
                const auto updated = bits & (1 << 23) ? base + offset : base - offset;
                const auto addr = pre ? updated : base;
                const auto value = reg(rd);
                if (wb)
                    regs[rn] = updated;
                std::uint32_t result;
                if (half && (bits & 0x60) == 0x40)
                    result = static_cast<std::int8_t>(memory<std::uint8_t>(addr, true));
                else if (half) {
                    auto h = memory<std::uint16_t>(addr, load, static_cast<std::uint16_t>(value));
                    result = bits & 0x40 ? static_cast<std::int16_t>(h) : h;
                } else if (bits & (1 << 22))
                    result = memory<std::uint8_t>(addr, load, static_cast<std::uint8_t>(value));
                else
                    result = memory<std::uint32_t>(addr, load, value);
                if (load) {
                    if (rd == 15) {
                        exchange(result);
                        return;
                    }
                    regs[rd] = result;
                }
                break;
            }
            case opcode::multiple: {
                const unsigned mask = bits & 0xffff;
                const auto bytes = std::popcount(mask) * 4;
                const auto base = regs[rn];
                const bool up = bits & (1 << 23), pre = bits & (1 << 24), load = bits & (1 << 20);
                auto addr = (up ? base : base - bytes) + (up == pre ? 4 : 0);
                const auto updated = up ? base + bytes : base - bytes;
                if (bits & (1 << 21))
                    regs[rn] = updated;
                for (auto pending = mask; pending; pending &= pending - 1) {
                    const unsigned index = std::countr_zero(pending);
                    const auto value = memory<std::uint32_t>(addr, load, index == rn ? base : reg(index));
                    if (load) {
                        if (index == 15) {
                            exchange(value);
                            return;
                        }
                        regs[index] = value;
                    }
                    addr += 4;
                }
                break;
            }
            case opcode::empty:
            case opcode::slow:
                slow_step();
                return;
            }
            regs[15] = next;
        }
    }
    std::unique_ptr<core> make_armv6_interpreter(exclusive_monitor* monitor) {
        return std::make_unique<interpreter>(monitor);
    }
}
