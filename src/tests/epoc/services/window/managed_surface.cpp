/* Copyright (c) 2026 EKA2L1 Team. GPLv3 or later. */
#include <catch2/catch.hpp>
#include <services/window/managed_surface.h>
#include <utils/err.h>

namespace {
    eka2l1::epoc::managed_surface_attributes attributes() {
        eka2l1::epoc::managed_surface_attributes a;
        a.size = { 3, 2 }; a.buffers = 2;
        a.pixel_format = eka2l1::epoc::MANAGED_SURFACE_ARGB8888_PRE;
        a.stride = 16; a.alignment = 4; a.mappable = 1;
        return a;
    }
}
TEST_CASE("Managed surface cached alignment honors explicit pitch", "[managed_surface]") {
    auto a = attributes(); a.first_offset = 5;
    eka2l1::epoc::managed_surface_storage out;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == 0);
    REQUIRE(out.stride == 16); REQUIRE(out.first_offset == 32);
    REQUIRE(out.buffer_spacing == 32); REQUIRE(out.bytes == 4096);
    a.cache_attrib = 1;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == 0);
    REQUIRE(out.first_offset == 8);
    a.alignment = -1;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == 0);
    REQUIRE(out.first_offset == 4096); REQUIRE(out.buffer_spacing == 4096);
    REQUIRE(out.bytes == 12288);
}
TEST_CASE("Managed surfaces reject invalid pitch alignment and overlap", "[managed_surface]") {
    const auto original = attributes();
    eka2l1::epoc::managed_surface_storage out;
    for (auto stride : { -1, 4, 13 }) {
        auto a = original; a.stride = stride;
        REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_argument);
        REQUIRE(out.bytes == 0);
    }
    for (auto alignment : { -2, 0, 3, 128 }) {
        auto a = original; a.alignment = alignment;
        REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_argument);
    }
    auto a = original; a.buffer_spacing = 31;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_argument);
    a = original; a.size.x = 0;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_argument);
    a = original; a.first_offset = -1;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_argument);
}
TEST_CASE("Managed surfaces reject unsupported hardware and oversized allocations", "[managed_surface]") {
    const auto original = attributes();
    eka2l1::epoc::managed_surface_storage out;
    auto a = original; a.contiguous = 1;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_not_supported);
    a = original; a.hint_count = 1;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_not_supported);
    a = original; a.pixel_format = 0;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_not_supported);
    a = original; a.mappable = 0;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_not_supported);
    a = original; a.buffers = 4;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_not_supported);
    a = original; a.first_offset = INT32_MAX;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_no_memory);
    a = original; a.size = { 4096, 4096 }; a.stride = 16384;
    REQUIRE(eka2l1::epoc::validate_managed_surface(a, out) == eka2l1::epoc::error_no_memory);
    REQUIRE(out.bytes == 0);
}
