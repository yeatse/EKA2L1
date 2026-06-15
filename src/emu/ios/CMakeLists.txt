# EKA2L1 iOS frontend
#
# Builds the SwiftUI shell plus the Obj-C++ bridge (IosEmulator / CpuSmoke)
# that drives the emu core on iOS: device install/boot, applist scan + launch,
# EAGL rendering, input, audio and vibration. Mirrors the Android JNI bridge
# under src/emu/android/app/src/main/cpp.
#
# The expected invocation is:
#   cmake -S . -B build/ios -G Xcode \
#       -DCMAKE_TOOLCHAIN_FILE=cmake/ios.toolchain.cmake \
#       -DPLATFORM=OS64
#
# Or with PLATFORM=SIMULATORARM64 for the simulator.

# Swift is not a language in the top-level project() declaration, so enable
# it here before declaring the bundle target. The Xcode generator + leetal
# ios.toolchain understand Swift natively.
enable_language(Swift)

set(EKA2L1_IOS_APP EKA2L1)
set(EKA2L1_IOS_BUNDLE_ID "com.eka2l1.emulator" CACHE STRING "iOS bundle identifier")

# Apple Development team for real-device installs. Leave empty for the
# unsigned stage-0 build (simulator / "build graph compiles" CI). Set it to a
# team id (e.g. via -DEKA2L1_IOS_DEVELOPMENT_TEAM=XXXXXXXXXX or the
# EKA2L1_IOS_DEVELOPMENT_TEAM env passed through build_ios.sh) to flip the
# target into automatic code signing so the .app can be sideloaded onto a
# physical iPhone. dyncom-only means no JIT entitlement is needed, so a plain
# Apple Development signature is enough.
set(EKA2L1_IOS_DEVELOPMENT_TEAM "" CACHE STRING "Apple Development team id for device signing")

