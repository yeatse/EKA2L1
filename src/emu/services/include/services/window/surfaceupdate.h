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

#include <kernel/server.h>
#include <services/framework.h>

namespace eka2l1 {
    // TSurfaceUpdateServRqst
    enum surface_update_opcode {
        surface_update_notify_when_available = 3,
        surface_update_notify_when_displayed = 4,
        surface_update_notify_when_displayed_x_times = 5,
        surface_update_submit_update = 6,
        surface_update_cancel_all_notifications = 7
    };

    // The compositor's content update server: clients tell it which buffer of a surface to show.
    class surface_update_server : public service::typical_server {
    public:
        explicit surface_update_server(eka2l1::system *sys);

        void connect(service::ipc_context &context) override;
    };

    struct surface_update_session : public service::typical_session {
        explicit surface_update_session(service::typical_server *serv, const kernel::uid ss_id, epoc::version client_version);

        void fetch(service::ipc_context *ctx) override;
        void submit_update(service::ipc_context *ctx);
    };
}
