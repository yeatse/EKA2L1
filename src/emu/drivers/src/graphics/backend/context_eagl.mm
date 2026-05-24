// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later

#include "context_eagl.h"

#include <algorithm>

#include <common/log.h>
#include <drivers/graphics/backend/ogl/ios_gl_loader.h>

#import <Metal/Metal.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/CALayer.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <QuartzCore/CAMetalLayer.h>

namespace eka2l1::drivers::graphics {
    gl_context_eagl::gl_context_eagl(const window_system_info &wsi, bool /*stereo*/, bool /*core*/) {
        m_opengl_mode = mode::opengl_es;

        m_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!m_context) {
            // Older simulators may not advertise GLES3; fall back to GLES2 so
            // the smoke / link path still passes. Real rendering needs GLES3.
            m_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
            if (!m_context) {
                LOG_CRITICAL(DRIVER_GRAPHICS, "EAGLContext creation failed");
                return;
            }
        }

        [EAGLContext setCurrentContext:m_context];

        CALayer *layer = (__bridge CALayer *)wsi.render_surface;
        if (!layer) {
            // Frontend may attach the layer later via update_surface.
            create_offscreen_buffers(wsi.surface_width, wsi.surface_height);
            return;
        }

        attach_surface(layer);
    }

    gl_context_eagl::~gl_context_eagl() {
        release_renderbuffers();

        if (m_framebuffer != 0) {
            glDeleteFramebuffers(1, &m_framebuffer);
            m_framebuffer = 0;
        }
        release_metal_objects();

        if (m_context && [EAGLContext currentContext] == m_context) {
            [EAGLContext setCurrentContext:nil];
        }
        m_context = nil;
        m_layer = nil;
    }

    bool gl_context_eagl::is_headless() const {
        return m_layer == nil;
    }

    std::unique_ptr<gl_context> gl_context_eagl::create_shared_context() {
        // Shared GL contexts on iOS need an EAGLSharegroup; not used by the
        // current frontend (rendering and resource upload share one thread).
        return nullptr;
    }

    bool gl_context_eagl::make_current() {
        if (!m_context) {
            return false;
        }
        return [EAGLContext setCurrentContext:m_context] == YES;
    }

    bool gl_context_eagl::clear_current() {
        return [EAGLContext setCurrentContext:nil] == YES;
    }

    void gl_context_eagl::swap_buffers() {
        if (m_paused || !m_context || m_colorbuffer == 0) {
            return;
        }
        if (m_surface_backend == surface_backend::metal) {
            present_metal();
            return;
        }
        glBindRenderbuffer(GL_RENDERBUFFER, m_colorbuffer);
        [m_context presentRenderbuffer:GL_RENDERBUFFER];
    }

    void gl_context_eagl::update(std::uint32_t new_width, std::uint32_t new_height) {
        m_backbuffer_width = new_width;
        m_backbuffer_height = new_height;

        if (m_layer == nil) {
            return;
        }

        if (m_surface_backend == surface_backend::metal) {
            create_offscreen_buffers(new_width, new_height);
            return;
        }

        // The renderbuffer storage is sized from the layer's drawable; re-bind
        // it so the next presentRenderbuffer: picks up the new dimensions.
        attach_surface(m_layer);
    }

    void gl_context_eagl::set_swap_interval(std::int32_t /*interval*/) {
        // CAEAGLLayer presentation is implicitly vsynced; no API to tune.
    }

    void gl_context_eagl::pause() {
        if (m_paused || !m_context) {
            return;
        }
        if ([EAGLContext currentContext] == m_context) {
            glFinish();
            [EAGLContext setCurrentContext:nil];
        }
        m_paused = true;
    }

    void gl_context_eagl::resume() {
        if (!m_paused) {
            return;
        }
        m_paused = false;
        make_current();
    }

    void gl_context_eagl::update_surface(void *new_surface) {
        CALayer *layer = (__bridge CALayer *)new_surface;
        if (layer == m_layer) {
            return;
        }
        release_renderbuffers();
        attach_surface(layer);
    }

    bool gl_context_eagl::attach_surface(CALayer *layer) {
        if (!layer) {
            m_layer = nil;
            m_metal_layer = nil;
            m_surface_backend = surface_backend::none;
            return false;
        }

        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            return attach_metal_layer((CAMetalLayer *)layer);
        }
        if ([layer isKindOfClass:[CAEAGLLayer class]]) {
            return attach_eagl_layer((CAEAGLLayer *)layer);
        }

        LOG_ERROR(DRIVER_GRAPHICS, "Unsupported iOS render layer class: {}",
            NSStringFromClass([layer class]).UTF8String);
        return false;
    }

    bool gl_context_eagl::attach_eagl_layer(CAEAGLLayer *layer) {
        if (!m_context || !layer) {
            return false;
        }

        // CAEAGLLayer property mutations (opaque / drawableProperties) and the
        // -[EAGLContext renderbufferStorage:fromDrawable:] call (which sets
        // CALayer.contents internally) MUST happen on the main thread, or
        // UIKit raises an exception and the renderbuffer never gets a backing
        // store -- the EmulatorView then stays at clear color. The graphics
        // driver constructor runs on a worker thread, so bounce the layer-
        // touching work to the main queue via dispatch_sync. Pure GL state
        // (depth/stencil renderbuffer, FBO attachments) stays on the caller
        // thread; named GL objects are shared regardless of which thread
        // currently holds the EAGLContext.
        m_layer = layer;
        m_metal_layer = nil;
        m_surface_backend = surface_backend::eagl;

        __block bool layer_ok = true;
        EAGLContext *ctx = m_context;
        CAEAGLLayer *target_layer = (CAEAGLLayer *)m_layer;
        __block GLuint colorbuffer = m_colorbuffer;
        __block GLint backing_width = 0;
        __block GLint backing_height = 0;

        dispatch_block_t main_work = ^{
            target_layer.opaque = YES;
            target_layer.drawableProperties = @{
                kEAGLDrawablePropertyRetainedBacking: @NO,
                kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
            };

            // EAGLContext is a per-thread "current" pointer. Borrow it for the
            // duration of the main-thread block so renderbufferStorage: binds
            // the storage to *our* colorbuffer; restore nil on the way out so
            // the worker thread can re-make_current and own it afterwards.
            EAGLContext *prev = [EAGLContext currentContext];
            [EAGLContext setCurrentContext:ctx];

            if (colorbuffer == 0) {
                glGenRenderbuffers(1, &colorbuffer);
            }
            glBindRenderbuffer(GL_RENDERBUFFER, colorbuffer);

            if (![ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:target_layer]) {
                LOG_ERROR(DRIVER_GRAPHICS, "EAGL renderbufferStorage:fromDrawable: failed");
                [EAGLContext setCurrentContext:prev];
                layer_ok = false;
                return;
            }

            glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backing_width);
            glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backing_height);

            [EAGLContext setCurrentContext:prev];
        };

        if ([NSThread isMainThread]) {
            main_work();
        } else {
            dispatch_sync(dispatch_get_main_queue(), main_work);
        }

        if (!layer_ok) {
            return false;
        }

        m_colorbuffer = colorbuffer;
        m_backbuffer_width = static_cast<std::uint32_t>(backing_width);
        m_backbuffer_height = static_cast<std::uint32_t>(backing_height);

        // Re-acquire the context on the caller thread for the remaining GL
        // setup and any draw work that follows.
        [EAGLContext setCurrentContext:m_context];

        if (m_framebuffer == 0) {
            glGenFramebuffers(1, &m_framebuffer);
        }
        glBindFramebuffer(GL_FRAMEBUFFER, m_framebuffer);

        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_RENDERBUFFER, m_colorbuffer);

        if (m_depthbuffer == 0) {
            glGenRenderbuffers(1, &m_depthbuffer);
        }
        glBindRenderbuffer(GL_RENDERBUFFER, m_depthbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, backing_width, backing_height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
            GL_RENDERBUFFER, m_depthbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
            GL_RENDERBUFFER, m_depthbuffer);

        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            LOG_ERROR(DRIVER_GRAPHICS, "EAGL framebuffer incomplete (0x{:X})", status);
            return false;
        }
        return true;
    }

    bool gl_context_eagl::attach_metal_layer(CAMetalLayer *layer) {
        if (!m_context || !layer) {
            return false;
        }

        __block CGSize drawable_size = CGSizeZero;
        __block bool layer_ok = true;
        __block id<MTLDevice> device = (__bridge id<MTLDevice>)m_metal_device;
        __block id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)m_metal_queue;
        CAMetalLayer *target_layer = layer;

        dispatch_block_t main_work = ^{
            if (!device) {
                device = MTLCreateSystemDefaultDevice();
            }
            if (!device) {
                layer_ok = false;
                return;
            }
            if (!queue) {
                queue = [device newCommandQueue];
            }
            if (!queue) {
                layer_ok = false;
                return;
            }

            target_layer.device = device;
            target_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            target_layer.framebufferOnly = NO;
            target_layer.opaque = YES;

            drawable_size = target_layer.drawableSize;
            if (drawable_size.width <= 0 || drawable_size.height <= 0) {
                CGFloat scale = target_layer.contentsScale > 0 ? target_layer.contentsScale : 1.0;
                drawable_size = CGSizeMake(target_layer.bounds.size.width * scale,
                    target_layer.bounds.size.height * scale);
                target_layer.drawableSize = drawable_size;
            }
        };

        if ([NSThread isMainThread]) {
            main_work();
        } else {
            dispatch_sync(dispatch_get_main_queue(), main_work);
        }

        if (!layer_ok || drawable_size.width <= 0 || drawable_size.height <= 0) {
            LOG_ERROR(DRIVER_GRAPHICS, "CAMetalLayer setup failed");
            return false;
        }

        if (!m_metal_device) {
            m_metal_device = (__bridge_retained void *)device;
        }
        if (!m_metal_queue) {
            m_metal_queue = (__bridge_retained void *)queue;
        }

        m_layer = layer;
        m_metal_layer = layer;
        m_surface_backend = surface_backend::metal;

        return create_offscreen_buffers(static_cast<std::uint32_t>(drawable_size.width),
            static_cast<std::uint32_t>(drawable_size.height));
    }

    bool gl_context_eagl::create_offscreen_buffers(std::uint32_t width, std::uint32_t height) {
        if (!m_context || width == 0 || height == 0) {
            return false;
        }

        [EAGLContext setCurrentContext:m_context];

        release_renderbuffers();

        if (m_framebuffer == 0) {
            glGenFramebuffers(1, &m_framebuffer);
        }
        glBindFramebuffer(GL_FRAMEBUFFER, m_framebuffer);

        glGenRenderbuffers(1, &m_colorbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, m_colorbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_RENDERBUFFER, m_colorbuffer);

        glGenRenderbuffers(1, &m_depthbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, m_depthbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
            GL_RENDERBUFFER, m_depthbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
            GL_RENDERBUFFER, m_depthbuffer);

        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            LOG_ERROR(DRIVER_GRAPHICS, "iOS offscreen framebuffer incomplete (0x{:X})", status);
            return false;
        }

        m_backbuffer_width = width;
        m_backbuffer_height = height;
        m_readback_rgba.resize(static_cast<std::size_t>(width) * height * 4);
        m_upload_bgra.resize(static_cast<std::size_t>(width) * height * 4);
        return true;
    }

    void gl_context_eagl::present_metal() {
        if (!m_metal_layer || !m_metal_device || !m_metal_queue
            || m_backbuffer_width == 0 || m_backbuffer_height == 0) {
            return;
        }

        [EAGLContext setCurrentContext:m_context];
        glBindFramebuffer(GL_FRAMEBUFFER, m_framebuffer);
        glFinish();
        glReadPixels(0, 0, m_backbuffer_width, m_backbuffer_height, GL_RGBA,
            GL_UNSIGNED_BYTE, m_readback_rgba.data());

        const std::size_t row_bytes = static_cast<std::size_t>(m_backbuffer_width) * 4;
        for (std::uint32_t y = 0; y < m_backbuffer_height; y++) {
            const std::uint8_t *src = m_readback_rgba.data()
                + static_cast<std::size_t>(m_backbuffer_height - 1 - y) * row_bytes;
            std::uint8_t *dst = m_upload_bgra.data() + static_cast<std::size_t>(y) * row_bytes;
            for (std::uint32_t x = 0; x < m_backbuffer_width; x++) {
                dst[x * 4 + 0] = src[x * 4 + 2];
                dst[x * 4 + 1] = src[x * 4 + 1];
                dst[x * 4 + 2] = src[x * 4 + 0];
                dst[x * 4 + 3] = src[x * 4 + 3];
            }
        }

        id<MTLDevice> device = (__bridge id<MTLDevice>)m_metal_device;
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)m_metal_queue;
        id<CAMetalDrawable> drawable = [m_metal_layer nextDrawable];
        if (!drawable) {
            return;
        }

        const std::uint32_t copy_width = std::min<std::uint32_t>(
            m_backbuffer_width, static_cast<std::uint32_t>(drawable.texture.width));
        const std::uint32_t copy_height = std::min<std::uint32_t>(
            m_backbuffer_height, static_cast<std::uint32_t>(drawable.texture.height));
        if (copy_width == 0 || copy_height == 0) {
            return;
        }

        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:m_backbuffer_width
                                                              height:m_backbuffer_height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> upload_texture = [device newTextureWithDescriptor:descriptor];
        if (!upload_texture) {
            return;
        }

        [upload_texture replaceRegion:MTLRegionMake2D(0, 0, m_backbuffer_width, m_backbuffer_height)
                           mipmapLevel:0
                             withBytes:m_upload_bgra.data()
                           bytesPerRow:row_bytes];

        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
        [blit copyFromTexture:upload_texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(copy_width, copy_height, 1)
                    toTexture:drawable.texture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [command_buffer presentDrawable:drawable];
        [command_buffer commit];
    }

    void gl_context_eagl::release_renderbuffers() {
        if (m_colorbuffer != 0) {
            glDeleteRenderbuffers(1, &m_colorbuffer);
            m_colorbuffer = 0;
        }
        if (m_depthbuffer != 0) {
            glDeleteRenderbuffers(1, &m_depthbuffer);
            m_depthbuffer = 0;
        }
    }

    void gl_context_eagl::release_metal_objects() {
        if (m_metal_queue) {
            CFRelease(m_metal_queue);
            m_metal_queue = nullptr;
        }
        if (m_metal_device) {
            CFRelease(m_metal_device);
            m_metal_device = nullptr;
        }
        m_metal_layer = nil;
        m_surface_backend = surface_backend::none;
    }
}
