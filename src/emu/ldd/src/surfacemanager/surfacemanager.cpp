/*
 * Copyright (c) 2026 EKA2L1 Team.
 * This file is part of EKA2L1, licensed under GPLv3 or later.
 */

#include <ldd/surfacemanager/surfacemanager.h>

#include <kernel/kernel.h>
#include <kernel/process.h>
#include <kernel/thread.h>
#include <mem/mem.h>
#include <services/window/managed_surface.h>
#include <services/window/window.h>
#include <system/epoc.h>
#include <utils/des.h>
#include <utils/err.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <utility>

namespace eka2l1::ldd {
    namespace {
        // RSurfaceManagerDriver control numbers in the SymbianSource driver.
        enum control : std::uint32_t {
            create_surface = 0,
            open_surface = 1,
            close_surface = 2,
            access_surface_data = 3,
            surface_info = 4,
            create_surface_existing_chunk = 5,
            synchronize_cache = 6,
            get_surface_hint = 7,
            set_surface_hint = 8,
            add_surface_hint = 9,
            get_buffer_offset = 10,
            get_manager_attribute = 11
        };

        // The native driver receives pointers and descriptors, not IPC slots.
        // First validate the whole fixed-size object; then copy page by page.
        // No guest pointer or contents are logged by these helpers.
        bool guest_bytes(kernel_system *kern, kernel::process *process,
            const address start, void *data, const std::uint32_t length,
            const bool writable, const bool copy) {
            if (!process || !start || !length
                || static_cast<std::uint64_t>(start) + length > (std::uint64_t{1} << 32)) {
                return false;
            }
            auto *model = process->get_mem_model();
            auto *memory = kern->get_memory_system();
            if (!model || !memory) {
                return false;
            }
            auto *control = memory->get_control();
            const auto page_size = static_cast<std::uint32_t>(memory->get_page_size());
            const auto required = writable ? prot_write : prot_read;
            const auto asid = model->address_space_id();
            std::uint32_t done = 0;
            while (done < length) {
                const address current = start + done;
                const auto *page = control->get_page_info(asid, current);
                if (!page || !page->host_addr || !(page->perm & required)) {
                    return false;
                }
                auto *host = control->get_host_pointer(asid, current);
                if (!host) {
                    return false;
                }
                const auto count = std::min(length - done, page_size - current % page_size);
                if (copy) {
                    auto *bytes = static_cast<std::uint8_t *>(data) + done;
                    if (writable) {
                        std::memcpy(host, bytes, count);
                    } else {
                        std::memcpy(bytes, host, count);
                    }
                }
                done += count;
            }
            return true;
        }

        template <typename T>
        bool read_value(kernel_system *kern, kernel::process *process,
            const address source, T &value) {
            return guest_bytes(kern, process, source, nullptr, sizeof(T), false, false)
                && guest_bytes(kern, process, source, &value, sizeof(T), false, true);
        }

        template <typename T>
        bool writable_value(kernel_system *kern, kernel::process *process,
            const address target) {
            return guest_bytes(kern, process, target, nullptr, sizeof(T), true, false);
        }

        template <typename T>
        bool write_value(kernel_system *kern, kernel::process *process,
            const address target, const T &value) {
            T copy = value;
            return writable_value<T>(kern, process, target)
                && guest_bytes(kern, process, target, &copy, sizeof(T), true, true);
        }

        // These controls take TPckgBuf<T>, as specified by the driver inlines.
        // Other descriptor classes are outside this minimal public API subset.
        template <typename T>
        bool package_payload(kernel_system *kern, kernel::process *process,
            const address descriptor, const bool writable, address &payload) {
            std::array<std::uint32_t, 2> header{};
            if (!read_value(kern, process, descriptor, header)
                || header[0] >> 28 != epoc::buf
                || (header[0] & epoc::descriptor_length_mask) != sizeof(T)
                || header[1] < sizeof(T)
                || descriptor > std::numeric_limits<address>::max() - sizeof(header)) {
                return false;
            }
            payload = descriptor + sizeof(header);
            return guest_bytes(kern, process, payload, nullptr, sizeof(T), writable, false);
        }
    }

    surface_manager_factory::surface_manager_factory(kernel_system *kern, system *sys)
        : factory(kern, sys) {
    }

    void surface_manager_factory::install() {
        obj_name = "surfacemanagerdriver";
    }

    std::unique_ptr<channel> surface_manager_factory::make_channel(epoc::version ver) {
        if (ver.major != 1 || ver.minor != 0 || kern->is_eka1()
            || kern->get_epoc_version() < epocver::epoc10 || !kern->crr_process()) {
            return nullptr;
        }
        auto *server = kern->get_by_name<window_server>(
            get_winserv_name_by_epocver(kern->get_epoc_version()));
        if (!server || !server->managed_surfaces()) {
            return nullptr;
        }
        return std::make_unique<surface_manager_channel>(kern, sys_, ver,
            server->managed_surfaces(), kern->crr_process()->unique_id());
    }

    surface_manager_channel::surface_manager_channel(kernel_system *kern, system *sys,
        epoc::version ver, std::shared_ptr<epoc::managed_surface_registry> surfaces,
        kernel::uid process_id)
        : channel(kern, sys, ver)
        , surfaces_(std::move(surfaces))
        , process_id_(process_id) {
        surfaces_->attach_channel(process_id_);
    }

