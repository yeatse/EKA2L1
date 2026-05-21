#include <common/platform.h>
#include <drivers/graphics/buffer.h>
#include <drivers/graphics/graphics.h>

#include <drivers/graphics/backend/ogl/buffer_ogl.h>

namespace eka2l1::drivers {
    std::unique_ptr<buffer> make_buffer(graphics_driver *driver) {
        switch (driver->get_current_api()) {
        case graphic_api::opengl: {
            return std::make_unique<ogl_buffer>();
        }

        default:
            break;
        }

        return nullptr;
    }
}
