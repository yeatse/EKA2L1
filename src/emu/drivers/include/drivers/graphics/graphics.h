/*
 * Copyright (c) 2018 EKA2L1 Team.
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

#pragma once

#include <common/vecx.h>

#include <drivers/driver.h>
#include <drivers/graphics/common.h>
#include <drivers/itc.h>

#include <functional>
#include <memory>
#include <algorithm>
#include <chrono>
#include <limits>
#include <map>

namespace eka2l1::drivers {
    enum graphics_driver_opcode : std::uint16_t {
        // Mode -1: Miscs
        graphics_driver_clip_rect,
        graphics_driver_clip_bitmap_rect,
        graphics_driver_set_feature,
        graphics_driver_set_viewport,
        graphics_driver_set_bitmap_viewport,
        graphics_driver_blend_formula,
        graphics_driver_depth_pass_condition,
        graphics_driver_depth_set_mask,
        graphics_driver_stencil_pass_condition,
        graphics_driver_stencil_set_action,
        graphics_driver_stencil_set_mask,
        graphics_driver_set_front_face_rule,
        graphics_driver_set_swapchain_size,
        graphics_driver_set_ortho_size,
        graphics_driver_cull_face,

        // Mode 0: Immediate - Draw direct 2D elements to screen
        // Don't mix it with advance mode
        graphics_driver_clear,
        graphics_driver_create_bitmap,
        graphics_driver_destroy_bitmap,
        graphics_driver_bind_bitmap,
        graphics_driver_set_brush_color,
        graphics_driver_update_bitmap,
        graphics_driver_update_texture,
        graphics_driver_draw_bitmap,
        graphics_driver_draw_rectangle,
        graphics_driver_draw_line,
        graphics_driver_draw_polygon,
        graphics_driver_set_point_size,
        graphics_driver_set_pen_style,
        graphics_driver_resize_bitmap,
        graphics_driver_read_bitmap,
        graphics_driver_clip_region,

        // Mode 1: Advance - Lower access to functions
        graphics_driver_create_shader_module,
        graphics_driver_create_shader_program,
        graphics_driver_create_renderbuffer,
        graphcis_driver_create_framebuffer,
        graphics_driver_create_texture,
        graphics_driver_create_buffer,
        graphics_driver_destroy_object,
        graphics_driver_set_texture_filter,
        graphics_driver_set_texture_wrap,
        graphics_driver_generate_mips,
        graphics_driver_set_max_mip_level,
        graphics_driver_set_texture_anisotrophy,
        graphics_driver_use_program,
        graphics_driver_set_uniform,
        graphics_driver_bind_texture,
        graphics_driver_bind_vertex_buffers,
        graphics_driver_bind_index_buffer,
        graphics_driver_bind_framebuffer,
        graphics_driver_set_texture_for_shader,
        graphics_driver_draw_array,
        graphics_driver_draw_indexed,
        graphics_driver_update_buffer,
        graphics_driver_set_state,
        graphics_driver_display,
        graphics_driver_set_swizzle,
        graphics_driver_set_color_mask,
        graphics_driver_set_depth_func,
        graphics_driver_set_line_width,
        graphics_driver_create_input_descriptor,
        graphics_driver_bind_input_descriptor,
        graphics_driver_set_depth_bias,
        graphics_driver_set_depth_range,
        graphics_driver_set_framebuffer_color_buffer,
        graphics_driver_set_framebuffer_depth_stencil_buffer,
        graphics_driver_set_blend_colour,
        graphics_driver_read_framebuffer,
        graphics_driver_backup_state, // Backup all possible state to a struct
        graphics_driver_restore_state, // Restore previously backup data
        graphics_driver_copy_framebuffer_to_texture,
        graphics_driver_validate_program,
        graphics_driver_get_shader_precision,
        graphics_driver_get_integer,
        graphics_driver_get_float,
        graphics_driver_finish
    };

    enum class finite_finish_result {
        success,
        not_supported,
        aborted,
        timed_out
    };

    enum graphics_driver_extension {
        graphics_driver_extension_anisotrophy_filtering = 1 << 0,
        graphics_driver_extension_float_precision_qualifier = 1 << 1,
        graphics_driver_extension_glsl_es_100 = 1 << 2
    };

    enum graphics_driver_extension_query {
        graphics_driver_extension_query_max_texture_max_anisotrophy,
        graphics_driver_extension_query_point_size_range
    };

    using display_hook = std::function<void()>;

    class graphics_driver : public driver {
        graphic_api api_;
        struct finite_finish_state {
            bool complete = false;
            finite_finish_result result = finite_finish_result::aborted;
        };
        std::mutex finite_finish_mutex_;
        std::condition_variable finite_finish_condition_;
        std::map<std::uint64_t, std::shared_ptr<finite_finish_state>> finite_finishes_;
        std::uint64_t next_finite_finish_ = 1;

    protected:
        display_hook disp_hook_;

        // An accepted command list owns its command storage, just like ordinary
        // submission. This path must never wait for queue capacity.
        virtual bool try_submit_finite_finish(command_list &) {
            return false;
        }

        finite_finish_result queued_finite_finish(const std::uint32_t timeout_ms) {
            if (!timeout_ms) {
                return finite_finish_result::timed_out;
            }
            const auto deadline = std::chrono::steady_clock::now()
                + std::chrono::milliseconds(std::min(timeout_ms, std::uint32_t{2000}));
            auto state = std::make_shared<finite_finish_state>();
            auto storage = std::make_unique<command[]>(1);
            command_list commands(1);
            commands.base_ = storage.get();
            commands.size_ = 1;
            commands.base_[0].opcode_ = graphics_driver_finish;
            std::uint64_t token = 0;
            {
                const std::lock_guard<std::mutex> guard(finite_finish_mutex_);
                if (aborted() || next_finite_finish_ == std::numeric_limits<std::uint64_t>::max()) {
                    return finite_finish_result::aborted;
                }
                token = next_finite_finish_++;
                finite_finishes_.emplace(token, state);
            }
            // Only the opaque token crosses the driver queue. In particular,
            // status_ stays null: a late command cannot write a caller's stack.
            commands.base_[0].data_[0] = token;
            if (!try_submit_finite_finish(commands)) {
                const std::lock_guard<std::mutex> guard(finite_finish_mutex_);
                finite_finishes_.erase(token);
                return aborted() ? finite_finish_result::aborted : finite_finish_result::timed_out;
            }
            storage.release();
            std::unique_lock<std::mutex> lock(finite_finish_mutex_);
            const bool completed = finite_finish_condition_.wait_until(lock, deadline,
                [&]() { return state->complete || aborted(); });
            finite_finishes_.erase(token);
            if (state->complete) {
                return state->result;
            }
            return completed ? finite_finish_result::aborted : finite_finish_result::timed_out;
        }

        bool finite_finish_pending(const std::uint64_t token) {
            const std::lock_guard<std::mutex> guard(finite_finish_mutex_);
            return finite_finishes_.count(token) != 0;
        }

        void complete_finite_finish(const std::uint64_t token,
            const finite_finish_result result) {
            const std::lock_guard<std::mutex> guard(finite_finish_mutex_);
            const auto pending = finite_finishes_.find(token);
            if (pending == finite_finishes_.end()) {
                return;
            }
            pending->second->result = result;
            pending->second->complete = true;
            finite_finishes_.erase(pending);
            finite_finish_condition_.notify_all();
        }

        void abort_finite_finishes() {
            const std::lock_guard<std::mutex> guard(finite_finish_mutex_);
            for (const auto &pending : finite_finishes_) {
                pending.second->result = finite_finish_result::aborted;
                pending.second->complete = true;
            }
            finite_finishes_.clear();
            finite_finish_condition_.notify_all();
        }

    public:
        explicit graphics_driver(graphic_api api)
            : api_(api) {}

        virtual ~graphics_driver() {
        }

        // Completes prior queued drawing, not physical display scanout. The
        // caller must retain the driver for the duration of this call. Backends
        // opt in only when they provide actual ordered rendering completion.
        virtual finite_finish_result finite_finish(const std::uint32_t = 2000) {
            return finite_finish_result::not_supported;
        }

        const graphic_api get_current_api() const {
            return api_;
        }

        virtual bool is_stricted() const {
            return false;
        }

        /**
         * \brief Largest 2D texture dimension the backend can allocate.
         *
         * Used to keep dynamically-grown textures (e.g. the font glyph atlas)
         * within what the GPU accepts — exceeding it makes texture creation
         * fail and the texture sample as opaque black. The conservative default
         * matches the GLES 3.0 minimum guarantee; backends override with the
         * real queried value.
         */
        virtual std::uint32_t max_texture_size() const {
            return 2048;
        }

        /**
         * \brief Set a hook when display function is called.
         *
         * On Vulkan, display may be done using vkQueueDisplayKHR, then you can hook to do things like for example,
         * polling window events.
         *
         * On OpenGL, this hook is expected to swap buffers and also do other things.
         *
         * \param hook    Contains function to hook.
         */
        void set_display_hook(display_hook hook) {
            disp_hook_ = hook;
        }

        virtual void update_bitmap(drivers::handle h, const std::size_t size, const eka2l1::vec2 &offset,
            const eka2l1::vec2 &dim, const void *data, const std::size_t pixels_per_line = 0)
            = 0;

        virtual void set_viewport(const eka2l1::rect &viewport) = 0;
        virtual void update_surface(void *surface) = 0;
        virtual void update_surface_size(const eka2l1::vec2 &size) = 0;

        /**
         * \brief Submit a command list.
         * 
         * The list object will be copied within the function, and can be safely delete after.
         *
         * \param cmd_list     Command list to submit.
         */
        virtual void submit_command_list(command_list &cmd_list) = 0;

        virtual void set_upscale_shader(const std::string &name) = 0;
        virtual std::string get_active_upscale_shader() const = 0;

        virtual bool support_extension(const graphics_driver_extension ext) = 0;
        virtual bool query_extension_value(const graphics_driver_extension_query query, void *data_ptr) = 0;
    };

    using graphics_driver_ptr = std::unique_ptr<graphics_driver>;

    graphics_driver_ptr create_graphics_driver(const graphic_api api, const window_system_info &info);
};
