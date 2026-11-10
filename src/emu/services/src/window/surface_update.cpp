/* Copyright (c) 2026 EKA2L1 Team. GPLv3 or later. */
#include <services/window/surface_update.h>
#include <services/window/managed_surface.h>
#include <services/window/window.h>
#include <kernel/kernel.h>
#include <kernel/process.h>
#include <kernel/thread.h>
#include <mem/mem.h>
#include <system/epoc.h>
#include <utils/err.h>
#include <cstring>
#include <array>
#include <algorithm>
#include <utils/des.h>

namespace eka2l1 {
    namespace {
        // SymbianSource graphics ff133bc surfaceupdate.h / suerror.h.
        constexpr std::int32_t ALL_SCREENS = 0xffffff;
        constexpr std::int32_t RECEIVER_NOT_AVAILABLE = -221;
        constexpr std::int32_t SURFACE_NOT_REGISTERED = -222;
        enum update_opcode {
            notify_available = 3, notify_displayed = 4, notify_displayed_times = 5,
            submit_update = 6, cancel_notifications = 7
        };

        bool read_bytes(service::ipc_context *context, address start, void *destination, std::uint32_t length) {
            if (!length) { return true; }
            if (!start || static_cast<std::uint64_t>(start) + length > (std::uint64_t{1} << 32)) { return false; }
            auto *process = context->msg->own_thr->owning_process();
            auto *memory = context->sys->get_memory_system();
            if (!process || !process->get_mem_model() || !memory) { return false; }
            auto *control = memory->get_control();
            const auto asid = process->get_mem_model()->address_space_id();
            const auto page_size = static_cast<std::uint32_t>(memory->get_page_size());
            for (unsigned pass = 0; pass != 2; ++pass) {
                std::uint32_t copied = 0;
                while (copied < length) {
                    const address current = start + copied;
                    const auto *page = control->get_page_info(asid, current);
                    if (!page || !page->host_addr || !(page->perm & prot_read)) { return false; }
                    const auto *source = control->get_host_pointer(asid, current);
                    if (!source) { return false; }
                    const auto count = std::min(length - copied, page_size - current % page_size);
                    if (pass) { std::memcpy(static_cast<std::uint8_t *>(destination) + copied, source, count); }
                    copied += count;
                }
            }
            return true;
        }
        bool read_descriptor(service::ipc_context *context, unsigned slot,
            std::uint32_t maximum, std::vector<std::uint8_t> &output) {
            const auto argument_type = static_cast<unsigned>(context->msg->args.get_arg_type(slot));
            if (!(argument_type & static_cast<unsigned>(ipc_arg_type::flag_des))
                || (argument_type & static_cast<unsigned>(ipc_arg_type::flag_16b))) { return false; }
            const address descriptor = context->msg->args.args[slot];
            std::uint32_t info = 0;
            if (!read_bytes(context, descriptor, &info, sizeof(info))) { return false; }
            const auto length = info & epoc::descriptor_length_mask;
            if (length > maximum || descriptor > UINT32_MAX - 4) { return false; }
            address payload = 0;
            std::array<std::uint32_t, 2> tail{};
            switch (info >> 28) {
            case epoc::buf_const: payload = descriptor + 4; break;
            case epoc::buf:
                if (!read_bytes(context, descriptor + 4, tail.data(), 4) || length > tail[0]) { return false; }
                payload = descriptor + 8; break;
            case epoc::ptr_const:
                if (!read_bytes(context, descriptor + 4, &payload, 4)) { return false; }
                break;
            case epoc::ptr:
            case epoc::ptr_to_buf:
                if (!read_bytes(context, descriptor + 4, tail.data(), 8) || length > tail[0]) { return false; }
                payload = tail[1];
                if ((info >> 28) == epoc::ptr_to_buf) {
                    std::uint32_t nested = 0;
                    if (payload > UINT32_MAX - 4 || !read_bytes(context, payload, &nested, 4)
                        || nested >> 28 != epoc::buf_const || length > (nested & epoc::descriptor_length_mask)) { return false; }
                    payload += 4;
                }
                break;
            default: return false;
            }
            output.resize(length);
            return read_bytes(context, payload, output.data(), length);
        }
    }
    surface_update_session::surface_update_session(service::typical_server *server,
        kernel::uid session, epoc::version version) : typical_session(server, session, version) {}
    surface_update_session::~surface_update_session() { complete_available(epoc::error_cancel); }

