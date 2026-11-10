/*
 * Copyright (c) 2026 EKA2L1 Team.
 * This file is part of EKA2L1, licensed under GPL version 3 or later.
 */

#pragma once

#include <services/window/common.h>
#include <optional>

namespace eka2l1::epoc {
    class key_event_translator {
        std::uint32_t modifiers_ = 0;

    public:
        std::uint32_t modifiers() const {
            return modifiers_;
        }

        static bool is_shift(std::uint32_t scan) {
            return scan == std_key_left_shift || scan == std_key_right_shift;
        }

        static bool is_repeatable(std::uint32_t scan) {
            return !modifier_bit(scan) && scan != std_key_device_0 && scan != std_key_device_1;
        }

        static std::uint32_t modifier_bit(std::uint32_t scan) {
            switch (scan) {
            case std_key_left_shift: return event_modifier_left_shift;
            case std_key_right_shift: return event_modifier_right_shift;
            case std_key_left_ctrl: return event_modifier_left_ctrl;
            case std_key_right_ctrl: return event_modifier_right_ctrl;
            case std_key_left_alt: return event_modifier_left_alt;
            case std_key_right_alt: return event_modifier_right_alt;
            default: return 0;
            }
        }

        // Ctrl editing commands use C0 codes while preserving physical scans.
        // The ASCII profile supplies standard A-Z scan codes.
        std::uint32_t key_code_for_scan(std::uint32_t scan) const {
            auto code = static_cast<std::uint32_t>(map_scancode_to_keycode(static_cast<std_scan_code>(scan)));
            if (code >= 'A' && code <= 'Z') {
                if ((modifiers_ & event_modifier_ctrl) && !(modifiers_ & event_modifier_alt))
                    return code - 'A' + 1;
                if (!(modifiers_ & event_modifier_shift))
                    return code - 'A' + 'a';
            }
            return code;
        }

        std::optional<event> translate(event &raw) {
            const auto scan = static_cast<std_scan_code>(raw.key_evt_.scancode);
            const auto bit = modifier_bit(scan);
            if (bit) {
                if (raw.type == event_code::key_down) {
                    modifiers_ |= bit;
                } else if (raw.type == event_code::key_up) {
                    modifiers_ &= ~bit;
                }
                modifiers_ &= ~(event_modifier_shift | event_modifier_ctrl | event_modifier_alt);
                if (modifiers_ & (event_modifier_left_shift | event_modifier_right_shift))
                    modifiers_ |= event_modifier_shift;
                if (modifiers_ & (event_modifier_left_ctrl | event_modifier_right_ctrl))
                    modifiers_ |= event_modifier_ctrl;
                if (modifiers_ & (event_modifier_left_alt | event_modifier_right_alt))
                    modifiers_ |= event_modifier_alt;
            }

            raw.key_evt_.modifiers = modifiers_;
            // WSERV reports modifier transitions through key up/down, never EEventKey.
            if (bit || raw.type != event_code::key_down) {
                return std::nullopt;
            }

            event key = raw;
            key.type = event_code::key;
            key.key_evt_.code = key_code_for_scan(scan);
            if (is_repeatable(scan)) {
                key.key_evt_.modifiers |= event_modifier_repeatable;
            }
            return key;
        }
    };
}
