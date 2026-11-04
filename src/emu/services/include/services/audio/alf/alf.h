/*
 * Copyright (c) 2022 EKA2L1 Team
 * 
 * This file is part of EKA2L1 project.
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

#pragma once

#include <services/framework.h>
#include <map>

namespace eka2l1 {
    class alf_streamer_session : public service::typical_session {
        // A session can be shared by threads/plugins. Cancellation is scoped
        // to the plugin and the thread that issued the policy subscription.
        using request_key = std::pair<std::uint32_t, std::uint64_t>;
        std::map<request_key, std::unique_ptr<service::ipc_context>> pending_policy_requests_;

        void cancel_policy(std::uint32_t plugin, std::uint64_t thread);
        void cancel_plugin(std::uint32_t plugin);
        static void complete_cancel(std::unique_ptr<service::ipc_context>, std::uint64_t requester_uid);

    public:
        explicit alf_streamer_session(service::typical_server *svr, kernel::uid client_ss_uid, epoc::version client_version);
        ~alf_streamer_session() override;
        void fetch(service::ipc_context *ctx) override;
    };

    class alf_streamer_server : public service::typical_server {
    public:
        explicit alf_streamer_server(system *sys);
        void connect(service::ipc_context &context) override;
    };
}
