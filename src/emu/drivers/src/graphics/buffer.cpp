#include <common/platform.h>
#include <drivers/graphics/buffer.h>
#include <drivers/graphics/graphics.h>

#if !EKA2L1_PLATFORM(IOS)
#include <drivers/graphics/backend/ogl/buffer_ogl.h>
#endif

namespace eka2l1::drivers {
    std::unique_ptr<buffer> make_buffer(graphics_driver *driver) {
        switch (driver->get_current_api()) {
#if !EKA2L1_PLATFORM(IOS)
        case graphic_api::opengl: {
            return std::make_unique<ogl_buffer>();
        }
#endif

        default:
            break;
        }

        return nullptr;
    }
}