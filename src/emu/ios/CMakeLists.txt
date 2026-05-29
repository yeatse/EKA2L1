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
    # Stage-0 builds are unsigned. Developers can flip these via -D overrides
    # or by opening the generated Xcode project and selecting a team.
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO")

message(STATUS "EKA2L1 iOS frontend skeleton: bundle ${EKA2L1_IOS_BUNDLE_ID}, deployment ${EKA2L1_IOS_DEPLOYMENT_TARGET}")
