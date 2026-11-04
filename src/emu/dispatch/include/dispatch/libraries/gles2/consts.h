#pragma once

#include <dispatch/libraries/gles_shared/consts.h>

namespace eka2l1::dispatch {
    enum {
        // Survey shows most provide 16. But use the minimum here, as the hardware probably can't provide
        // more at the time (PowerVR GPU) (for both these one wrote here)
        GLES2_EMU_MAX_VERTEX_ATTRIBS_COUNT = 8,
        GLES2_EMU_MAX_TEXTURE_UNIT_COUNT = 8
    };

    enum {
        GL_MAX_VERTEX_UNIFORM_VECTORS_EMU = 0x8DFB,
        GL_MAX_VARYING_VECTORS_EMU = 0x8DFC,
        GL_MAX_FRAGMENT_UNIFORM_VECTORS_EMU = 0x8DFD,
        GL_MAX_RENDERBUFFER_SIZE_EMU = 0x84E8,
        GL_CURRENT_PROGRAM_EMU = 0x8B8D,
        GL_SHADER_COMPILER_EMU = 0x8DFA,
        GL_LOW_FLOAT_EMU = 0x8DF0,
        GL_MEDIUM_FLOAT_EMU = 0x8DF1,
        GL_HIGH_FLOAT_EMU = 0x8DF2,
        GL_LOW_INT_EMU = 0x8DF3,
        GL_MEDIUM_INT_EMU = 0x8DF4,
        GL_HIGH_INT_EMU = 0x8DF5,
        GL_VERTEX_ATTRIB_ARRAY_ENABLED_EMU = 0x8622,
        GL_VERTEX_ATTRIB_ARRAY_SIZE_EMU = 0x8623,
        GL_VERTEX_ATTRIB_ARRAY_STRIDE_EMU = 0x8624,
        GL_VERTEX_ATTRIB_ARRAY_TYPE_EMU = 0x8625,
        GL_CURRENT_VERTEX_ATTRIB_EMU = 0x8626,
        GL_VERTEX_ATTRIB_ARRAY_NORMALIZED_EMU = 0x886A,
        GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING_EMU = 0x889F,
        GL_VERTEX_ATTRIB_ARRAY_POINTER_EMU = 0x8645,
        GL_RENDERBUFFER_WIDTH_EMU = 0x8D42,
        GL_RENDERBUFFER_HEIGHT_EMU = 0x8D43,
        GL_RENDERBUFFER_INTERNAL_FORMAT_EMU = 0x8D44,
        GL_RENDERBUFFER_RED_SIZE_EMU = 0x8D50,
        GL_RENDERBUFFER_GREEN_SIZE_EMU = 0x8D51,
        GL_RENDERBUFFER_BLUE_SIZE_EMU = 0x8D52,
        GL_RENDERBUFFER_ALPHA_SIZE_EMU = 0x8D53,
        GL_RENDERBUFFER_DEPTH_SIZE_EMU = 0x8D54,
        GL_RENDERBUFFER_STENCIL_SIZE_EMU = 0x8D55,
        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE_EMU = 0x8CD0,
        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME_EMU = 0x8CD1,
        GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL_EMU = 0x8CD2,
        GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE_EMU = 0x8CD3
    };
    
    static constexpr const char *GLES2_STATIC_STRING_VENDOR = "IMAGINATION TECHNOLOGIES EKA2L1";
    static constexpr const char *GLES2_STATIC_STRING_RENDERER = "POWERVR EKA2L1";
    static constexpr const char *GLES2_STATIC_STRING_VERSION = "OpenGL ES 2.0 POWERVR (EKA2L1 IMPLEMENTATION)";
    static constexpr const char *GLES2_STATIC_STRING_EXTENSIONS = "GL_IMG_texture_compression_pvrtc "
        "GL_OES_compressed_ETC1_RGB8_texture "
        "GL_OES_compressed_paletted_texture "
        "GL_EXT_texture_format_BGRA8888 "
        "GL_OES_vertex_buffer_object "
        "GL_EXT_texture_lod_bias "
        "GL_OES_framebuffer_object "
        "GL_OES_packed_depth_stencil "
        "GL_OES_texture_npot "
        "GL_EXT_shader_texture_lod "
        "GL_IMG_texture_format_BGRA8888 ";
        /*
         * "GL_EXT_texture_compression_s3tc "
         */
    static constexpr const char *GLES2_STATIC_STRING_SHADER_LANGUAGE_VERSION = "OpenGL ES GLSL ES 1.00";
}
