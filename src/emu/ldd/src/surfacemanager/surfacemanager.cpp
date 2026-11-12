/*
 * Copyright (c) 2026 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include <ldd/surfacemanager/surfacemanager.h>

#include <kernel/chunk.h>
#include <kernel/kernel.h>
#include <kernel/process.h>
#include <kernel/thread.h>
#include <services/window/window.h>
#include <utils/des.h>
#include <utils/err.h>

#include <common/log.h>

#include <limits>

namespace eka2l1::ldd {
    namespace {
        constexpr std::int32_t PAGE_ALIGNED = -1;
        constexpr std::uint32_t PAGE_SIZE = 0x1000;
        constexpr std::int32_t MAX_HINTS_PER_SURFACE = 16;

        // RSurfaceManager::TSurfaceCreationAttributes
        struct surface_creation_attributes {
            eka2l1::vec2 size;
            std::int32_t buffers;
            std::uint32_t pixel_format;
            std::int32_t stride;
            std::int32_t offset_to_first_buffer;
            std::int32_t alignment;
            std::int32_t contiguous;
            std::int32_t cache_attribute;
            std::int32_t offset_between_buffers;
            eka2l1::ptr<void> hints;
            std::int32_t hint_count;
            std::int32_t mappable;
        };
        static_assert(sizeof(surface_creation_attributes) == 52);

        // RSurfaceManager::TSurfaceInfoV01
        struct surface_info {
            eka2l1::vec2 size;
            std::int32_t buffers;
            std::uint32_t pixel_format;
            std::int32_t stride;
            std::int32_t contiguous;
            std::int32_t cache_attribute;
            std::int32_t mappable;
        };
        static_assert(sizeof(surface_info) == 32);

        // RSurfaceManagerDriver::TDeviceParam
        struct device_param {
            std::uint32_t buffer;
            eka2l1::ptr<void> surface_id;
        };

        std::uint32_t bytes_per_pixel(std::uint32_t format) {
            return format == epoc::surface_pixel_format_rgb565 ? 2 : format == epoc::surface_pixel_format_rgb888 ? 3 : 4;
        }
    }

    surface_manager_factory::surface_manager_factory(kernel_system *kern, system *sys)
        : factory(kern, sys) {
    }

    void surface_manager_factory::install() {
        obj_name = "surfacemanagerdriver";
    }

    std::unique_ptr<channel> surface_manager_factory::make_channel(epoc::version ver) {
        return std::make_unique<surface_manager_channel>(kern, sys_, ver);
    }

    surface_manager_channel::surface_manager_channel(kernel_system *kern, system *sys, epoc::version ver)
        : channel(kern, sys, ver) {
    }

    epoc::surface_registry *surface_manager_channel::registry() {
        auto *winserv = kern->get_by_name<window_server>(get_winserv_name_by_epocver(kern->get_epoc_version()));
        return winserv ? &winserv->surfaces() : nullptr;
    }

    void surface_manager_channel::release(const epoc::surface_id &id, int references) {
        auto *surfaces = registry();
        auto *guest = surfaces ? surfaces->guest(id) : nullptr;
        if (!guest) {
            return;
        }
        guest->references -= references;
        if (guest->references <= 0) {
            guest->surface->set_streaming(false);
            guest->chunk->decrease_access_count();
            surfaces->remove_guest(id);
        }
    }

    int surface_manager_channel::destroy() {
        if (!kern->wipeout_in_progress()) {
            for (const auto &[id, references] : opened_) {
                release(id, references);
            }
        }
        opened_.clear();
        return channel::destroy();
    }

    epoc::guest_surface *surface_manager_channel::opened(kernel::process *process, eka2l1::ptr<void> id_ptr, epoc::surface_id &id) {
        const auto *guest_id = id_ptr.cast<epoc::surface_id>().get(process);
        auto *surfaces = registry();
        if (!guest_id || !surfaces || !opened_.count(*guest_id)) {
            return nullptr;
        }
        id = *guest_id;
        return surfaces->guest(id);
    }

    std::int32_t surface_manager_channel::create_surface(kernel::process *process, eka2l1::ptr<void> attributes_ptr, eka2l1::ptr<void> id_ptr) {
        auto *package = attributes_ptr.cast<epoc::desc8>().get(process);
        auto *id = id_ptr.cast<epoc::surface_id>().get(process);
        auto *surfaces = registry();
        if (!package || !id || package->get_length() < sizeof(surface_creation_attributes)) {
            return epoc::error_argument;
        }
        if (!surfaces) {
            return epoc::error_not_ready;
        }
        surface_creation_attributes attributes;
        std::memcpy(&attributes, package->get_pointer(process), sizeof(attributes));
        if (attributes.size.x <= 0 || attributes.size.y <= 0 || attributes.buffers <= 0 || attributes.offset_to_first_buffer < 0
            || attributes.offset_between_buffers < 0 || attributes.hint_count < 0 || attributes.hint_count > MAX_HINTS_PER_SURFACE) {
            return epoc::error_argument;
        }
        if (!epoc::guest_surface::format_supported(attributes.pixel_format)) {
            return epoc::error_not_supported;
        }
        std::uint32_t align = 0;
        switch (attributes.alignment) {
        case 1: case 2: case 4: case 8: case 16: case 32:
            align = 32;
            break;
        case 64:
            align = 64;
            break;
        case PAGE_ALIGNED:
            align = PAGE_SIZE;
            break;
        default:
            return epoc::error_argument;
        }
        const auto round = [align](std::uint64_t value) { return (value + align - 1) & ~static_cast<std::uint64_t>(align - 1); };
        const std::uint64_t minimum_stride = static_cast<std::uint64_t>(attributes.size.x) * bytes_per_pixel(attributes.pixel_format);
        if (static_cast<std::uint64_t>(attributes.stride) < minimum_stride) {
            return epoc::error_argument;
        }
        const std::uint64_t buffer_size = static_cast<std::uint64_t>(attributes.stride) * attributes.size.y;
        const std::uint64_t first = round(attributes.offset_to_first_buffer);
        const std::uint64_t pitch = round(attributes.offset_between_buffers ? attributes.offset_between_buffers : buffer_size);
        const std::uint64_t total = (first + pitch * attributes.buffers + PAGE_SIZE - 1) & ~static_cast<std::uint64_t>(PAGE_SIZE - 1);
        if (pitch < buffer_size || total > static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())) {
            return epoc::error_argument;
        }
        auto *chunk = kern->create<kernel::chunk>(kern->get_memory_system(), nullptr, "Surface", 0,
            static_cast<address>(total), static_cast<std::size_t>(total), prot_read_write, kernel::chunk_type::normal,
            kernel::chunk_access::kernel_mapping, kernel::chunk_attrib::none);
        if (!chunk) {
            return epoc::error_no_memory;
        }
        std::memset(chunk->host_base(), 0, static_cast<std::size_t>(total));
        chunk->increase_access_count();

        epoc::guest_surface guest;
        guest.surface = std::make_shared<epoc::window_surface>();
        guest.surface->set_streaming(true);
        guest.chunk = chunk;
        guest.size = attributes.size;
        guest.pixel_format = attributes.pixel_format;
        guest.stride = static_cast<std::uint32_t>(attributes.stride);
        guest.buffers = static_cast<std::uint32_t>(attributes.buffers);
        guest.first_buffer = static_cast<std::uint32_t>(first);
        guest.buffer_pitch = static_cast<std::uint32_t>(pitch);
        guest.references = 1;
        *id = surfaces->add_guest(guest);
        opened_[*id] = 1;
        return epoc::error_none;
    }

    std::int32_t surface_manager_channel::do_control(kernel::thread *r, const std::uint32_t n,
        const eka2l1::ptr<void> arg1, const eka2l1::ptr<void> arg2) {
        kernel::process *process = r->owning_process();
        epoc::surface_id id{};

        switch (n) {
        case surface_manager_create_surface:
            return create_surface(process, arg1, arg2);

        case surface_manager_open_surface: {
            const auto *guest_id = arg1.cast<epoc::surface_id>().get(process);
            auto *surfaces = registry();
            auto *guest = (guest_id && surfaces) ? surfaces->guest(*guest_id) : nullptr;
            if (!guest) {
                return epoc::error_argument;
            }
            guest->references++;
            opened_[*guest_id]++;
            return epoc::error_none;
        }

        case surface_manager_close_surface: {
            const auto *guest_id = arg1.cast<epoc::surface_id>().get(process);
            auto *surfaces = registry();
            if (!guest_id || !surfaces || !surfaces->guest(*guest_id)) {
                return epoc::error_argument;
            }
            const auto it = opened_.find(*guest_id);
            if (it == opened_.end()) {
                return epoc::error_access_denied;
            }
            id = *guest_id;
            if (--it->second == 0) {
                opened_.erase(it);
            }
            release(id, 1);
            return epoc::error_none;
        }

        case surface_manager_access_surface_data: {
            auto *guest = opened(process, arg1, id);
            if (!guest) {
                return epoc::error_argument;
            }
            return static_cast<std::int32_t>(kern->open_handle_with_thread(r, guest->chunk, kernel::owner_type::thread));
        }

        case surface_manager_surface_info: {
            auto *guest = opened(process, arg1, id);
            auto *package = arg2.cast<epoc::des8>().get(process);
            if (!guest || !package) {
                return epoc::error_argument;
            }
            surface_info info{};
            info.size = guest->size;
            info.buffers = static_cast<std::int32_t>(guest->buffers);
            info.pixel_format = guest->pixel_format;
            info.stride = static_cast<std::int32_t>(guest->stride);
            info.mappable = 1;
            package->assign(process, reinterpret_cast<const std::uint8_t *>(&info), sizeof(info));
            return epoc::error_none;
        }

        case surface_manager_get_buffer_offset: {
            const auto *param = arg1.cast<device_param>().get(process);
            auto *offset = arg2.cast<std::int32_t>().get(process);
            auto *guest = param ? opened(process, param->surface_id, id) : nullptr;
            if (!guest || !offset || param->buffer >= guest->buffers) {
                return epoc::error_argument;
            }
            *offset = static_cast<std::int32_t>(guest->first_buffer + param->buffer * guest->buffer_pitch);
            return epoc::error_none;
        }

        case surface_manager_synchronize_cache: {
            const auto *param = arg1.cast<device_param>().get(process);
            auto *guest = param ? opened(process, param->surface_id, id) : nullptr;
            return (guest && param->buffer < guest->buffers) ? epoc::error_none : epoc::error_argument;
        }

        case surface_manager_get_attribute: {
            const auto *attribute = arg1.cast<std::int32_t>().get(process);
            auto *value = arg2.cast<std::int32_t>().get(process);
            if (!attribute || !value || *attribute != 0) {
                return epoc::error_argument;
            }
            *value = MAX_HINTS_PER_SURFACE;
            return epoc::error_none;
        }

        default:
            break;
        }

        LOG_TRACE(KERNEL, "Unimplemented surface manager control opcode {}", n);
        return epoc::error_not_supported;
    }

    std::int32_t surface_manager_channel::do_request(epoc::notify_info info, const std::uint32_t n,
        const eka2l1::ptr<void> arg1, const eka2l1::ptr<void> arg2, const bool is_supervisor) {
        return epoc::error_not_supported;
    }
}
