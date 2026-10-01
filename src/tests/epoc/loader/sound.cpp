/*
 * Copyright (c) 2026 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include <catch2/catch.hpp>
#include <common/buffer.h>
#include <loader/sound.h>

namespace {
    std::vector<std::uint8_t> record_sound() {
        std::vector<std::uint8_t> data;
        auto word = [&](std::uint32_t value) {
            for (int i = 0; i < 4; ++i) data.push_back(static_cast<std::uint8_t>(value >> (i * 8)));
        };
        for (std::uint32_t value : {0x10000037U, 0x1000006dU, 0x1000007eU, 0x5508accfU, 20U}) word(value);
        data.push_back(4);
        word(0x10000052); word(52);
        word(0x10000089); word(37);
        data.resize(52);
        for (auto value : {4U, 0U, 0U, 0U, 4U}) word(value);
        data.insert(data.end(), {0xd5, 0x55, 0xd5, 0x55});
        return data;
    }
}

TEST_CASE("EPOC Record A-law samples become an 8 kHz mono wave", "sound") {
    // Official WVEConv writes a stream dictionary and a five-word sample header.
    auto data = record_sound();
    SECTION("two-byte cardinality") {
        data[20] = 9;
        data.insert(data.begin() + 21, 0);
        data.erase(data.begin() + 38);
    }
    SECTION("four-byte cardinality") {
        data[20] = 19;
        data.insert(data.begin() + 21, 3, 0);
        data.erase(data.begin() + 40, data.begin() + 43);
    }
    eka2l1::common::ro_buf_stream stream(data.data(), data.size());
    auto wave = eka2l1::loader::epoc_record_to_wave(stream);
    REQUIRE(wave.has_value());
    REQUIRE(wave->size() == 52);
    REQUIRE(std::string(wave->begin(), wave->begin() + 4) == "RIFF");
    REQUIRE((*wave)[20] == 1);
    REQUIRE((*wave)[22] == 1);
    REQUIRE((*wave)[24] == 0x40);
    REQUIRE((*wave)[25] == 0x1f);
    REQUIRE(std::vector<std::uint8_t>(wave->begin() + 44, wave->end())
        == std::vector<std::uint8_t>{8, 0, 0xf8, 0xff, 8, 0, 0xf8, 0xff});
}

TEST_CASE("EPOC Record rejects invalid offsets lengths and compression", "sound") {
    auto data = record_sound();
    SECTION("invalid cardinality prefix") { data[20] = 7; }
    SECTION("truncated cardinality") { data.resize(21); data[20] = 3; }
    SECTION("wrong UID") { data[8] = 0; }
    SECTION("root outside file") { data[16] = 0xff; }
    SECTION("sample outside file") { data[25] = 0xff; }
    SECTION("unknown compressor") { data[56] = 1; }
    SECTION("inconsistent sample length") { data[52] = 5; }
    SECTION("truncated payload") { data.pop_back(); }
    SECTION("missing dictionary") { data[20] = 0; }
    SECTION("truncated header") { data.resize(12); }
    eka2l1::common::ro_buf_stream stream(data.data(), data.size());
    REQUIRE_FALSE(eka2l1::loader::epoc_record_to_wave(stream));
}
