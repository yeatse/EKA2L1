if (BUILD_WITH_VULKAN)
    set(DRIVERS_VULKAN_SRC
            include/drivers/graphics/backend/vulkan/graphics_vulkan.h
            src/graphics/backend/vulkan/graphics_vulkan.cpp)
endif ()

# Audio / video / camera backends that rely on external libraries which are
# not (yet) wired up for the iOS stage-0 build. Task 0.5 lists cubeb and
# ffmpeg as deferred dependencies; until they have proper iOS builds the
# backend sources are excluded so the headers are not pulled in.
if (NOT EKA2L1_IOS)
    set(DRIVERS_CUBEB_SRC
            include/drivers/audio/backend/cubeb/audio_cubeb.h
            include/drivers/audio/backend/cubeb/stream_cubeb.h
            src/audio/backend/cubeb/audio_cubeb.cpp
            src/audio/backend/cubeb/stream_cubeb.cpp)

    set(DRIVERS_FFMPEG_SRC
            include/drivers/audio/backend/ffmpeg/dsp_ffmpeg.h
            include/drivers/audio/backend/ffmpeg/player_ffmpeg.h
            include/drivers/video/backend/ffmpeg/video_player_ffmpeg.h
            src/audio/backend/ffmpeg/dsp_ffmpeg.cpp
            src/audio/backend/ffmpeg/player_ffmpeg.cpp
            src/video/backend/ffmpeg/video_player_ffmpeg.cpp)
endif ()

# The OGL graphics backend depends on glad, which is not currently set up for
# iOS. Task 0.3 excludes the whole ogl subdirectory on iOS; phase 2 will bring
# back a GLES-compatible variant (likely via a swapped loader or direct
# <OpenGLES/ES3/gl.h> include).
if (NOT EKA2L1_IOS)
    set(DRIVERS_OGL_SRC
            include/drivers/graphics/backend/ogl/buffer_ogl.h
            include/drivers/graphics/backend/ogl/common_ogl.h
            include/drivers/graphics/backend/ogl/fb_ogl.h
            include/drivers/graphics/backend/ogl/graphics_ogl.h
            include/drivers/graphics/backend/ogl/input_desc_ogl.h
            include/drivers/graphics/backend/ogl/shader_ogl.h
            include/drivers/graphics/backend/ogl/texture_ogl.h
            src/graphics/backend/ogl/buffer_ogl.cpp
            src/graphics/backend/ogl/common_ogl.cpp
            src/graphics/backend/ogl/etcdec.cxx
            src/graphics/backend/ogl/fb_ogl.cpp
            src/graphics/backend/ogl/graphics_ogl.cpp
            src/graphics/backend/ogl/input_desc_ogl.cpp
            src/graphics/backend/ogl/pvrt-dec.cpp
            src/graphics/backend/ogl/texture_ogl.cpp
            src/graphics/backend/ogl/shader_ogl.cpp)
endif ()

add_library(drivers
        include/drivers/itc.h
        include/drivers/driver.h
        include/drivers/audio/audio.h
        include/drivers/audio/dsp.h
        include/drivers/audio/player.h
        include/drivers/audio/stream.h
        include/drivers/audio/backend/minibae/player_minibae.h
        include/drivers/audio/backend/tinysoundfont/player_tsf.h
        include/drivers/audio/backend/dsp_shared.h
        include/drivers/audio/backend/player_shared.h
        include/drivers/camera/camera_collection.h
        include/drivers/hwrm/backend/vibration_null.h
        include/drivers/hwrm/vibration.h
        include/drivers/graphics/buffer.h
        include/drivers/graphics/emu_window.h
        include/drivers/graphics/fb.h
        include/drivers/graphics/context.h
        include/drivers/graphics/graphics.h
        include/drivers/graphics/input_desc.h
        include/drivers/graphics/shader.h
        include/drivers/graphics/texture.h
        include/drivers/graphics/backend/graphics_driver_shared.h
        include/drivers/input/emu_controller.h
        include/drivers/sensor/sensor.h
        include/drivers/video/video.h
        src/driver.cpp
        src/itc.cpp
        src/audio/audio.cpp
        src/audio/dsp.cpp
        src/audio/player.cpp
        src/audio/stream.cpp
        src/audio/backend/minibae/player_minibae.cpp
        src/audio/backend/tinysoundfont/player_tsf.cpp
        src/audio/backend/bae_platimpl.cpp
        src/audio/backend/dsp_shared.cpp
        src/audio/backend/player_shared.cpp
        src/camera/camera_collection.cpp
        src/hwrm/backend/vibration_null.cpp
        src/hwrm/vibration.cpp
        src/input/common.cpp
        src/graphics/buffer.cpp
        src/graphics/context.cpp
        src/graphics/fb.cpp
        src/graphics/graphics.cpp
        src/graphics/input_desc.cpp
        src/graphics/shader.cpp
        src/graphics/texture.cpp
        src/graphics/backend/graphics_driver_shared.cpp
        src/sensor/backend/null/sensor_null.cpp
        src/sensor/sensor.cpp
        src/video/video.cpp
        ${DRIVERS_CUBEB_SRC}
        ${DRIVERS_FFMPEG_SRC}
        ${DRIVERS_OGL_SRC}
        ${DRIVERS_VULKAN_SRC})
