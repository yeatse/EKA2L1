/* Copyright (c) 2026 EKA2L1 Team. GPLv3 or later. */
#include <services/window/managed_surface.h>
#include <kernel/chunk.h>
#include <kernel/kernel.h>
#include <kernel/process.h>
#include <kernel/thread.h>
#include <utils/err.h>
#include <algorithm>
#include <atomic>
#include <limits>
#include <new>

namespace eka2l1::epoc {
    namespace {
        constexpr std::uint64_t MAX_SURFACE_BYTES = 32u * 1024 * 1024;
        constexpr std::uint64_t MAX_REGISTERED_BYTES = 64u * 1024 * 1024;
        std::uint64_t round_up(std::uint64_t value, std::uint64_t alignment) { return (value + alignment - 1) / alignment * alignment; }
    }
    std::int32_t validate_managed_surface(const managed_surface_attributes &a, managed_surface_storage &out) {
        out = {};
        if (a.size.x <= 0 || a.size.y <= 0 || a.buffers <= 0 || a.stride < 0 || a.first_offset < 0
            || a.buffer_spacing < 0 || a.hint_count < 0 || a.cache_attrib < 0 || a.cache_attrib > 1
            || a.contiguous < 0 || a.contiguous > 1 || a.mappable < 0 || a.mappable > 1) { return epoc::error_argument; }
        if (a.alignment != -1 && a.alignment != 1 && a.alignment != 2 && a.alignment != 4
            && a.alignment != 8 && a.alignment != 16 && a.alignment != 32 && a.alignment != 64) { return epoc::error_argument; }
        if (a.pixel_format != MANAGED_SURFACE_ARGB8888_PRE || !a.mappable || a.contiguous || a.hint_count) { return epoc::error_not_supported; }
        if (a.size.x > 4096 || a.size.y > 4096 || a.buffers > 3) { return epoc::error_not_supported; }
        std::uint64_t alignment = a.alignment == -1 ? 4096 : a.alignment;
        if (!a.cache_attrib) { alignment = std::max<std::uint64_t>(alignment, 32); }
        const std::uint64_t minimum_stride = static_cast<std::uint64_t>(a.size.x) * 4;
        const std::uint64_t stride = a.stride ? a.stride : minimum_stride;
        if (stride < minimum_stride || stride % 4) { return epoc::error_argument; }
        const std::uint64_t frame_bytes = stride * a.size.y;
        if (a.buffer_spacing && static_cast<std::uint64_t>(a.buffer_spacing) < frame_bytes) { return epoc::error_argument; }
        const auto first = round_up(a.first_offset, alignment);
        const auto spacing = round_up(a.buffer_spacing ? a.buffer_spacing : frame_bytes, alignment);
        const auto total = round_up(first + spacing * a.buffers, 4096);
        if (total > MAX_SURFACE_BYTES || stride > INT32_MAX || first > INT32_MAX || spacing > INT32_MAX) { return epoc::error_no_memory; }
        out = { static_cast<std::int32_t>(stride), static_cast<std::int32_t>(first),
            static_cast<std::int32_t>(spacing), static_cast<std::uint32_t>(total) };
        return epoc::error_none;
    }
    managed_surface::managed_surface(kernel_system *kernel, kernel::uid chunk_uid,
        const managed_surface_attributes &a, const managed_surface_storage &s)
        : kernel_(kernel), chunk_uid_(chunk_uid), attributes(a), storage(s), producer(std::make_shared<window_surface>()) {}
    managed_surface::~managed_surface() {
        if (!kernel_->wipeout_in_progress()) { if (auto *c = chunk()) { c->decrease_access_count(); } }
    }
    kernel::chunk *managed_surface::chunk() const { return kernel_->get_by_id<kernel::chunk>(chunk_uid_); }
    bool managed_surface::publish(std::int32_t buffer) {
        auto *c = chunk();
        if (!c || !c->valid() || !c->host_base() || c->committed() < storage.bytes || buffer < 0 || buffer >= attributes.buffers) { return false; }
        std::atomic_thread_fence(std::memory_order_acquire);
        const auto *source = static_cast<const std::uint8_t *>(c->host_base()) + storage.first_offset + static_cast<std::size_t>(buffer) * storage.buffer_spacing;
        try {
        std::vector<std::uint8_t> rgba(static_cast<std::size_t>(attributes.size.x) * attributes.size.y * 4);
        // Little-endian Symbian ARGB8888_PRE stores BGRA; the mailbox consumes RGBA.
        for (std::int32_t y = 0; y < attributes.size.y; ++y) {
            const auto *row = source + static_cast<std::size_t>(y) * storage.stride;
            auto *dest = rgba.data() + static_cast<std::size_t>(y) * attributes.size.x * 4;
            for (std::int32_t x = 0; x < attributes.size.x; ++x) {
                dest[0] = row[2]; dest[1] = row[1]; dest[2] = row[0]; dest[3] = row[3]; dest += 4; row += 4;
            }
        }
        return producer->publish_pixels(rgba.data(), rgba.size(), attributes.size);
        } catch (const std::bad_alloc &) { return false; }
    }
    managed_surface_registry::managed_surface_registry(kernel_system *kernel,
        const std::shared_ptr<surface_registry> &producers) : kernel_(kernel), producers_(producers) {}
    void managed_surface_registry::attach_channel(kernel::uid process) { ++channels_[process]; }
    void managed_surface_registry::collect(const surface_id &id) {
        const auto it = surfaces_.find(id);
        if (it != surfaces_.end() && it->second->owners.empty() && !it->second->registrations) { surfaces_.erase(it); }
    }
    void managed_surface_registry::detach_channel(kernel::uid process) {
        const auto channel = channels_.find(process);
        if (channel == channels_.end() || --channel->second) { return; }
        channels_.erase(channel);
        for (auto it = surfaces_.begin(); it != surfaces_.end();) {
            it->second->owners.erase(process);
            if (it->second->owners.empty() && !it->second->registrations) { it = surfaces_.erase(it); } else { ++it; }
        }
    }
    std::int32_t managed_surface_registry::create(kernel::thread *thread, const managed_surface_attributes &a, surface_id &id) {
        if (!thread || !thread->owning_process()) { return epoc::error_argument; }
        const auto process = thread->owning_process()->unique_id();
        if (!channels_.count(process)) { return epoc::error_not_ready; }
        managed_surface_storage storage;
        const auto result = validate_managed_surface(a, storage);
        if (result != epoc::error_none) { return result; }
        std::uint64_t allocated = storage.bytes;
        for (const auto &it : surfaces_) { allocated += it.second->storage.bytes; }
        if (surfaces_.size() >= 64 || allocated > MAX_REGISTERED_BYTES) { return epoc::error_no_memory; }
        auto *c = kernel_->create<kernel::chunk>(kernel_->get_memory_system(), nullptr, "ScreenPlaySurface", 0,
            storage.bytes, storage.bytes, prot_read_write, kernel::chunk_type::normal,
            kernel::chunk_access::kernel_mapping, kernel::chunk_attrib::none);
        if (!c) { return epoc::error_no_memory; }
        if (!c->valid() || !c->host_base() || c->committed() < storage.bytes) { kernel_->destroy(c); return epoc::error_no_memory; }
        c->increase_access_count();
        std::shared_ptr<managed_surface> surface;
        try {
            surface = std::make_shared<managed_surface>(kernel_, c->unique_id(), a, storage);
            surface->owners.emplace(process, 1);
            const auto assigned = producers_->add(surface->producer);
            surfaces_.emplace(assigned, surface); id = assigned;
            return epoc::error_none;
        } catch (const std::bad_alloc &) {
            if (!surface) { c->decrease_access_count(); }
            return epoc::error_no_memory;
        }
    }
    std::shared_ptr<managed_surface> managed_surface_registry::find(const surface_id &id) const {
        const auto it = surfaces_.find(id);
        return it == surfaces_.end() ? nullptr : it->second;
    }
    std::shared_ptr<managed_surface> managed_surface_registry::find_owned(kernel::uid process, const surface_id &id, std::int32_t &error) const {
        auto surface = find(id);
        error = !surface ? epoc::error_argument : surface->owners.count(process) ? epoc::error_none : epoc::error_access_denied;
        return error == epoc::error_none ? surface : nullptr;
    }
    std::int32_t managed_surface_registry::open(kernel::uid process, const surface_id &id) {
        auto surface = find(id);
        if (!surface) { return epoc::error_argument; }
        if (!channels_.count(process)) { return epoc::error_not_ready; }
        auto &count = surface->owners[process];
        if (count == UINT32_MAX) { return epoc::error_overflow; }
        ++count; return epoc::error_none;
    }
    std::int32_t managed_surface_registry::close(kernel::uid process, const surface_id &id) {
        std::int32_t result;
        auto surface = find_owned(process, id, result);
        if (!surface) { return result; }
        auto owner = surface->owners.find(process);
        if (!--owner->second) { surface->owners.erase(owner); }
        collect(id); return epoc::error_none;
    }
    std::int32_t managed_surface_registry::map(kernel::thread *thread, const surface_id &id) {
        if (!thread || !thread->owning_process()) { return epoc::error_argument; }
        std::int32_t result;
        auto surface = find_owned(thread->owning_process()->unique_id(), id, result);
        if (!surface) { return result; }
        auto *c = surface->chunk();
        if (!c || !c->valid()) { return epoc::error_bad_handle; }
        const auto handle = kernel_->open_handle_with_thread(thread, c, kernel::owner_type::thread);
        return handle == kernel::INVALID_HANDLE ? epoc::error_no_memory : static_cast<std::int32_t>(handle);
    }
    std::int32_t managed_surface_registry::info(kernel::uid process, const surface_id &id, managed_surface_info &result) const {
        std::int32_t error;
        auto surface = find_owned(process, id, error);
        if (!surface) { return error; }
        const auto &a = surface->attributes;
        result = { a.size, a.buffers, a.pixel_format, surface->storage.stride, 0, a.cache_attrib, 1 };
        return epoc::error_none;
    }
    std::int32_t managed_surface_registry::buffer_offset(kernel::uid process, const surface_id &id,
        std::int32_t buffer, std::int32_t &offset) const {
        std::int32_t error;
        auto surface = find_owned(process, id, error);
        if (!surface) { return error; }
        if (buffer < 0 || buffer >= surface->attributes.buffers) { return epoc::error_argument; }
        offset = surface->storage.first_offset + buffer * surface->storage.buffer_spacing;
        return epoc::error_none;
    }
    std::int32_t managed_surface_registry::synchronize(kernel::uid process, const surface_id &id,
        std::int32_t buffer, std::int32_t operation) const {
        std::int32_t ignored;
        const auto result = buffer_offset(process, id, buffer, ignored);
        if (result != epoc::error_none) { return result; }
        if (operation < 0 || operation > 2) { return epoc::error_argument; }
        if (operation != 0) { return epoc::error_not_supported; }
        // CPU and the owned-copy path share coherent memory. No DMA writer is exposed.
        std::atomic_thread_fence(std::memory_order_seq_cst);
        return epoc::error_none;
    }
    std::int32_t managed_surface_registry::register_surface(kernel::uid session, std::int32_t screen, const surface_id &id) {
        auto producer = producers_->find(id);
        if (!producer) { return epoc::error_argument; }
        auto &registered_surfaces = registrations_[{ session, screen }];
        if (registered_surfaces.count(id)) { return epoc::error_in_use; }
        auto surface = find(id);
        registered_surfaces.emplace(id, registration{ surface, producer });
        if (surface) { ++surface->registrations; }
        return epoc::error_none;
    }
    void managed_surface_registry::unregister_surface(kernel::uid session, std::int32_t screen, const surface_id &id) {
        const auto group = registrations_.find({ session, screen });
        if (group == registrations_.end()) { return; }
        const auto it = group->second.find(id);
        if (it == group->second.end()) { return; }
        if (it->second.managed) { --it->second.managed->registrations; }
        group->second.erase(it);
        if (group->second.empty()) { registrations_.erase(group); }
        collect(id);
    }
    void managed_surface_registry::unregister_session(kernel::uid session) {
        for (auto group = registrations_.begin(); group != registrations_.end();) {
            if (group->first.first != session) { ++group; continue; }
            std::vector<surface_id> affected;
            for (const auto &it : group->second) {
                if (it.second.managed) { --it.second.managed->registrations; }
                affected.push_back(it.first);
            }
            group = registrations_.erase(group);
            for (const auto &id : affected) { collect(id); }
        }
    }
    bool managed_surface_registry::registered(const surface_id &id, std::int32_t screen) const {
        for (const auto &group : registrations_) {
            if ((screen == 0xffffff || screen == group.first.second) && group.second.count(id)) { return true; }
        }
        for (const auto &entry : windows_) {
            if (entry.second.id == id && (screen == 0xffffff || screen == entry.second.screen)) { return true; }
        }
        return false;
    }
    void managed_surface_registry::retain_window(kernel::uid window, std::int32_t screen,
        const std::shared_ptr<window_surface> &producer) {
        const auto existing = windows_.find(window);
        if (existing != windows_.end() && existing->second.retained.producer == producer) {
            existing->second.screen = screen;
            return;
        }
        release_window(window);
        if (!producer) { return; }
        const auto id = producers_->add(producer);
        auto surface = find(id);
        if (surface) { ++surface->registrations; }
        windows_.emplace(window, window_registration{ id, screen, registration{ surface, producer } });
    }
    void managed_surface_registry::release_window(kernel::uid window) {
        const auto entry = windows_.find(window);
        if (entry == windows_.end()) { return; }
        const auto id = entry->second.id;
        if (entry->second.retained.managed) { --entry->second.retained.managed->registrations; }
        windows_.erase(entry);
        collect(id);
    }
}
