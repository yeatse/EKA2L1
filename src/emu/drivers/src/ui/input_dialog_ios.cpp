// Copyright (c) 2026 EKA2L1 Team.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Stub UI dialog implementations for iOS. Real UIAlertController-backed
// implementations land in stage 3 alongside the document picker and the
// settings panel; until then the EPOC dispatch layer's ehui_* calls are
// satisfied by no-ops so the static-link graph closes.

#include <drivers/ui/input_dialog.h>

namespace eka2l1::drivers::ui {
    bool open_input_view(const std::u16string & /*initial_text*/, const int /*max_len*/,
        input_dialog_complete_callback /*complete_callback*/) {
        return false;
    }

    void close_input_view() {}

    void show_yes_no_dialog(const std::u16string & /*text*/, const std::u16string & /*button1_text*/,
        const std::u16string & /*button2_text*/, yes_no_dialog_complete_callback /*complete_callback*/) {}
}