if (ANDROID)
    target_sources(drivers PRIVATE
        include/drivers/camera/backend/android/camera_android.h
        include/drivers/camera/backend/android/camera_collection_android.h
        include/drivers/hwrm/backend/vibration_jdk.h
        src/camera/backend/android/camera_android.cpp
        src/camera/backend/android/camera_collection_android.cpp
        src/camera/backend/android/emulator_camera_jni.cpp
        src/camera/backend/android/emulator_camera_jni.h
        src/hwrm/backend/vibration_jdk.cpp
        src/sensor/backend/android/sensor_android.cpp
        src/sensor/backend/android/sensor_android.h)
elseif (EKA2L1_IOS)
    # iOS uses the null sensor/camera/vibration backends already included in
    # the unconditional source block. Input/window handling will be provided
    # by the iOS frontend introduced in task 0.6 (no SDL2, no shared
    # emu_window.cpp). The graphics context is intentionally left to the
    # nullptr fallback in src/graphics/context.cpp until task 2 lands a real
    # CAEAGLLayer-backed implementation.
else()
    target_sources(drivers PRIVATE
        include/drivers/input/backend/emu_controller_sdl2.h
        include/drivers/hwrm/backend/vibration_sdl2.h
        src/graphics/emu_window.cpp
        src/input/backend/emu_controller_sdl2.cpp
        src/input/emu_controller.cpp
        src/hwrm/backend/vibration_sdl2.cpp
        src/sdl2_scoping.cpp
        src/sdl2_scoping.h)
endif()

if(WIN32)
    target_sources(drivers PRIVATE
        include/drivers/audio/backend/wmf/player_wmf.h
        include/drivers/audio/backend/wmf/wmf_loader.h
        src/audio/backend/wmf/wmf_loader.cpp
        src/audio/backend/wmf/player_wmf.cpp
        src/graphics/backend/context_wgl.cpp
        src/graphics/backend/context_wgl.h
    )

    target_link_libraries(drivers PRIVATE opengl32.lib Mfuuid.lib Propsys.lib)
elseif (EKA2L1_IOS)
    # No GL context backend wired up yet; context::make_gl_context() falls
    # through to its nullptr branch on iOS until task 2.
elseif(APPLE)
    target_sources(drivers PRIVATE
        src/graphics/backend/context_agl.h
        src/graphics/backend/context_agl.mm
    )
elseif(HAIKU)
    target_sources(drivers PRIVATE
        src/graphics/backend/context_bgl.cpp
        src/graphics/backend/context_bgl.h
    )
elseif(ANDROID)
    target_sources(drivers PRIVATE
        src/graphics/backend/context_egl.cpp
        src/graphics/backend/context_egl.h
        src/graphics/backend/context_egl_android.cpp
        src/graphics/backend/context_egl_android.h
    )
else()
    find_package(X11 REQUIRED)
    find_package(OpenGL REQUIRED)
    find_package(Wayland REQUIRED EGL)

    target_sources(drivers PRIVATE
        src/graphics/backend/context_glx.cpp
        src/graphics/backend/context_glx.h
        src/graphics/backend/context_egl.cpp
        src/graphics/backend/context_egl.h
        src/graphics/backend/context_wayland.cpp
        src/graphics/backend/context_wayland.h
    )

    # GLX has a hard dependency on libGL.
    # Make sure to link to it if using GLX.
    target_link_libraries(drivers PUBLIC ${OPENGL_LIBRARIES} ${X11_LIBRARIES} ${WAYLAND_LIBRARIES} EGL)
endif()

# Make miniBAE build alone so that its include directories don't messed up system headers
add_library(miniBAE_EMU STATIC ${MINIBAE_SHARED_SOURCES})
target_include_directories(miniBAE_EMU
    PRIVATE include/drivers/audio/backend/minibae ${MINIBAE_INTERNAL_INCLUDE_DIRS})
target_link_libraries(miniBAE_EMU PRIVATE common)

target_link_libraries(drivers PRIVATE common glm miniBAE_EMU)
if (EKA2L1_IOS)
    # glad / SDL2 are not linked on iOS; the ogl backend is excluded entirely
    # in the source list above and the graphics factories below short-circuit
    # via EKA2L1_PLATFORM(IOS). cubeb and ffmpeg link is gated by task 0.5.
else()
    target_link_libraries(drivers PRIVATE cubeb ffmpeg glad)
endif()
if (ANDROID)
    target_link_libraries(drivers PRIVATE android)
elseif (NOT EKA2L1_IOS)
    target_link_libraries(drivers PRIVATE SDL2)
endif()

target_include_directories(drivers PUBLIC include ${MINIBAE_PUBLIC_INCLUDE_DIRS} ${TSF_INCLUDE})

if (BUILD_WITH_VULKAN)
    target_link_libraries(drivers PRIVATE Vulkan)
endif ()
