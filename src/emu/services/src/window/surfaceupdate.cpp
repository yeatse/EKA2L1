/*
 * Copyright (c) 2026 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include <services/window/surfaceupdate.h>
#include <services/window/window.h>

#include <kernel/kernel.h>
#include <system/epoc.h>
#include <utils/err.h>

namespace eka2l1 {
    surface_update_server::surface_update_server(eka2l1::system *sys)
        : service::typical_server(sys, "SURFACE_UPDATE_SERVER") {
    }

    void surface_update_server::connect(service::ipc_context &context) {
        create_session<surface_update_session>(&context);
        context.complete(epoc::error_none);
    }

    surface_update_session::surface_update_session(service::typical_server *serv, const kernel::uid ss_id,
        epoc::version client_version)
        : service::typical_session(serv, ss_id, client_version) {
    }

    void surface_update_session::submit_update(service::ipc_context *ctx) {
        const auto id = ctx->get_argument_data_from_descriptor<epoc::surface_id>(1);
        const auto buffer = ctx->get_argument_value<std::int32_t>(2);
        kernel_system *kern = ctx->sys->get_kernel_system();
        auto *winserv = kern->get_by_name<window_server>(get_winserv_name_by_epocver(kern->get_epoc_version()));
        if (!id || !buffer || *buffer < 0) {
            ctx->complete(epoc::error_argument);
            return;
        }
        auto *guest = winserv ? winserv->surfaces().guest(*id) : nullptr;
        if (!guest) {
            // Surfaces filled on the host need no update from the guest.
            ctx->complete((winserv && winserv->surfaces().find(*id)) ? epoc::error_none : epoc::error_argument);
            return;
        }
        if (!guest->present(static_cast<std::uint32_t>(*buffer))) {
            ctx->complete(epoc::error_argument);
            return;
        }
        // The update is what asks for composition; the window showing the surface draws nothing itself.
        const std::uint64_t now = winserv->get_ntimer()->microseconds();
        for (epoc::screen *scr = winserv->get_screens(); scr; scr = scr->next) {
            const std::lock_guard<std::mutex> guard(scr->screen_mutex);
            const std::uint64_t frame = 1000000 / scr->refresh_rate;
            scr->set_client_draw_pending();
            winserv->get_anim_scheduler()->schedule(winserv->get_graphics_driver(), scr, (now + frame) / frame * frame);
        }
        ctx->complete(epoc::error_none);
    }

    void surface_update_session::fetch(service::ipc_context *ctx) {
        switch (ctx->msg->function) {
        case surface_update_submit_update:
            submit_update(ctx);
            break;

        // A submitted buffer is taken at once, so nothing is left to wait for.
        case surface_update_notify_when_available:
        case surface_update_notify_when_displayed:
        case surface_update_notify_when_displayed_x_times:
        case surface_update_cancel_all_notifications:
            ctx->complete(epoc::error_none);
            break;

        default:
            ctx->complete(epoc::error_not_supported);
            break;
        }
    }
}
