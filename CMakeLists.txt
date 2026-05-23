cmake_minimum_required(VERSION 3.8)

project (EKA2L1)

# Clang 14 is required to compile nicely with C++ 20
set (CMAKE_CXX_STANDARD 20)

# iOS detection. When building with cmake/ios.toolchain.cmake, CMAKE_SYSTEM_NAME
# is set to "iOS" before project() runs, so this flag reflects that.
if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(EKA2L1_IOS ON)
else()
    set(EKA2L1_IOS OFF)
endif()

set(EKA2L1_IOS_DEPLOYMENT_TARGET "18.0" CACHE STRING "Minimum iOS version to target")

option(EKA2L1_BUILD_TOOLS "Build EKA2L1's tool" ON)
option(EKA2L1_BUILD_TESTS "Build EKA2L1's tests" ON)
option(EKA2L1_ENABLE_SCRIPTING_ABILITY "Enable to script with Python or Lua" ON)
option(EKA2L1_ENABLE_UNEXPECTED_EXCEPTION_HANDLER "Enable EKA2L1 to dump unexpected exception" OFF)
option(EKA2L1_BUILD_VULKAN_BACKEND "Build Vulkan backend" OFF)
option(EKA2L1_DEPLOY_DMG "Deploy EKA2L1 as .dmg" OFF)
option(EKA2L1_BUILD_PATCH "Enable building Symbian's DLL patches using Symbian SDK" OFF)
option(EKA2L1_ENABLE_DISCORD_RICH_PRESENCE "Enable support for Discord Rich Presence" OFF)

# Stage-0 iOS build: force-off options that the iOS port does not yet support.
# These are silently overridden so a user passing -DEKA2L1_BUILD_TESTS=ON for
# another platform does not have to special-case iOS in their scripts.
if (EKA2L1_IOS)
    set(EKA2L1_IOS_SIMULATOR OFF)
    if (CMAKE_OSX_SYSROOT MATCHES "[Ii][Pp]honeSimulator")
        set(EKA2L1_IOS_SIMULATOR ON)
    endif()
    option(EKA2L1_IOS_SIMULATOR_DYNARMIC "Enable Dynarmic for iOS simulator builds" ${EKA2L1_IOS_SIMULATOR})
    if (EKA2L1_IOS_SIMULATOR_DYNARMIC)
        add_compile_definitions(EKA2L1_IOS_SIMULATOR_DYNARMIC=1)
        add_compile_definitions(_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION=1)
        message(STATUS "iOS simulator build: Dynarmic backend enabled")
    endif()

    set(EKA2L1_BUILD_TOOLS OFF CACHE BOOL "Disabled on iOS" FORCE)
    set(EKA2L1_BUILD_TESTS OFF CACHE BOOL "Disabled on iOS" FORCE)
    set(EKA2L1_ENABLE_SCRIPTING_ABILITY OFF CACHE BOOL "Disabled on iOS" FORCE)
    set(EKA2L1_BUILD_VULKAN_BACKEND OFF CACHE BOOL "Disabled on iOS" FORCE)
    set(EKA2L1_BUILD_PATCH OFF CACHE BOOL "Disabled on iOS" FORCE)
    set(EKA2L1_DEPLOY_DMG OFF CACHE BOOL "Disabled on iOS" FORCE)
    set(EKA2L1_ENABLE_DISCORD_RICH_PRESENCE OFF CACHE BOOL "Disabled on iOS" FORCE)
    message(STATUS "iOS build: tools/tests/scripting/vulkan/patch/dmg/discord forced OFF")
endif()

set (CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
set (ROOT ${CMAKE_CURRENT_SOURCE_DIR})

find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")

    message("Using CCache for building")
endif()

if (MSVC)
    add_definitions(-D_CRT_SECURE_NO_DEPRECATE)
    add_definitions(-D_CRT_NONSTDC_NO_DEPRECATE)
    add_definitions(-D_DISABLE_VECTOR_ANNOTATION)
endif(MSVC)

if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    # Limit to C-family languages so that swiftc (enabled for the iOS target)
    # does not reject the clang-only flag.
    add_compile_options($<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-Wno-error>)
endif()

if (EKA2L1_BUILD_VULKAN_BACKEND)
    set (BUILD_WITH_VULKAN 1)
else()
    set (BUILD_WITH_VULKAN 0)
endif()

if (EKA2L1_ENABLE_SCRIPTING_ABILITY)
    set (ENABLE_SCRIPTING 1)
else()
    set (ENABLE_SCRIPTING 0)
endif(EKA2L1_ENABLE_SCRIPTING_ABILITY)

if (CI)
    set (BUILD_FOR_USER 1)
endif (CI)

set (ENABLE_SEH_HANDLER 0)

if (EKA2L1_ENABLE_UNEXPECTED_EXCEPTION_HANDLER)
    set(ENABLE_SEH_HANDLER 1)
endif (EKA2L1_ENABLE_UNEXPECTED_EXCEPTION_HANDLER)

if (EKA2L1_ENABLE_DISCORD_RICH_PRESENCE AND NOT ANDROID AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "GNU"))
    set(ENABLE_DISCORD_RICH_PRESENCE 1)
else()
    set(ENABLE_DISCORD_RICH_PRESENCE 0)
endif()

add_subdirectory(src/patch)
add_subdirectory(src/external)
add_subdirectory(src/emu)

if (EKA2L1_BUILD_TOOLS)
    add_subdirectory(src/tools)
endif()

if (EKA2L1_BUILD_TESTS)
    enable_testing()
    add_subdirectory(src/tests)
endif()
