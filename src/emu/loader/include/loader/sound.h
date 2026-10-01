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

#pragma once

#include <cstdint>
#include <optional>
#include <vector>

namespace eka2l1::common { class ro_stream; }

namespace eka2l1::loader {
    std::optional<std::vector<std::uint8_t>> epoc_record_to_wave(common::ro_stream &stream);
}
