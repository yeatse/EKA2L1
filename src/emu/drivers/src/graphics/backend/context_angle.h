// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#if defined(__OBJC__)
#import <Foundation/Foundation.h>
@class MGLContext;
@class MGLLayer;
#else
struct MGLContext;
struct MGLLayer;
#endif

#include <drivers/graphics/context.h>

namespace eka2l1::drivers::graphics {
    // MetalANGLE-backed GLES3 context (GLES -> Metal) for the iOS frontend.
    //
    // Constructed with `window_system_info::render_surface` pointing at an
    // MGLLayer (MetalANGLE's CALayer-derived presentation layer, backed by a
    // CAMetalLayer). Unlike the EAGL path, MGLContext / MGLLayer own the default
    // framebuffer, the depth/stencil attachments, and the present, so this class
    // is a thin adapter: it just routes make-current / present / resize to the
    // MGL objects. Selected over gl_context_eagl when EKA2L1_IOS_ANGLE is set.
    class gl_context_angle final : public gl_context {
    public:
        gl_context_angle() = default;
        gl_context_angle(const window_system_info &wsi, bool stereo, bool core);

        ~gl_context_angle() override;

        bool is_headless() const override;

        std::unique_ptr<gl_context> create_shared_context() override;

        bool make_current() override;
        bool clear_current() override;

        void swap_buffers() override;
        void update(std::uint32_t new_width, std::uint32_t new_height) override;
        void set_swap_interval(std::int32_t interval) override;

        // iOS lifecycle: stop GL traffic before losing foreground (see the EAGL
        // context for the rationale).
        void pause();
        void resume();

        void update_surface(void *new_surface) override;

        // MGLLayer owns the default FBO; report it so the GL backend renders to
        // the swapchain instead of FBO 0.
        unsigned int swapchain_framebuffer() const override;

    private:
        void configure_layer(MGLLayer *layer);

        MGLContext *m_context = nullptr;
        MGLLayer *m_layer = nullptr;

        bool m_paused = false;
    };
}