    void surface_update_session::complete_available(std::int32_t error) {
        auto *kernel = server<surface_update_server>()->get_kernel_object_owner();
        if (!available_.empty() && !kernel->wipeout_in_progress() && kernel->get_by_id<kernel::thread>(requester_)) {
            available_.complete(error);
        }
        available_ = epoc::notify_info{};
        requester_ = 0;
    }

    std::int32_t surface_update_session::submit(service::ipc_context *context) {
        const auto screen = static_cast<std::int32_t>(context->msg->args.args[0]);
        const auto buffer = static_cast<std::int32_t>(context->msg->args.args[2]);
        std::vector<std::uint8_t> packed_id;
        if (screen < 0 || buffer < 0 || !read_descriptor(context, 1, sizeof(epoc::surface_id), packed_id)
            || packed_id.size() != sizeof(epoc::surface_id)) {
            return epoc::error_argument;
        }
        epoc::surface_id id{};
        std::memcpy(id.data(), packed_id.data(), sizeof(id));
        if (id == epoc::surface_id{}) { return epoc::error_argument; }
        const auto region_type = static_cast<unsigned>(context->msg->args.get_arg_type(3));
        if (region_type & static_cast<unsigned>(ipc_arg_type::flag_des)) {
            std::vector<std::uint8_t> region;
            if (!read_descriptor(context, 3, 256 * sizeof(eka2l1::rect), region)
                || region.size() % sizeof(eka2l1::rect)) {
                return epoc::error_argument;
            }
            // A complete copied frame is a valid superset of the dirty region.
        }
        const auto method = screen == ALL_SCREENS ? 1 : 2;
        if (update_method_ && update_method_ != method) { return epoc::error_not_supported; }
        auto *kernel = server<surface_update_server>()->get_kernel_object_owner();
        auto *windows = kernel->get_by_name<window_server>(get_winserv_name_by_epocver(kernel->get_epoc_version()));
        if (!windows || (screen != ALL_SCREENS && !windows->get_screen(screen))) { return RECEIVER_NOT_AVAILABLE; }
        auto registry = windows->managed_surfaces();
        if (!registry->registered(id, screen)) { return SURFACE_NOT_REGISTERED; }
        auto surface = registry->find(id);
        if (!surface) { return epoc::error_not_supported; }
        if (buffer >= surface->attributes.buffers) { return epoc::error_argument; }
        if (!surface->publish(buffer)) { return epoc::error_no_memory; }
        update_method_ = method;
        // Publication copies the frame, so the producer can reuse its buffer.
        windows->surface_updated(surface->producer);
        return epoc::error_none;
    }

    void surface_update_session::fetch(service::ipc_context *context) {
        switch (context->msg->function) {
        case notify_available:
            if (!available_.empty()) { context->complete(epoc::error_in_use); return; }
            available_ = epoc::notify_info(context->msg->request_sts, context->msg->own_thr);
            requester_ = context->msg->own_thr->unique_id();
            return;
        case submit_update: {
            const auto result = submit(context);
            complete_available(result);
            context->complete(result);
            return;
        }
        case cancel_notifications:
            complete_available(epoc::error_cancel);
            context->complete(epoc::error_none);
            return;
        case notify_displayed:
        case notify_displayed_times:
            // Displayed notifications require a display-completion signal.
            context->complete(epoc::error_not_supported);
            return;
        default:
            context->complete(epoc::error_not_supported);
            return;
        }
    }
    surface_update_server::surface_update_server(system *sys)
        : typical_server(sys, "SURFACE_UPDATE_SERVER") {
    }
    void surface_update_server::connect(service::ipc_context &context) {
        const auto version = get_version(&context);
        if (!version) {
            context.complete(epoc::error_argument); return;
        }
        if (version->major != 1) {
            context.complete(epoc::error_not_supported); return;
        }
        if (version->minor > 1) {
            context.complete(epoc::error_not_supported); return;
        }
        if (version->minor == 1 && version->build > 3) {
            context.complete(epoc::error_not_supported); return;
        }
        if (!create_session<surface_update_session>(&context)) {
            context.complete(epoc::error_no_memory); return;
        }
        context.complete(epoc::error_none);
    }
}
