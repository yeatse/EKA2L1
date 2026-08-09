/*
 * Copyright (c) 2026 EKA2L1 Team
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include <services/notifier/bluetooth.h>

#include <kernel/kernel.h>
#include <services/bluetooth/btman.h>
#include <services/bluetooth/protocols/btmidman_inet.h>
#include <services/bluetooth/protocols/common.h>

#include <utils/err.h>

#include <array>
#include <cstring>

namespace eka2l1::epoc::notifier {
    namespace {
        constexpr std::size_t bt_device_response_size = 544;
        constexpr std::size_t bt_device_name_offset = 8;
        constexpr std::size_t bt_device_class_offset = 512;
    }

    void bluetooth_device_selection_plugin::handle(epoc::desc8 *, epoc::des8 *response,
        epoc::notify_info &complete_info) {
        if (!response) {
            complete_info.complete(epoc::error_argument);
            return;
        }

        btman_server *btman = kern_->get_by_name<btman_server>(
            get_btman_server_name_by_epocver(kern_->get_epoc_version()));
        if (!btman || !btman->get_midman() || btman->get_midman()->type() != epoc::bt::MIDMAN_INET_BT) {
            complete_info.complete(epoc::error_not_supported);
            return;
        }

        auto *midman = static_cast<epoc::bt::midman_inet *>(btman->get_midman());
        epoc::bt::device_address selected_address{};
        if (!midman->get_friend_device_address(0, selected_address)) {
            complete_info.complete(epoc::error_not_found);
            return;
        }

        std::array<std::uint8_t, bt_device_response_size> result{};
        std::memcpy(result.data(), &selected_address, sizeof(selected_address));

        constexpr std::u16string_view peer_name = u"EKA2L1 peer";
        const std::uint32_t name_info = (static_cast<std::uint32_t>(epoc::buf) << 28)
            | static_cast<std::uint32_t>(peer_name.size());
        const std::uint32_t name_capacity = 248;
        std::memcpy(result.data() + bt_device_name_offset, &name_info, sizeof(name_info));
        std::memcpy(result.data() + bt_device_name_offset + sizeof(name_info), &name_capacity, sizeof(name_capacity));
        std::memcpy(result.data() + bt_device_name_offset + sizeof(name_info) + sizeof(name_capacity),
            peer_name.data(), peer_name.size() * sizeof(char16_t));

        // EKA1's TBTDeviceClass contains only the class value. EKA2 added two
        // reserved words before the validity flags while retaining the 544-byte
        // response package size.
        const std::uint32_t phone_device_class = 0x0200;
        const std::int32_t valid = 1;
        const std::size_t validity_offset = bt_device_class_offset + (kern_->is_eka1() ? 4 : 12);
        std::memcpy(result.data() + bt_device_class_offset, &phone_device_class, sizeof(phone_device_class));
        std::memcpy(result.data() + validity_offset, &valid, sizeof(valid));
        std::memcpy(result.data() + validity_offset + sizeof(valid), &valid, sizeof(valid));
        std::memcpy(result.data() + validity_offset + sizeof(valid) * 2, &valid, sizeof(valid));

        kernel::process *requester = complete_info.requester->owning_process();
        if (response->assign(requester, result.data(), result.size()) != 0) {
            complete_info.complete(epoc::error_overflow);
            return;
        }

        complete_info.complete(epoc::error_none);
    }

    void bluetooth_device_selection_plugin::cancel() {
    }
}
