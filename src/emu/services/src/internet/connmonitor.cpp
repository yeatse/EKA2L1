/*
 * Copyright (c) 2020 EKA2L1 Team
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

#include <services/internet/connmonitor.h>
#include <services/centralrepo/centralrepo.h>
#include <services/socket/server.h>
#include <system/epoc.h>

#include <utils/err.h>

namespace eka2l1 {
    connmonitor_iap_info connmonitor_available_iaps(const central_repo &repo) {
        connmonitor_iap_info result;
        // CommsDat identifies IAP records through their RecordName field; 0 and 255 are reserved.
        for (std::uint32_t id = 1; id < 255 && result.count < result.ids.size(); id++) {
            for (const auto &entry : repo.entries) {
                if ((entry.key & 0x7FFFFF00) == (0x02820000 | (id << 8))
                    && entry.data.etype == central_repo_entry_type::string && !entry.data.strd.empty()) {
                    result.ids[result.count++] = id;
                    break;
                }
            }
        }
        return result;
    }

    connmonitor_server::connmonitor_server(eka2l1::system *sys)
        : service::typical_server(sys, "!ConnectionMonitorServer") {
    }

    void connmonitor_server::connect(service::ipc_context &context) {
        create_session<connmonitor_client_session>(&context);
        context.complete(epoc::error_none);
    }

    connmonitor_client_session::connmonitor_client_session(service::typical_server *serv, const kernel::uid ss_id,
        epoc::version client_version)
        : service::typical_session(serv, ss_id, client_version) {
    }

    connmonitor_client_session::~connmonitor_client_session() {
        stop_notifications();
    }

    epoc::socket::connection_registry *connmonitor_client_session::registry() {
        auto *owner = server<connmonitor_server>();
        auto *system = owner->get_system();
        const auto name = get_socket_server_name_by_epocver(system->get_symbian_version_use());
        auto *socket = reinterpret_cast<socket_server *>(system->get_kernel_system()->get_by_name<service::server>(name));
        return socket ? &socket->connections() : nullptr;
    }

    void connmonitor_client_session::enqueue(const event_info &event) {
        // Like the real ConnMon event queue, keep bounded recent history while
        // the client is handling a previous event. State queries remain current.
        if (events_.size() == 256) {
            events_.pop_front();
        }
        events_.push_back(event);
        deliver_event();
    }

    void connmonitor_client_session::deliver_event() {
        if (!event_request_ || events_.empty()) {
            return;
        }
        auto request = std::move(event_request_);
        if (!request->sys->get_kernel_system()->is_thread_alive(request->msg->own_thr)) {
            return;
        }
        const bool written = request->write_data_to_descriptor_argument(0, events_.front());
        if (written) {
            events_.pop_front();
        }
        request->complete(written ? epoc::error_none : epoc::error_bad_descriptor);
    }

    void connmonitor_client_session::stop_notifications() {
        if (connection_events_) {
            connection_events_->observers.erase(this);
            connection_events_.reset();
        }
        events_.clear();
        if (event_request_) {
            auto request = std::move(event_request_);
            if (request->sys->get_kernel_system()->is_thread_alive(request->msg->own_thr)) {
                request->complete(epoc::error_cancel);
            }
        }
    }

    void connmonitor_client_session::fetch(service::ipc_context *ctx) {
        switch (ctx->msg->function) {
        case connmonitor_get_connection_count: {
            get_connection_count(ctx);
            break;
        }

        case connmonitor_get_connection_info: {
            get_connection_info(ctx);
            break;
        }

        case connmonitor_get_int_attribute: {
            get_int_attribute(ctx);
            break;
        }

        case connmonitor_get_uint_attribute: {
            get_uint_attribute(ctx);
            break;
        }

        case connmonitor_get_pckg_attribute: {
            get_pckg_attribute(ctx);
            break;
        }

        case connmonitor_receive_event: {
            receive_event(ctx);
            break;
        }

        case connmonitor_cancel_async_request: {
            cancel_async_request(ctx);
            break;
        }

        case connmonitor_cancel_receive_event: {
            cancel_receive_event(ctx);
            break;
        }

        default: {
            LOG_ERROR(SERVICE_INTERNET, "Unimplemented opcode for ConnectionMonitorServer 0x{:X}", ctx->msg->function);
            ctx->complete(epoc::error_not_supported);
            break;
        }
        }
    }

    void connmonitor_client_session::get_pckg_attribute(service::ipc_context *ctx) {
        const auto connection = ctx->get_argument_value<std::uint32_t>(0);
        const auto attribute = ctx->get_argument_value<std::uint32_t>(2);
        if (!connection || !attribute) {
            ctx->complete(epoc::error_argument);
            return;
        }
        if (*attribute != 403 || *connection != bearer_id_all) {
            ctx->complete(epoc::error_not_supported);
            return;
        }

        auto *cenrep = reinterpret_cast<central_repo_server *>(ctx->sys->get_kernel_system()
            ->get_by_name<service::server>(CENTRAL_REPO_SERVER_NAME));
        auto *repo = cenrep ? cenrep->load_repo_with_lookup(ctx->sys->get_io_system(),
            ctx->sys->get_device_manager(), 0xCCCCCC00) : nullptr;
        if (!repo) {
            ctx->complete(epoc::error_not_found);
            return;
        }

        // Internet sockets use the host network, so configured guest IAPs need no radio scan.
        const auto iaps = connmonitor_available_iaps(*repo);
        repo->access_count--;
        ctx->complete(ctx->write_data_to_descriptor_argument(3, iaps)
            ? epoc::error_none : epoc::error_argument);
    }

    void connmonitor_client_session::get_connection_count(eka2l1::service::ipc_context *ctx) {
        const auto *connections = registry();
        auto snapshot = connections ? connections->monitor_snapshot() : std::vector<std::uint32_t>{};
        const auto count = static_cast<std::uint32_t>(snapshot.size());
        if (ctx->get_argument_max_data_size(0) < sizeof(count)
            || !ctx->write_data_to_descriptor_argument(0, count)) {
            ctx->complete(epoc::error_bad_descriptor);
            return;
        }
        snapshot_ = std::move(snapshot);
        ctx->complete(epoc::error_none);
    }

    void connmonitor_client_session::receive_event(eka2l1::service::ipc_context *ctx) {
        if (event_request_) {
            ctx->complete(epoc::error_in_use);
            return;
        }
        if (ctx->get_argument_max_data_size(0) < sizeof(event_info)) {
            ctx->complete(epoc::error_bad_descriptor);
            return;
        }
        auto *connections = registry();
        if (!connections) {
            ctx->complete(epoc::error_not_ready);
            return;
        }
        if (!connection_events_) {
            connection_events_ = connections->events();
            connection_events_->observers[this] = [this](const epoc::socket::connection_state &state, bool was_active) {
                // Progress events carry the NIF stage in data1; deletion events
                // carry the authoritative-stop flag in data3.
                if (!was_active && state.active) {
                    enqueue({1, state.monitor_id});
                }
                enqueue({8, state.monitor_id, 0, static_cast<std::uint32_t>(state.stage)});
                if (was_active && !state.active) {
                    enqueue({2, state.monitor_id, 0, 0, 0, state.authoritative_stop ? 1u : 0u});
                }
            };
        }
        event_request_ = ctx->move_to_new();
        deliver_event();
    }

    void connmonitor_client_session::get_connection_info(eka2l1::service::ipc_context *ctx) {
        const auto index = ctx->get_argument_value<std::uint32_t>(0);
        if (!index || !*index || *index > snapshot_.size()) {
            ctx->complete(epoc::error_argument);
            return;
        }
        const std::uint32_t subconnections = 0;
        if (ctx->get_argument_max_data_size(1) < sizeof(std::uint32_t)
            || ctx->get_argument_max_data_size(2) < sizeof(std::uint32_t)
            || !ctx->write_data_to_descriptor_argument(1, snapshot_[*index - 1])
            || !ctx->write_data_to_descriptor_argument(2, subconnections)) {
            ctx->complete(epoc::error_bad_descriptor);
            return;
        }
        ctx->complete(epoc::error_none);
    }

    void connmonitor_client_session::get_int_attribute(eka2l1::service::ipc_context *ctx) {
        const auto connection = ctx->get_argument_value<std::uint32_t>(0);
        const auto subconnection = ctx->get_argument_value<std::uint32_t>(1);
        const auto attribute = ctx->get_argument_value<std::uint32_t>(2);
        if (!connection || !subconnection || !attribute) {
            ctx->complete(epoc::error_argument);
            return;
        }
        if (*subconnection) {
            ctx->complete(epoc::error_not_supported);
            return;
        }
        auto *connections = registry();
        const auto state = connections ? connections->monitor_find(*connection) : nullptr;
        if (!state) {
            ctx->complete(epoc::error_not_found);
            return;
        }
        std::int32_t value = 0;
        switch (*attribute) {
        case 1: // KBearer: EKA exposes a virtual host-backed LAN connection.
            value = 3; // EBearerLAN
            break;
        case 2: // KNetworkStatus
            value = state->active ? 3 : 1; // Active / Unattached
            break;
        case 3: // KConnectionStatus
            value = state->stage;
            break;
        default:
            ctx->complete(epoc::error_not_supported);
            return;
        }
        ctx->complete(ctx->get_argument_max_data_size(3) >= sizeof(value)
                && ctx->write_data_to_descriptor_argument(3, value)
            ? epoc::error_none : epoc::error_bad_descriptor);
    }

    void connmonitor_client_session::get_uint_attribute(eka2l1::service::ipc_context *ctx) {
        const auto connection = ctx->get_argument_value<std::uint32_t>(0);
        const auto subconnection = ctx->get_argument_value<std::uint32_t>(1);
        const auto attribute = ctx->get_argument_value<std::uint32_t>(2);
        if (!connection || !subconnection || !attribute) {
            ctx->complete(epoc::error_argument);
            return;
        }
        if (*subconnection || (*attribute != 102 && *attribute != 103)) {
            ctx->complete(epoc::error_not_supported);
            return;
        }
        auto *connections = registry();
        const auto state = connections ? connections->monitor_find(*connection) : nullptr;
        if (!state) {
            ctx->complete(epoc::error_not_found);
            return;
        }
        const auto value = *attribute == 102 ? state->info.iap_id : state->info.network_id;
        ctx->complete(ctx->get_argument_max_data_size(3) >= sizeof(value)
                && ctx->write_data_to_descriptor_argument(3, value)
            ? epoc::error_none : epoc::error_bad_descriptor);
    }

    void connmonitor_client_session::cancel_async_request(eka2l1::service::ipc_context *ctx) {
        // Count and attribute reads complete synchronously in this service;
        // no pending request remains to cancel. Events have a separate API.
        const auto request = ctx->get_argument_value<std::int32_t>(0);
        ctx->complete(request && *request >= 1 && *request <= 7
            ? epoc::error_none : epoc::error_argument);
    }

    void connmonitor_client_session::cancel_receive_event(eka2l1::service::ipc_context *ctx) {
        stop_notifications();
        ctx->complete(epoc::error_none);
    }
}
