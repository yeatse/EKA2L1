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

#pragma once

#include <services/notifier/plugin.h>

namespace eka2l1::epoc::notifier {
    class bluetooth_device_selection_plugin : public plugin_base {
    public:
        explicit bluetooth_device_selection_plugin(kernel_system *kern)
            : plugin_base(kern) {
        }

        epoc::uid unique_id() const override {
            return 0x100069D1;
        }

        void handle(epoc::desc8 *request, epoc::des8 *response, epoc::notify_info &complete_info) override;
        void cancel() override;
    };
}
