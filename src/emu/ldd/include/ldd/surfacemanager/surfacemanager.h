/*
 * Copyright (c) 2026 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#pragma once

#include <kernel/ldd.h>
#include <services/window/surface.h>

#include <map>

namespace eka2l1::ldd {
    // RSurfaceManagerDriver::TSurfaceManagerControl
    enum surface_manager_control_op {
        surface_manager_create_surface = 0,
        surface_manager_open_surface = 1,
        surface_manager_close_surface = 2,
        surface_manager_access_surface_data = 3,
        surface_manager_surface_info = 4,
        surface_manager_create_surface_in_chunk = 5,
        surface_manager_synchronize_cache = 6,
        surface_manager_get_surface_hint = 7,
        surface_manager_set_surface_hint = 8,
        surface_manager_add_surface_hint = 9,
        surface_manager_get_buffer_offset = 10,
        surface_manager_get_attribute = 11
    };

    class surface_manager_channel : public channel {
        // References this channel's process holds on each surface.
        std::map<epoc::surface_id, int> opened_;

        epoc::surface_registry *registry();
        epoc::guest_surface *opened(kernel::process *process, eka2l1::ptr<void> id_ptr, epoc::surface_id &id);
        std::int32_t create_surface(kernel::process *process, eka2l1::ptr<void> attributes, eka2l1::ptr<void> id);
        void release(const epoc::surface_id &id, int references);

    public:
        explicit surface_manager_channel(kernel_system *kern, system *sys, epoc::version ver);

        int destroy() override;

        std::int32_t do_control(kernel::thread *r, const std::uint32_t n, const eka2l1::ptr<void> arg1,
            const eka2l1::ptr<void> arg2) override;

        std::int32_t do_request(epoc::notify_info info, const std::uint32_t n,
            const eka2l1::ptr<void> arg1, const eka2l1::ptr<void> arg2,
            const bool is_supervisor) override;
    };

    class surface_manager_factory : public factory {
    public:
        explicit surface_manager_factory(kernel_system *kern, system *sys);

        void install() override;
        std::unique_ptr<channel> make_channel(epoc::version ver) override;
    };
}
