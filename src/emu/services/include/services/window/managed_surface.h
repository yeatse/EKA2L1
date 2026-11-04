/*
 * Copyright (c) 2026 EKA2L1 Team.
 * This file is part of EKA2L1, licensed under GPLv3 or later.
 */

#pragma once

#include <services/window/surface.h>
#include <kernel/kernel_obj.h>

#include <map>
#include <memory>

namespace eka2l1 {
    class kernel_system;
    namespace kernel {
        class chunk;
        class thread;
    }
}

namespace eka2l1::epoc {
    constexpr std::int32_t MANAGED_SURFACE_ARGB8888_PRE = 0x1027549a;

    struct managed_surface_attributes {
        eka2l1::vec2 size{};
        std::int32_t buffers = 0;
        std::int32_t pixel_format = 0;
        std::int32_t stride = 0;
        std::int32_t first_offset = 0;
        std::int32_t alignment = 0;
        std::int32_t contiguous = 0;
        std::int32_t cache_attrib = 0;
        std::int32_t buffer_spacing = 0;
        std::int32_t hint_count = 0;
        std::int32_t mappable = 0;
    };

    struct managed_surface_info {
        eka2l1::vec2 size{};
        std::int32_t buffers = 0;
        std::int32_t pixel_format = 0;
        std::int32_t stride = 0;
        std::int32_t contiguous = 0;
        std::int32_t cache_attrib = 0;
        std::int32_t mappable = 0;
    };

    struct managed_surface_storage {
        std::int32_t stride = 0;
        std::int32_t first_offset = 0;
        std::int32_t buffer_spacing = 0;
        std::uint32_t bytes = 0;
    };

    // Pure validation of the supported public creation contract. Unsupported
    // hardware options are rejected rather than silently approximated.
    std::int32_t validate_managed_surface(const managed_surface_attributes &attributes,
        managed_surface_storage &storage);

    class managed_surface {
        kernel_system *kernel_;
        kernel::uid chunk_uid_;

    public:
        managed_surface(kernel_system *kernel, kernel::uid chunk_uid,
            const managed_surface_attributes &requested, const managed_surface_storage &storage);
        ~managed_surface();

        const managed_surface_attributes attributes;
        const managed_surface_storage storage;
        const std::shared_ptr<window_surface> producer;
        std::map<kernel::uid, std::uint32_t> owners;
        std::uint32_t registrations = 0;

        kernel::chunk *chunk() const;
        // Copies the submitted buffer into an owned image before returning.
        bool publish(std::int32_t buffer);
    };

    class managed_surface_registry {
        kernel_system *kernel_;
        std::shared_ptr<surface_registry> producers_;
        std::map<surface_id, std::shared_ptr<managed_surface>> surfaces_;
        std::map<kernel::uid, std::uint32_t> channels_;
        struct registration {
            std::shared_ptr<managed_surface> managed;
            std::shared_ptr<window_surface> producer;
        };
        struct window_registration {
            surface_id id;
            std::int32_t screen;
            registration retained;
        };
        using registration_key = std::pair<kernel::uid, std::int32_t>;
        std::map<registration_key, std::map<surface_id, registration>> registrations_;
        std::map<kernel::uid, window_registration> windows_;
        void collect(const surface_id &id);

    public:
        explicit managed_surface_registry(kernel_system *kernel,
            const std::shared_ptr<surface_registry> &producers);

        void attach_channel(kernel::uid process);
        void detach_channel(kernel::uid process);
        std::int32_t create(kernel::thread *thread, const managed_surface_attributes &attributes, surface_id &id);
        std::int32_t open(kernel::uid process, const surface_id &id);
        std::int32_t close(kernel::uid process, const surface_id &id);
        std::int32_t map(kernel::thread *thread, const surface_id &id);
        std::int32_t info(kernel::uid process, const surface_id &id, managed_surface_info &result) const;
        std::int32_t buffer_offset(kernel::uid process, const surface_id &id, std::int32_t buffer, std::int32_t &offset) const;
        std::int32_t synchronize(kernel::uid process, const surface_id &id, std::int32_t buffer, std::int32_t operation) const;

        std::shared_ptr<managed_surface> find(const surface_id &id) const;
        std::shared_ptr<managed_surface> find_owned(kernel::uid process, const surface_id &id, std::int32_t &error) const;
        std::int32_t register_surface(kernel::uid session, std::int32_t screen, const surface_id &id);
        void unregister_surface(kernel::uid session, std::int32_t screen, const surface_id &id);
        void unregister_session(kernel::uid session);
        void retain_window(kernel::uid window, std::int32_t screen, const std::shared_ptr<window_surface> &producer);
        void release_window(kernel::uid window);
        bool registered(const surface_id &id, std::int32_t screen) const;
    };
}
