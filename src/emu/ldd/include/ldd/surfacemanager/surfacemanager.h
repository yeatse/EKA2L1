/*
 * Copyright (c) 2026 EKA2L1 Team.
 * This file is part of EKA2L1, licensed under GPLv3 or later.
 */

#pragma once

#include <kernel/ldd.h>
#include <kernel/common.h>

#include <memory>

namespace eka2l1::epoc {
    class managed_surface_registry;
}

namespace eka2l1::ldd {
    class surface_manager_channel final : public channel {
        std::shared_ptr<epoc::managed_surface_registry> surfaces_;
        kernel::uid process_id_;

    public:
        surface_manager_channel(kernel_system *kern, system *sys, epoc::version ver,
            std::shared_ptr<epoc::managed_surface_registry> surfaces, kernel::uid process_id);
        ~surface_manager_channel() override;

        std::int32_t do_control(kernel::thread *requester, const std::uint32_t operation,
            const eka2l1::ptr<void> argument1, const eka2l1::ptr<void> argument2) override;
        std::int32_t do_request(epoc::notify_info info, const std::uint32_t operation,
            const eka2l1::ptr<void> argument1, const eka2l1::ptr<void> argument2,
            const bool is_supervisor) override;
    };

    class surface_manager_factory final : public factory {
    public:
        surface_manager_factory(kernel_system *kern, system *sys);
        void install() override;
        std::unique_ptr<channel> make_channel(epoc::version ver) override;
    };
}
