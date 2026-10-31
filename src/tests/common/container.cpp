// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later
#include <catch2/catch.hpp>
#include <common/container.h>

TEST_CASE("identity_container_iteration_visits_only_live_entries", "common") {
    eka2l1::common::identity_container<int> container;
    std::vector<int> values;
    for (int value : container) {
        values.push_back(value);
    }
    REQUIRE(values.empty());

    int first = 10, second = 20, third = 30;
    const auto first_id = container.add(first);
    const auto second_id = container.add(second);
    const auto third_id = container.add(third);

    SECTION("leading and middle holes") {
        REQUIRE(container.remove(first_id));
        REQUIRE(container.remove(second_id));
        for (int value : container) {
            values.push_back(value);
        }
        REQUIRE(values == std::vector<int>{ 30 });
    }
    SECTION("all entries removed") {
        REQUIRE(container.remove(first_id));
        REQUIRE(container.remove(second_id));
        REQUIRE(container.remove(third_id));
        for (int value : container) {
            values.push_back(value);
        }
        REQUIRE(values.empty());
    }
    SECTION("a removed leading entry is reused") {
        REQUIRE(container.remove(first_id));
        int replacement = 40;
        REQUIRE(container.add(replacement) == first_id);
        for (int value : container) {
            values.push_back(value);
        }
        REQUIRE(values == std::vector<int>{ 40, 20, 30 });
    }
}
