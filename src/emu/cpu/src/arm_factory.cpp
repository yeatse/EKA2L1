/*
 * Copyright (c) 2018 EKA2L1 Team.
 * 
 * This file is part of EKA2L1 project 
 * (see bentokun.github.com/EKA2L1).
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
#include <common/log.h>
#include <common/platform.h>
#include <cpu/arm_factory.h>

#include <cpu/dyncom/arm_dyncom.h>

// iOS device builds have no JIT backend wired up yet; simulator builds run as
// host macOS processes and can use dynarmic for acceptance coverage. The
// dyncom-only build (e.g. the differential test harness) forces dynarmic off on
// any host so it doesn't drag in the dynarmic headers/library.
#if !defined(EKA2L1_CPU_DYNCOM_ONLY_BUILD)
#define EKA2L1_CPU_DYNCOM_ONLY_BUILD 0
#endif
#define EKA2L1_CPU_HAS_DYNARMIC (!EKA2L1_ARCH(ARM) && (!EKA2L1_PLATFORM(IOS) || EKA2L1_IOS_SIMULATOR_DYNARMIC) && !EKA2L1_CPU_DYNCOM_ONLY_BUILD)

#if EKA2L1_ARCH(ARM)
#include <cpu/12l1r/arm_12l1r.h>
#elif EKA2L1_CPU_HAS_DYNARMIC
#include <cpu/arm_dynarmic.h>
#endif

#include <cpu/12l1r/exclusive_monitor.h>

namespace eka2l1::arm {
    bool host_can_jit() {
#if EKA2L1_PLATFORM(IOS)
#if EKA2L1_IOS_SIMULATOR_DYNARMIC
        return true;
#else
        return false;
#endif
#elif EKA2L1_ARCH(ARM)
        // 32-bit ARM hosts use 12l1r rather than dynarmic, treat as JIT-capable.
        return true;
#elif EKA2L1_CPU_HAS_DYNARMIC
        return true;
#else
        return false;
#endif
    }

    arm_emulator_type resolve_emulator_type(arm_emulator_type requested, const char **out_reason) {
        const char *reason = nullptr;
        arm_emulator_type resolved = requested;

#if EKA2L1_PLATFORM(IOS) && !EKA2L1_IOS_SIMULATOR_DYNARMIC
        if (requested == arm_emulator_type::dynarmic || requested == arm_emulator_type::r12l1
            || requested == arm_emulator_type::unicorn) {
            reason = "no-jit-on-ios-device (no MAP_JIT entitlement path yet)";
            resolved = arm_emulator_type::dyncom;
        }
#else
        (void)requested;
#endif

        if (out_reason) {
            *out_reason = reason;
        }
        return resolved;
    }

    core_instance create_core(exclusive_monitor *monitor, arm_emulator_type arm_type) {
        const char *reason = nullptr;
        const arm_emulator_type resolved = resolve_emulator_type(arm_type, &reason);
        if (reason) {
            LOG_WARN(CPU, "CPU backend request {} downgraded to {} ({})",
                static_cast<int>(arm_type), static_cast<int>(resolved), reason);
        }

        switch (resolved) {
        case arm_emulator_type::unicorn:
            return nullptr;

#if EKA2L1_ARCH(ARM)
        case arm_emulator_type::r12l1:
            return std::make_unique<r12l1_core>(monitor, 12);
#elif EKA2L1_CPU_HAS_DYNARMIC
        case arm_emulator_type::dynarmic:
            return std::make_unique<dynarmic_core>(monitor);
#endif

        case arm_emulator_type::dyncom:
            return std::make_unique<dyncom_core>(monitor, 12);

        default:
            break;
        }

        return nullptr;
    }

    exclusive_monitor_instance create_exclusive_monitor(arm_emulator_type arm_type, const std::size_t core_count) {
        switch (arm_type) {
        case arm_emulator_type::unicorn:
            return nullptr;

        case arm_emulator_type::dyncom:
            return std::make_unique<r12l1::exclusive_monitor>(core_count);

#if EKA2L1_ARCH(ARM)
        case arm_emulator_type::r12l1:
            return std::make_unique<r12l1::exclusive_monitor>(core_count);
#elif EKA2L1_CPU_HAS_DYNARMIC
        case arm_emulator_type::dynarmic:
            return std::make_unique<dynarmic_exclusive_monitor>(core_count);
#endif

        default:
            break;
        }

        return nullptr;
    }
}
