/*
 * Copyright (c) 2026 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <catch2/catch.hpp>
#include <services/remcon/common.h>

TEST_CASE("RemCon v2 session version distinguishes target and controller", "[remcon]") {
    using namespace eka2l1::epoc::remcon;
    // RRemConTarget/Controller::Version put the role in the TVersion build field.
    REQUIRE(session_client_type(2, 2) == client_type_target);
    REQUIRE(session_client_type(2, 1) == client_type_controller);
    REQUIRE(session_client_type(2, 0) == client_type_undefined);
    REQUIRE(session_client_type(2, 3) == client_type_undefined);
    REQUIRE(session_client_type(1, 2) == client_type_undefined);
    REQUIRE(session_client_type(3, 2) == client_type_undefined);
}
