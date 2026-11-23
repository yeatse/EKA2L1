// Copyright (c) 2026 EKA2L1 Team. Licensed under GPLv2 or later.
#include <cpu/arm_factory.h>
#include <cpu/arm_replay_capture.h>

#include <array>
#include <cstring>
#include <fstream>
#include <map>

namespace eka2l1::arm {
    bool capture_replay_snapshot(const core::thread_context &initial, const replay_page_lookup &lookup,
        std::uint32_t budget, const std::string &path) {
        using page = std::array<std::uint8_t, 4096>;
        struct captured_page {
            page initial, working;
        };
        std::map<std::uint32_t, captured_page> pages;

        auto monitor = create_exclusive_monitor(arm_emulator_type::dyncom, 1);
        auto cpu = create_core(monitor.get(), arm_emulator_type::dyncom);
        bool fault = false;
        auto reject = [&](auto...) {
            fault = true;
            cpu->stop();
            return false;
        };
        auto access = [&](std::uint32_t address, auto *value, bool write) {
            const auto offset = address & 4095;
            const auto base = address - offset;
            if (offset + sizeof(*value) > 4096)
                return reject();
            auto it = pages.find(base);
            if (it == pages.end()) {
                const auto *source = lookup(base);
                if (!source)
                    return reject();
                it = pages.try_emplace(base).first;
                std::memcpy(it->second.initial.data(), source, 4096);
                it->second.working = it->second.initial;
            }
            auto *data = it->second.working.data();
            cpu->set_tlb_page(base, data, prot_read_write_exec);
            if (write)
                std::memcpy(data + offset, value, sizeof(*value));
            else
                std::memcpy(value, data + offset, sizeof(*value));
            return true;
        };
        auto read = [&](auto address, auto *value) { return access(address, value, false); };
        auto write = [&](auto address, auto *value) { return access(address, value, true); };
        cpu->read_code = read;
        cpu->read_8bit = read;
        cpu->read_16bit = read;
        cpu->read_32bit = read;
        cpu->read_64bit = read;
        cpu->write_8bit = write;
        cpu->write_16bit = write;
        cpu->write_32bit = write;
        cpu->write_64bit = write;
        cpu->exclusive_write_8bit = reject;
        cpu->exclusive_write_16bit = reject;
        cpu->exclusive_write_32bit = reject;
        cpu->exclusive_write_64bit = reject;
        cpu->exception_handler = reject;
        cpu->system_call_handler = reject;
        monitor->read_8bit = reject;
        monitor->read_16bit = reject;
        monitor->read_32bit = reject;
        monitor->read_64bit = reject;
        monitor->write_8bit = reject;
        monitor->write_16bit = reject;
        monitor->write_32bit = reject;
        monitor->write_64bit = reject;
        cpu->set_asid(1);

        cpu->load_context(initial);
        cpu->run(budget);
        if (fault || cpu->get_num_instruction_executed() != budget || pages.empty())
            return false;
        core::thread_context expected {};
        cpu->save_context(expected);

        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        output.write(reinterpret_cast<const char *>(&budget), sizeof(budget));
        output.write(reinterpret_cast<const char *>(&initial), sizeof(initial));
        output.write(reinterpret_cast<const char *>(&expected), sizeof(expected));
        for (const auto &[base, data] : pages) {
            output.write(reinterpret_cast<const char *>(&base), sizeof(base));
            output.write(reinterpret_cast<const char *>(data.initial.data()), data.initial.size());
            output.write(reinterpret_cast<const char *>(data.working.data()), data.working.size());
        }
        return bool(output);
    }
}