set(EKA2L1_IOS_RESOURCES_DIR "${CMAKE_CURRENT_SOURCE_DIR}/Resources")
set(EKA2L1_IOS_APP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/App")
set(EKA2L1_IOS_BRIDGE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/Bridge")

set(EKA2L1_IOS_SOURCES
    "${EKA2L1_IOS_APP_DIR}/EKA2L1App.swift"
    "${EKA2L1_IOS_APP_DIR}/ContentView.swift"
    "${EKA2L1_IOS_APP_DIR}/EKA2L1Bridge.swift"
    "${EKA2L1_IOS_APP_DIR}/ImportStrings.swift"
    "${EKA2L1_IOS_APP_DIR}/EmulatorView.swift"
    "${EKA2L1_IOS_APP_DIR}/EmulatorViewController.swift"
    "${EKA2L1_IOS_APP_DIR}/ImportRouter.swift"
    "${EKA2L1_IOS_APP_DIR}/SettingsView.swift"
    "${EKA2L1_IOS_BRIDGE_DIR}/CpuSmokeBlob.h"
    "${EKA2L1_IOS_BRIDGE_DIR}/CpuSmokeBridge.h"
    "${EKA2L1_IOS_BRIDGE_DIR}/CpuSmokeBridge.mm"
    "${EKA2L1_IOS_BRIDGE_DIR}/IosEmulator.h"
    "${EKA2L1_IOS_BRIDGE_DIR}/IosEmulator.mm"
    "${EKA2L1_IOS_BRIDGE_DIR}/EKA2L1-Bridging-Header.h"
    "${EKA2L1_IOS_RESOURCES_DIR}/Info.plist"
    "${EKA2L1_IOS_RESOURCES_DIR}/EKA2L1.entitlements"
)

add_executable(${EKA2L1_IOS_APP} MACOSX_BUNDLE ${EKA2L1_IOS_SOURCES})

# Bundle the GLES shader sources into the .app under "shaders/". The ogl
# driver loads these at runtime (see ogl_graphics_driver::do_init), and
# IosEmulator.mm stages them from NSBundle.resourcePath/shaders into the
# sandbox's data/resources. The __FILE__-relative fallback in that staging
# only resolves on the simulator (which runs on the build host); on a real
# device the bundle copy is the only source, so a missing copy here means a
# null shader FILE* and a crash.
#
# NB: the bundle subfolder must NOT be named "resources" — the build host's
# filesystem is case-insensitive, so "resources" collides with the reserved
# "Resources" bundle directory and codesign rejects the .app with "bundle
# format unrecognized, invalid, or unsuitable".
file(GLOB EKA2L1_IOS_SHADER_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/../drivers/resources/gles/*")
target_sources(${EKA2L1_IOS_APP} PRIVATE ${EKA2L1_IOS_SHADER_FILES})
set_source_files_properties(${EKA2L1_IOS_SHADER_FILES} PROPERTIES
    MACOSX_PACKAGE_LOCATION "shaders")

# Bundle the prebuilt HLE patch DLLs + .map files into the .app under "patch/".
# lib_manager::load_patch_libraries (epoc.cpp) scans data/patch at boot to apply
# ROM/library patches (audio via mediaclientaudiostream, the scdv screen driver,
# etc.). IosEmulator.mm stages them from NSBundle.resourcePath/patch into the
# sandbox's data/patch. As with the shaders above, the __FILE__-relative source
# fallback only resolves on the simulator (which runs on the build host); on a
# real device the bundle copy is the only source. A missing copy here leaves the
# guest unpatched — no sound, and apps that hit an unpatched path (e.g. Snakes
# falling back to d_display.ldd) panic the active scheduler and black-screen.
# Names are flat and unique, so MACOSX_PACKAGE_LOCATION "patch" stages them
# alongside each other, matching the layout load_patch_libraries expects.
file(GLOB EKA2L1_IOS_PATCH_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/../../patch/*/group/*.map"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../patch/*/group/*_general.dll")
target_sources(${EKA2L1_IOS_APP} PRIVATE ${EKA2L1_IOS_PATCH_FILES})
set_source_files_properties(${EKA2L1_IOS_PATCH_FILES} PROPERTIES
    MACOSX_PACKAGE_LOCATION "patch")

target_include_directories(${EKA2L1_IOS_APP} PRIVATE "${EKA2L1_IOS_BRIDGE_DIR}")
target_compile_definitions(${EKA2L1_IOS_APP} PRIVATE GLES_SILENCE_DEPRECATION)

# Link the emu static libraries the bridge depends on. We mirror the Android
# JNI bridge link line (see src/emu/android/app/src/main/cpp/CMakeLists.txt)
# because that target is known-good for a non-Qt frontend.
target_link_libraries(${EKA2L1_IOS_APP} PRIVATE
    common
    cpu
    drivers
    epoc
    epockern
    epocloader
    epocpkg
    epocservs
    lunasvg
    sqlite3
    yaml-cpp)

# --- MetalANGLE (GLES -> Metal) opt-in backend --------------------------------
# Off by default: the app keeps the EAGL GLES path. When ON (option lives in the
# root CMakeLists so the drivers lib sees it too) we link + embed the vendored
# MetalANGLE.xcframework. See docs/ios_metal_angle_plan.md.
if (EKA2L1_IOS_USE_ANGLE)
    set(EKA2L1_METALANGLE_XCFRAMEWORK
        "${CMAKE_SOURCE_DIR}/src/external/metalangle/MetalANGLE.xcframework")
    message(STATUS "EKA2L1 iOS: MetalANGLE enabled (${EKA2L1_METALANGLE_XCFRAMEWORK})")
    target_compile_definitions(${EKA2L1_IOS_APP} PRIVATE EKA2L1_IOS_ANGLE=1)
    target_link_libraries(${EKA2L1_IOS_APP} PRIVATE "${EKA2L1_METALANGLE_XCFRAMEWORK}")
    set_target_properties(${EKA2L1_IOS_APP} PROPERTIES
        XCODE_EMBED_FRAMEWORKS "${EKA2L1_METALANGLE_XCFRAMEWORK}"
        XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY "YES"
        # The framework is embedded in <app>/Frameworks; make dyld look there
        # (the default rpath only covers the Swift runtime paths).
        XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "$(inherited) @executable_path/Frameworks")
endif()

set_target_properties(${EKA2L1_IOS_APP} PROPERTIES
    BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${EKA2L1_IOS_RESOURCES_DIR}/Info.plist"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${EKA2L1_IOS_BUNDLE_ID}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
    XCODE_ATTRIBUTE_SWIFT_VERSION "6.0"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${EKA2L1_IOS_BRIDGE_DIR}/EKA2L1-Bridging-Header.h"
    # Xcode 26's swift driver rejects the bare -stdlib=libc++ that CMake's
    # Xcode generator otherwise pushes into OTHER_SWIFT_FLAGS for mixed
    # Swift/C++ targets. Explicitly reset OTHER_SWIFT_FLAGS to the inherited
    # defaults so the unsupported flag is not appended. Swift only talks to
    # the Obj-C++ bridge through plain Obj-C, so C++ interop on the Swift
    # side stays disabled.
    XCODE_ATTRIBUTE_SWIFT_OBJC_INTEROP_MODE "objc"
    XCODE_ATTRIBUTE_OTHER_SWIFT_FLAGS "$(inherited) -Xcc -DGLES_SILENCE_DEPRECATION"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "${EKA2L1_IOS_DEPLOYMENT_TARGET}"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${EKA2L1_IOS_RESOURCES_DIR}/EKA2L1.entitlements"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO")

if (EKA2L1_IOS_DEVELOPMENT_TEAM STREQUAL "")
    # Stage-0 builds are unsigned. Developers can flip these by passing
    # -DEKA2L1_IOS_DEVELOPMENT_TEAM=<team> (see above) or by opening the
    # generated Xcode project and selecting a team.
    set_target_properties(${EKA2L1_IOS_APP} PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO")
    message(STATUS "EKA2L1 iOS: unsigned build (no development team set)")
else()
    # Real-device install path: automatic signing against the given team.
    # Xcode registers the bundle id / device UDID and provisions on demand
    # (xcodebuild needs -allowProvisioningUpdates; see scripts/build_ios.sh).
    set_target_properties(${EKA2L1_IOS_APP} PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${EKA2L1_IOS_DEVELOPMENT_TEAM}"
        XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "Apple Development"
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "YES"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES")
    message(STATUS "EKA2L1 iOS: signed build for team ${EKA2L1_IOS_DEVELOPMENT_TEAM}")
endif()

message(STATUS "EKA2L1 iOS frontend skeleton: bundle ${EKA2L1_IOS_BUNDLE_ID}, deployment ${EKA2L1_IOS_DEPLOYMENT_TARGET}")