    surface_manager_channel::~surface_manager_channel() {
        surfaces_->detach_channel(process_id_);
    }

    std::int32_t surface_manager_channel::do_control(kernel::thread *requester,
        const std::uint32_t operation, const eka2l1::ptr<void> argument1,
        const eka2l1::ptr<void> argument2) {
        auto *process = requester ? requester->owning_process() : nullptr;
        if (!process || process->unique_id() != process_id_) {
            return epoc::error_access_denied;
        }
        const auto first = argument1.ptr_address();
        const auto second = argument2.ptr_address();
        epoc::surface_id id{};

        switch (operation) {
        case create_surface: {
            // TSurfaceCreationAttributes is thirteen 32-bit fields, including
            // the two TSize components and the native hints pointer.
            std::array<std::int32_t, 13> wire{};
            address payload = 0;
            if (!package_payload<decltype(wire)>(kern, process, first, false, payload)
                || !read_value(kern, process, payload, wire)
                || !writable_value<epoc::surface_id>(kern, process, second)) {
                return epoc::error_bad_descriptor;
            }
            if (wire[11] != 0) {
                return wire[11] < 0 ? epoc::error_argument : epoc::error_not_supported;
            }
            epoc::managed_surface_attributes attributes{};
            attributes.size = { wire[0], wire[1] };
            attributes.buffers = wire[2];
            attributes.pixel_format = wire[3];
            attributes.stride = wire[4];
            attributes.first_offset = wire[5];
            attributes.alignment = wire[6];
            attributes.contiguous = wire[7];
            attributes.cache_attrib = wire[8];
            attributes.buffer_spacing = wire[9];
            attributes.hint_count = wire[11];
            attributes.mappable = wire[12];
            const auto result = surfaces_->create(requester, attributes, id);
            if (result != epoc::error_none) {
                return result;
            }
            if (!write_value(kern, process, second, id)) {
                surfaces_->close(process_id_, id);
                return epoc::error_bad_descriptor;
            }
            return epoc::error_none;
        }
        case open_surface:
        case close_surface:
        case access_surface_data:
        case surface_info: {
            if (!read_value(kern, process, first, id)) {
                return epoc::error_bad_descriptor;
            }
            if (operation == open_surface) {
                return surfaces_->open(process_id_, id);
            }
            if (operation == close_surface) {
                return surfaces_->close(process_id_, id);
            }
            if (operation == access_surface_data) {
                // RChunk::SetReturnedHandle consumes the actual positive
                // thread-owned kernel handle directly from this return value.
                return surfaces_->map(requester, id);
            }
            std::array<std::int32_t, 8> wire{};
            address payload = 0;
            if (!package_payload<decltype(wire)>(kern, process, second, true, payload)) {
                return epoc::error_bad_descriptor;
            }
            epoc::managed_surface_info information{};
            const auto result = surfaces_->info(process_id_, id, information);
            if (result != epoc::error_none) {
                return result;
            }
            wire = { information.size.x, information.size.y, information.buffers,
                information.pixel_format, information.stride, information.contiguous,
                information.cache_attrib, information.mappable };
            return write_value(kern, process, payload, wire)
                ? epoc::error_none : epoc::error_bad_descriptor;
        }
        case synchronize_cache:
        case get_buffer_offset: {
            // TDeviceParam's declared field order is iBuffer, iSurfaceId.
            std::array<std::uint32_t, 2> parameters{};
            if (!read_value(kern, process, first, parameters)
                || !read_value(kern, process, parameters[1], id)) {
                return epoc::error_bad_descriptor;
            }
            const auto buffer = static_cast<std::int32_t>(parameters[0]);
            if (operation == synchronize_cache) {
                return surfaces_->synchronize(process_id_, id, buffer,
                    static_cast<std::int32_t>(second));
            }
            if (!writable_value<std::int32_t>(kern, process, second)) {
                return epoc::error_bad_descriptor;
            }
            std::int32_t offset = 0;
            const auto result = surfaces_->buffer_offset(process_id_, id, buffer, offset);
            if (result != epoc::error_none) {
                return result;
            }
            return write_value(kern, process, second, offset)
                ? epoc::error_none : epoc::error_bad_descriptor;
        }
        case get_manager_attribute: {
            std::int32_t attribute = 0;
            if (!read_value(kern, process, first, attribute)
                || !writable_value<std::int32_t>(kern, process, second)) {
                return epoc::error_bad_descriptor;
            }
            if (attribute != 0) {
                return epoc::error_argument;
            }
            // This implementation advertises no optional per-surface hints.
            return write_value(kern, process, second, std::int32_t{0})
                ? epoc::error_none : epoc::error_bad_descriptor;
        }
        case create_surface_existing_chunk:
        case get_surface_hint:
        case set_surface_hint:
        case add_surface_hint:
        default:
            return epoc::error_not_supported;
        }
    }

    std::int32_t surface_manager_channel::do_request(epoc::notify_info info,
        const std::uint32_t, const eka2l1::ptr<void>, const eka2l1::ptr<void>,
        const bool) {
        // The official Surface Manager entry points use synchronous DoControl.
        // Reject asynchronous requests explicitly rather than leaving them pending.
        info.complete(epoc::error_not_supported);
        return epoc::error_none;
    }
}
