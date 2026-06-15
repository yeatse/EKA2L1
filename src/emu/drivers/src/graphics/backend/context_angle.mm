// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#include "context_angle.h"

#include <common/log.h>

#import <MetalANGLE/MGLContext.h>
#import <MetalANGLE/MGLLayer.h>
#import <MetalANGLE/GLES3/gl3.h>

namespace eka2l1::drivers::graphics {
    gl_context_angle::gl_context_angle(const window_system_info &wsi, bool /*stereo*/, bool /*core*/) {
        m_opengl_mode = mode::opengl_es;

        m_context = [[MGLContext alloc] initWithAPI:kMGLRenderingAPIOpenGLES3];
        if (!m_context) {
            LOG_CRITICAL(DRIVER_GRAPHICS, "MGLContext (MetalANGLE) creation failed");
            return;
        }

        // The frontend hands render_surface as an opaque CALayer pointer. Only
        // adopt it if it is actually an MGLLayer (MetalANGLE's presentation
        // layer); otherwise stay headless rather than message a wrong class.
        id surface = (__bridge id)wsi.render_surface;
        if ([surface isKindOfClass:[MGLLayer class]]) {
            MGLLayer *layer = (MGLLayer *)surface;
            configure_layer(layer);
            m_layer = layer;
        } else if (surface) {
            LOG_WARN(DRIVER_GRAPHICS, "ANGLE context: render_surface is not an MGLLayer; staying headless");
        }

        make_current();
    }

    gl_context_angle::~gl_context_angle() {
        if (m_context && [MGLContext currentContext] == m_context) {
            [MGLContext setCurrentContext:nil];
        }
        m_context = nil;
        m_layer = nil;
    }

    void gl_context_angle::configure_layer(MGLLayer *layer) {
        // Match the EAGL swapchain: 8-bit RGBA colour plus a 24/8 depth-stencil
        // so the guest 3D titles have a depth buffer on the default framebuffer.
        // CALayer property mutation belongs on the main thread; the graphics
        // driver is constructed on a worker thread, so bounce it across.
        dispatch_block_t work = ^{
            layer.drawableColorFormat = MGLDrawableColorFormatRGBA8888;
            layer.drawableDepthFormat = MGLDrawableDepthFormat24;
            layer.drawableStencilFormat = MGLDrawableStencilFormat8;
            layer.retainedBacking = NO;
        };

        if ([NSThread isMainThread]) {
            work();
        } else {
            dispatch_sync(dispatch_get_main_queue(), work);
        }
    }

    bool gl_context_angle::is_headless() const {
        return m_layer == nil;
    }

    std::unique_ptr<gl_context> gl_context_angle::create_shared_context() {
        // Single render/upload thread on iOS, same as the EAGL path.
        return nullptr;
    }

    bool gl_context_angle::make_current() {
        if (!m_context) {
            return false;
        }
        if (m_layer) {
            return [MGLContext setCurrentContext:m_context forLayer:m_layer] == YES;
        }
        return [MGLContext setCurrentContext:m_context] == YES;
    }

    bool gl_context_angle::clear_current() {
        return [MGLContext setCurrentContext:nil] == YES;
    }

    void gl_context_angle::swap_buffers() {
        if (m_paused || !m_context || !m_layer) {
            return;
        }
        [m_context present:m_layer];
    }

    void gl_context_angle::update(std::uint32_t new_width, std::uint32_t new_height) {
        m_backbuffer_width = new_width;
        m_backbuffer_height = new_height;
        // MGLLayer derives its drawableSize from the layer bounds * contentsScale,
        // which the frontend view updates on layout; there is nothing to re-bind.
    }

    void gl_context_angle::set_swap_interval(std::int32_t /*interval*/) {
        // CAMetalLayer present is implicitly display-synced; no tunable here.
    }

    void gl_context_angle::pause() {
        if (m_paused || !m_context) {
            return;
        }
        if ([MGLContext currentContext] == m_context) {
            glFinish();
            [MGLContext setCurrentContext:nil];
        }
        m_paused = true;
    }

    void gl_context_angle::resume() {
        if (!m_paused) {
            return;
        }
        m_paused = false;
        make_current();
    }

    void gl_context_angle::update_surface(void *new_surface) {
        id surface = (__bridge id)new_surface;
        MGLLayer *layer = [surface isKindOfClass:[MGLLayer class]] ? (MGLLayer *)surface : nil;
        if (layer == m_layer) {
            return;
        }
        if (layer) {
            configure_layer(layer);
        }
        m_layer = layer;
        make_current();
    }

    unsigned int gl_context_angle::swapchain_framebuffer() const {
        return m_layer ? m_layer.defaultOpenGLFrameBufferID : 0;
    }
}
