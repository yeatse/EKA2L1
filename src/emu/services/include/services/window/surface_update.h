/* Copyright (c) 2026 EKA2L1 Team. GPLv3 or later. */
#pragma once
#include <services/framework.h>
#include <utils/reqsts.h>

namespace eka2l1 {
    class surface_update_session : public service::typical_session {
        epoc::notify_info available_;
        kernel::uid requester_ = 0;
        std::int32_t update_method_ = 0;
        void complete_available(std::int32_t error);
        std::int32_t submit(service::ipc_context *context);
    public:
        explicit surface_update_session(service::typical_server *server, kernel::uid session, epoc::version version);
        ~surface_update_session() override;
        void fetch(service::ipc_context *context) override;
    };
    class surface_update_server : public service::typical_server {
    public:
        explicit surface_update_server(system *sys);
        void connect(service::ipc_context &context) override;
    };
}
