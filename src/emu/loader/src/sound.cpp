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

#include <loader/sound.h>
#include <common/buffer.h>
#include <limits>

namespace eka2l1::loader {
    std::optional<std::vector<std::uint8_t>> epoc_record_to_wave(common::ro_stream &stream) {
        auto read_word = [&](std::uint32_t &value) {
            std::uint8_t bytes[4];
            if (stream.read(bytes, sizeof(bytes)) != sizeof(bytes)) {
                return false;
            }
            value = bytes[0] | (std::uint32_t(bytes[1]) << 8)
                | (std::uint32_t(bytes[2]) << 16) | (std::uint32_t(bytes[3]) << 24);
            return true;
        };
        std::uint32_t header[5];
        for (auto &word : header) {
            if (!read_word(word)) {
                return std::nullopt;
            }
        }
        if (header[0] != 0x10000037 || header[1] != 0x1000006d
            || header[2] != 0x1000007e || header[3] != 0x5508accf
            || header[4] < sizeof(header) || header[4] >= stream.size()) {
            return std::nullopt;
        }

        stream.seek(header[4], common::seek_where::beg);
        std::uint8_t first;
        if (stream.read(&first, 1) != 1) {
            return std::nullopt;
        }
        std::uint32_t count = first;
        const int extra_bytes = !(first & 1) ? 0 : ((first & 3) == 1 ? 1 : ((first & 7) == 3 ? 3 : -1));
        if (extra_bytes < 0) {
            return std::nullopt;
        }
        for (int i = 0; i < extra_bytes; ++i) {
            std::uint8_t next;
            if (stream.read(&next, 1) != 1) {
                return std::nullopt;
            }
            count |= std::uint32_t(next) << (8 * (i + 1));
        }
        count >>= extra_bytes == 0 ? 1 : (extra_bytes == 1 ? 2 : 3);
        if (count > stream.left() / 8) {
            return std::nullopt;
        }
        std::uint32_t sample_offset = 0;
        for (std::uint32_t i = 0; i < count; ++i) {
            std::uint32_t uid, offset;
            if (!read_word(uid) || !read_word(offset)) {
                return std::nullopt;
            }
            if (uid == 0x10000052) {
                sample_offset = offset;
            }
        }
        if (sample_offset < sizeof(header) || stream.size() < 20
            || sample_offset > stream.size() - 20) {
            return std::nullopt;
        }
        stream.seek(sample_offset, common::seek_where::beg);
        std::uint32_t sample[5];
        for (auto &word : sample) {
            if (!read_word(word)) {
                return std::nullopt;
            }
        }
        // WVEConv stores compressor UID zero as 8 kHz mono A-law samples.
        if (sample[1] != 0 || sample[0] != sample[4] || sample[4] > stream.left()
            || sample[4] > (std::numeric_limits<std::uint32_t>::max() - 36) / 2) {
            return std::nullopt;
        }

        std::vector<std::uint8_t> samples(sample[4]);
        if (stream.read(samples.data(), samples.size()) != samples.size()) {
            return std::nullopt;
        }

        std::vector<std::uint8_t> wave;
        wave.reserve(44 + samples.size() * 2);
        auto word = [&](std::uint32_t value, int bytes) {
            for (int i = 0; i < bytes; ++i) {
                wave.push_back(static_cast<std::uint8_t>(value >> (i * 8)));
            }
        };
        auto tag = [&](const char *value) {
            wave.insert(wave.end(), value, value + 4);
        };
        tag("RIFF");
        word(36 + sample[4] * 2, 4);
        tag("WAVE");
        tag("fmt ");
        word(16, 4);
        word(1, 2);
        word(1, 2);
        word(8000, 4);
        word(16000, 4);
        word(2, 2);
        word(16, 2);
        tag("data");
        word(sample[4] * 2, 4);
        for (std::uint8_t sample_byte : samples) {
            const std::uint8_t code = sample_byte ^ 0x55;
            const int segment = (code >> 4) & 7;
            int value = (code & 15) << 4;
            value += segment ? 0x108 : 8;
            if (segment > 1) {
                value <<= segment - 1;
            }
            if (!(code & 0x80)) {
                value = -value;
            }
            word(static_cast<std::uint16_t>(value), 2);
        }
        return wave;
    }
}
