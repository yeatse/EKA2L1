/*
 * Copyright (c) 2022 EKA2L1 Team
 * 
 * This file is part of EKA2L1 project
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

#include <services/audio/alf/alf.h>
#include <system/epoc.h>
#include <kernel/thread.h>

#include <utils/err.h>

namespace eka2l1 {
    // Cancellation encodes a little-endian TInt followed by an unpadded TThreadId.
    constexpr std::uint32_t control_policy_request = 33;
    constexpr std::uint32_t control_policy_get = 34;
    constexpr std::uint32_t control_policy_cancel = 35;

    static std::uint64_t read_little_endian(const char *bytes, unsigned count) {
        std::uint64_t result = 0;
        for (unsigned index = 0; index < count; ++index)
            result |= static_cast<std::uint64_t>(static_cast<unsigned char>(bytes[index])) << (8 * index);
        return result;
    }

    alf_streamer_server::alf_streamer_server(eka2l1::system *sys)
        : service::typical_server(sys, "alfstreamerserver") {
    }

    void alf_streamer_server::connect(service::ipc_context &context) {
        create_session<alf_streamer_session>(&context);
        context.complete(epoc::error_none);
    }

    alf_streamer_session::alf_streamer_session(service::typical_server *serv, const kernel::uid ss_id,
        epoc::version client_version)
        : service::typical_session(serv, ss_id, client_version) {
    }

    alf_streamer_session::~alf_streamer_session() {
        while (!pending_policy_requests_.empty()) {
            const auto requester_uid = pending_policy_requests_.begin()->first.second;
            auto request = std::move(pending_policy_requests_.begin()->second);
            pending_policy_requests_.erase(pending_policy_requests_.begin());
            complete_cancel(std::move(request), requester_uid);
        }
    }

    void alf_streamer_session::complete_cancel(std::unique_ptr<service::ipc_context> request, std::uint64_t requester_uid) {
        auto *kern = request->sys->get_kernel_system();
        auto *thread = request->msg->own_thr;
        // IPC retains the requesting thread; completion also requires its live identity.
        if (!kern->is_wiping() && kern->is_thread_alive(thread)
            && thread->unique_id() == requester_uid
            && thread->get_exit_type() == kernel::entity_exit_type::pending
            && request->msg->request_sts.get(thread->owning_process()))
            request->complete(epoc::error_cancel);
    }

    void alf_streamer_session::cancel_policy(std::uint32_t plugin, std::uint64_t thread) {
        auto found = pending_policy_requests_.find({plugin, thread});
        if (found == pending_policy_requests_.end())
            return;
        auto request = std::move(found->second);
        pending_policy_requests_.erase(found);
        complete_cancel(std::move(request), thread);
    }

    void alf_streamer_session::cancel_plugin(std::uint32_t plugin) {
        auto entry = pending_policy_requests_.lower_bound({plugin, 0});
        while (entry != pending_policy_requests_.end() && entry->first.first == plugin) {
            const auto requester_uid = entry->first.second;
            auto request = std::move(entry->second);
            entry = pending_policy_requests_.erase(entry);
            complete_cancel(std::move(request), requester_uid);
        }
    }

    void alf_streamer_session::fetch(service::ipc_context *ctx) {
        int function = ctx->msg->function;
        if ((function >= 20000) && (function <= 20005)) {
            function -= 20000;
        }

        const auto plugin = ctx->get_argument_value<std::uint32_t>(0);
        switch (function) {
        case 0: // LoadTfxPlugin.
            ctx->complete(plugin ? epoc::error_none : epoc::error_argument);
            break;
        case 1: // UnloadTfxPlugin also releases this session's pending requests.
            if (!plugin) {
                ctx->complete(epoc::error_argument);
                break;
            }
            cancel_plugin(*plugin);
            ctx->complete(epoc::error_none);
            break;
        case 2: {
            const auto input = ctx->get_argument_value<std::string>(1);
            if (!plugin || !input || input->size() < 4) {
                ctx->complete(epoc::error_argument);
                break;
            }
            if (ctx->get_argument_max_data_size(2) < sizeof(std::int32_t)) {
                ctx->complete(epoc::error_bad_descriptor);
                break;
            }
            const auto operation = read_little_endian(input->data(), 4);
            if (operation == control_policy_cancel) {
                if (input->size() != 12) {
                    ctx->complete(epoc::error_argument);
                    break;
                }
                const auto thread = read_little_endian(input->data() + 4, 8);
                if (thread != ctx->msg->own_thr->unique_id()) {
                    ctx->complete(epoc::error_permission_denied);
                    break;
                }
                // Complete the original async status before the synchronous
                // reply. CAlfTransitionRequest::DoCancel is intentionally empty.
                cancel_policy(*plugin, thread);
            } else if (operation > control_policy_get || operation == control_policy_request) {
                ctx->complete(epoc::error_not_supported);
                break;
            }
            // Known synchronous commands return the disabled-effects result.
            const std::int32_t result = epoc::error_none;
            ctx->complete(ctx->write_data_to_descriptor_argument(2, result)
                ? epoc::error_none : epoc::error_bad_descriptor);
            break;
        }
        case 3: {
            const auto input = ctx->get_argument_value<std::string>(1);
            if (!plugin || !input || input->size() != 4) {
                ctx->complete(epoc::error_argument);
                break;
            }
            if (read_little_endian(input->data(), 4) != control_policy_request) {
                ctx->complete(epoc::error_not_supported);
                break;
            }
            const request_key key{*plugin, ctx->msg->own_thr->unique_id()};
            if (pending_policy_requests_.count(key)) {
                ctx->complete(epoc::error_in_use);
                break;
            }
            pending_policy_requests_.emplace(key, ctx->move_to_new());
            break;
        }
        case 4:
            // CancelAsynchronousData takes a message ID; policy cancellation uses inner op 35.
            ctx->complete(epoc::error_not_supported);
            break;
        case 5: // Frame-preparation hint: rendering effects remain disabled.
            ctx->complete(epoc::error_none);
            break;
        default:
            ctx->complete(epoc::error_not_supported);
            break;
        }
    }
}
