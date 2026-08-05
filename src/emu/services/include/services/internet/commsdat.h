/*
 * Copyright (c) 2026 EKA2L1 Team
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
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#pragma once

#include <cstdint>

namespace eka2l1 {
    struct central_repo;
}

namespace eka2l1::epoc::internet {
    /// Central repository holding CommsDat from Symbian OS 9.1 onwards.
    static constexpr std::uint32_t COMMSDAT_REPO_UID = 0xCCCCCC00;

    /**
     * \brief Make sure the emulated phone owns at least one internet access point.
     *
     * A retail ROM ships CommsDat with bearer and service templates only: the access points
     * themselves are provisioned later, either by the operator (over-the-air settings) or by
     * the user. The emulator has no such step, so every guest that asks "which IAP should I
     * connect through" gets an empty list and refuses to go online, long before it ever
     * reaches the socket server.
     *
     * This adds a packet-data access point wired to whatever bearer/network/location records
     * the ROM already provides, which is what a provisioned handset looks like. Sockets are
     * bridged to the host by the socket server, so the access point only has to exist and be
     * well-formed - none of its dial-up specific settings are ever acted upon.
     *
     * Does nothing unless the repository is CommsDat and its IAP table is still empty.
     */
    void provision_default_access_point(central_repo &repo);
}
