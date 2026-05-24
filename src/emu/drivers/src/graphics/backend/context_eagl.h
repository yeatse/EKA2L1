// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#if defined(__OBJC__)
#import <Foundation/Foundation.h>
@class EAGLContext;
@class CALayer;
@class CAEAGLLayer;
@class CAMetalLayer;
#else
struct EAGLContext;
struct CALayer;
struct CAEAGLLayer;
struct CAMetalLayer;
#endif

#include <drivers/graphics/context.h>

#include <cstdint>
#include <vector>

namespace eka2l1::drivers::graphics {
    // EAGL-backed GLES3 context for the iOS frontend.
    //
    // The frontend normally provides a CAMetalLayer, so swap_buffers reads the
    // GLES framebuffer and presents it through Metal. The old CAEAGLLayer path
    // stays available for the Settings fallback switch.
    class gl_context_eagl final : public gl_context {
    public:
        gl_context_eagl() = default;
        gl_context_eagl(const window_system_info &wsi, bool stereo, bool core);

        ~gl_context_eagl() override;

        bool is_headless() const override;

        std::unique_ptr<gl_context> create_shared_context() override;

        bool make_current() override;
        bool clear_current() override;

        void swap_buffers() override;
        void update(std::uint32_t new_width, std::uint32_t new_height) override;
        void set_swap_interval(std::int32_t interval) override;

        // The iOS lifecycle requires GL traffic to stop before the app loses
        // foreground. The frontend calls pause() from `scenePhase` ≠ .active
        // (glFinish + clear current) and resume() when it returns.
        void pause();
        void resume();

        // Replace the bound render CALayer (e.g. after the view is recreated
        // by SwiftUI on a navigation transition).
        void update_surface(void *new_surface) override;

        unsigned int swapchain_framebuffer() const override {
            return m_framebuffer;
        }

    private:
        enum class surface_backend {
            none,
            eagl,
            metal,
        };

        bool attach_surface(CALayer *layer);
        bool attach_eagl_layer(CAEAGLLayer *layer);
        bool attach_metal_layer(CAMetalLayer *layer);
        bool create_offscreen_buffers(std::uint32_t width, std::uint32_t height);
        void present_metal();
        void release_renderbuffers();
        void release_metal_objects();

        EAGLContext *m_context = nullptr;
        CALayer *m_layer = nullptr;
        CAMetalLayer *m_metal_layer = nullptr;
        void *m_metal_device = nullptr;
        void *m_metal_queue = nullptr;

        unsigned int m_framebuffer = 0;
        unsigned int m_colorbuffer = 0;
        unsigned int m_depthbuffer = 0;

        surface_backend m_surface_backend = surface_backend::none;
        std::vector<std::uint8_t> m_readback_rgba;
        std::vector<std::uint8_t> m_upload_bgra;

        bool m_paused = false;
    };
}
