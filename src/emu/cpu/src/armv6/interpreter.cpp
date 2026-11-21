// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#include <cpu/armv6.h>
#include <cpu/12l1r/tlb.h>
#include <cpu/dyncom/arm_dyncom.h>
#include <cpu/dyncom/arm_dyncom_thumb.h>
#include <bit>
#include <cstring>

namespace eka2l1::arm {
namespace {
    enum class opcode : std::uint8_t {
        empty, slow, data, transfer, multiple, branch, exchange, multiply, half,
        thumb_branch, thumb_prefix, thumb_call, supervisor
    };

    struct instruction {
        std::uint32_t bits;
        opcode op;
        std::uint8_t condition;
    };

    instruction decode(std::uint32_t bits, bool thumb) {
        if (thumb) {
            const auto half = static_cast<std::uint16_t>(bits);
            const auto group = half >> 11;
            if ((half >> 12) == 13 && ((half >> 8) & 15) < 14)
                return { half, opcode::thumb_branch, static_cast<std::uint8_t>((half >> 8) & 15) };
            if (group == 28) return { half, opcode::thumb_branch, 14 };
            if (group == 30) return { half, opcode::thumb_prefix, 14 };
            if (group == 31 || (group == 29 && !(half & 1))) return { half, opcode::thumb_call, 14 };
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
            else if ((bits & 0x0fc000f0) == 0x00000090)
                op = opcode::multiply;
            else if ((bits & 0x0e000090) == 0x00000090 && (bits & 0x01200000) != 0x00200000 && (bits & 0x60) && ((bits & (1u << 20)) || (bits & 0x60) == 0x20))
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
        if (op == opcode::data && (bits & 0x0010f000) == 0x0010f000)
            op = opcode::slow;
        return { bits, op, cond };
    }

    constexpr std::uint32_t N = 1u << 31, Z = 1u << 30, C = 1u << 29, V = 1u << 28, T = 1u << 5;

    bool passes(unsigned cond, std::uint32_t flags) {
        bool take;
        switch (cond >> 1) {
        case 0: take = flags & Z; break;
        case 1: take = flags & C; break;
        case 2: take = flags & N; break;
        case 3: take = flags & V; break;
        case 4: take = (flags & (C | Z)) == C; break;
        case 5: take = !((flags ^ (flags << 3)) & N); break;
        default: take = !(flags & Z) && !((flags ^ (flags << 3)) & N); break;
        }
        return take != static_cast<bool>(cond & 1);
    }

    std::uint32_t shift(std::uint32_t value, unsigned type, unsigned n, bool immediate, bool &carry) {
        if (!n && (!immediate || type == 0)) return value;
        switch (type) {
        case 0:
            carry = n <= 32 && ((value >> (32 - n)) & 1);
            return n < 32 ? value << n : 0;
        case 1:
            if (!n) n = 32;
            carry = n <= 32 && ((value >> (n - 1)) & 1);
            return n < 32 ? value >> n : 0;
        case 2:
            if (!n || n > 32) n = 32;
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
            std::uint32_t address, asid;
            bool thumb;
            std::array<instruction, 2048> entries{};
        };
        std::array<std::unique_ptr<code_page>, 128> pages_;
        thread_context state_{};
        r12l1::tlb tlb_{12};
        exclusive_monitor *monitor_;
        std::unique_ptr<dyncom_core> slow_;
        std::uint32_t asid_{}, retired_{};
        bool tagged_{}, stopped_{}, in_slow_{};

        void exchange(std::uint32_t target) {
            const bool thumb = target & 1;
            state_.cpsr = (state_.cpsr & ~T) | (thumb ? T : 0);
            state_.set_pc(target & (thumb ? ~1u : ~3u));
        }

        template <typename U, typename Callback>
        U access(address addr, U value, Callback &callback, bool write, bool code = false) {
            auto &entry = tlb_.entries[(addr >> 12) & r12l1::TLB_ENTRY_MASK];
            const auto tag = code ? entry.execute_addr : write ? entry.write_addr : entry.read_addr;
            const auto offset = addr & 4095;
            if (tag == (addr & ~4095u) && offset <= 4096 - sizeof(U)) {
                if (write) std::memcpy(entry.host_base + offset, &value, sizeof(U));
                else std::memcpy(&value, entry.host_base + offset, sizeof(U));
            } else if (!callback(addr, &value) && exception_handler(write ? exception_type_access_violation_write : exception_type_access_violation_read, addr)) {
                callback(addr, &value);
            }
            return value;
        }

        template <typename U>
        U memory(address addr, bool load, U value = 0) {
            if constexpr (sizeof(U) == 1)
                return access(addr, value, load ? read_8bit : write_8bit, !load);
            else if constexpr (sizeof(U) == 2)
                return access(addr, value, load ? read_16bit : write_16bit, !load);
            else
                return access(addr, value, load ? read_32bit : write_32bit, !load);
        }

        instruction fetch(address pc, bool thumb) {
            const auto page = pc >> 12;
            auto &slot = pages_[(page ^ asid_ ^ unsigned(thumb)) % pages_.size()];
            const auto index = (pc & 4095) >> (thumb ? 1 : 2);
            if (slot && slot->address == page && slot->asid == asid_ && slot->thumb == thumb) {
                const auto op = slot->entries[index];
                if (op.op != opcode::empty) return op;
            }
            const auto word = access(pc & ~3u, 0u, read_code, false, true);
            const auto op = decode(thumb && (pc & 2) ? word >> 16 : word, thumb);
            if (!slot || slot->address != page || slot->asid != asid_ || slot->thumb != thumb) {
                slot = std::make_unique<code_page>();
                slot->address = page;
                slot->asid = asid_;
                slot->thumb = thumb;
            }
            slot->entries[index] = op;
            return op;
        }

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
                    if (type == exception_type_undefined_inst) stop();
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
        explicit interpreter(exclusive_monitor *monitor) : monitor_(monitor) {
            state_.cpsr = 0x10;
            state_.set_sp(0x10000000);
        }
        void run(std::uint32_t budget) override {
            stopped_ = false;
            retired_ = 0;
            while (!stopped_ && retired_ < budget) {
                const auto pc = state_.get_pc();
                const bool thumb = state_.cpsr & T;
                auto op = fetch(pc, thumb);
                if (stopped_) break;
                ++retired_;
                if (op.condition < 14 && !passes(op.condition, state_.cpsr)) state_.set_pc(pc + (thumb ? 2 : 4));
                else if (state_.cpsr & 0x200) slow_step();
                else execute(op, pc, thumb ? 2 : 4);
            }
        }
        void stop() override { stopped_ = true; if (in_slow_) slow_->stop(); }
        void step() override { run(1); }
        void save_context(thread_context &ctx) override { if (in_slow_) slow_->save_context(ctx); else ctx = state_; }
        void load_context(const thread_context &ctx) override {
            state_ = ctx;
            if (in_slow_) slow_->load_context(ctx);
            if (!tagged_) clear_instruction_cache();
        }
        void set_asid(std::uint32_t asid) override { asid_ = asid; tagged_ = true; if (slow_) slow_->set_asid(asid); }
        void clear_instruction_cache() override { for (auto &page : pages_) page.reset(); if (slow_) slow_->clear_instruction_cache(); }
        void imb_range(address addr, std::size_t size) override { clear_instruction_cache(); }
        void flush_tlb() override { tlb_.flush(); if (slow_) slow_->flush_tlb(); }
        void set_tlb_page(address addr, std::uint8_t *ptr, prot perm) override { tlb_.add(addr, ptr, perm); if (slow_) slow_->set_tlb_page(addr, ptr, perm); }
        void dirty_tlb_page(address addr) override { tlb_.make_dirty(addr); if (slow_) slow_->dirty_tlb_page(addr); }
        bool should_clear_old_memory_map() const override { return false; }
        std::uint32_t get_num_instruction_executed() override { return retired_; }
        std::uint32_t get_pc() override { return get_reg(15); }
        std::uint32_t get_lr() override { return get_reg(14); }
        std::uint32_t get_sp() override { return get_reg(13); }
        void set_pc(std::uint32_t v) override { set_reg(15,v); }
        void set_lr(std::uint32_t v) override { set_reg(14,v); }
        void set_sp(std::uint32_t v) override { set_reg(13,v); }
        bool is_thumb_mode() override { return get_cpsr() & T; }
        std::uint32_t get_reg(std::size_t i) override { return in_slow_ ? slow_->get_reg(i) : state_.cpu_registers[i]; }
        void set_reg(std::size_t i, std::uint32_t v) override { if (in_slow_) slow_->set_reg(i,v); else state_.cpu_registers[i] = v; }
        std::uint32_t get_cpsr() override { return in_slow_ ? slow_->get_cpsr() : state_.cpsr; }
        void set_cpsr(std::uint32_t v) override { if (in_slow_) slow_->set_cpsr(v); else state_.cpsr = v; }
        std::uint32_t get_fpscr() override { return in_slow_ ? slow_->get_fpscr() : state_.fpscr; }
        void set_fpscr(std::uint32_t v) override { if (in_slow_) slow_->set_fpscr(v); else state_.fpscr = v; }
        std::uint32_t get_vfp(std::size_t i) override { return in_slow_ ? slow_->get_vfp(i) : state_.fpu_registers[i]; }
        void set_vfp(std::size_t i, std::uint32_t v) override { if (in_slow_) slow_->set_vfp(i,v); else state_.fpu_registers[i] = v; }
    };

    void interpreter::execute(instruction op, std::uint32_t pc, unsigned size) {
        const auto bits = op.bits;
        const unsigned rn = bits >> 16 & 15, rd = bits >> 12 & 15, rm = bits & 15;
        auto &regs = state_.cpu_registers;
        const auto next = pc + size;
        auto reg = [&](unsigned index) { return index == 15 ? pc + 2 * size : regs[index]; };
        auto &flags = state_.cpsr;
        auto nz = [&](std::uint32_t value) {
            flags = (flags & ~(N | Z)) | (value & N) | (value ? 0 : Z);
        };
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
                if (bits & (1 << 24)) regs[14] = next;
                regs[15] = target;
            }
            return;
        }
        case opcode::exchange: {
            const auto target = reg(rm);
            if (bits & 0x20) regs[14] = next | (size == 2);
            exchange(target);
            return;
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
                if (rotate) carry = rhs >> 31;
            } else {
                const bool immediate = !(bits & 16);
                const auto amount = immediate ? (bits >> 7 & 31) : (reg(bits >> 8 & 15) & 255);
                rhs = shift(reg(rm) + (!immediate && rm == 15 ? size : 0), bits >> 5 & 3, amount, immediate, carry);
            }
            auto lhs = reg(rn);
            if (size == 2 && rn == 15 && (bits & (1 << 25))) lhs &= ~3u;
            std::uint32_t result;
            bool overflow = flags & V;
            switch (kind) {
            case 0: case 8: result = lhs & rhs; break;
            case 1: case 9: result = lhs ^ rhs; break;
            case 12: result = lhs | rhs; break;
            case 13: result = rhs; break;
            case 14: result = lhs & ~rhs; break;
            case 15: result = ~rhs; break;
            default: {
                if (kind == 3 || kind == 7) std::swap(lhs, rhs);
                const bool sub = kind == 2 || kind == 3 || kind == 6 || kind == 7 || kind == 10;
                if (sub) rhs = ~rhs;
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
            if (bits & (1 << 21)) result += regs[rd];
            regs[rn] = result;
            if (bits & (1 << 20)) nz(result);
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
            } else offset = bits & 4095;
            auto base = reg(rn);
            if (rn == 15 && size == 2) base &= ~3u;
            const auto updated = bits & (1 << 23) ? base + offset : base - offset;
            const auto addr = pre ? updated : base;
            const auto value = reg(rd);
            if (wb) regs[rn] = updated;
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
                if (rd == 15) { exchange(result); return; }
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
            if (bits & (1 << 21)) regs[rn] = updated;
            for (auto pending = mask; pending; pending &= pending - 1) {
                const unsigned index = std::countr_zero(pending);
                const auto value = memory<std::uint32_t>(addr, load, index == rn ? base : reg(index));
                if (load) {
                    if (index == 15) { exchange(value); return; }
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
    std::unique_ptr<core> make_armv6_interpreter(exclusive_monitor *monitor) {
        return std::make_unique<interpreter>(monitor);
    }
}
