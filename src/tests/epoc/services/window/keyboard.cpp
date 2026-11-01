/*
 * Copyright (c) 2026 EKA2L1 Team.
 * This file is part of EKA2L1, licensed under GPL version 3 or later.
 */

#include <catch2/catch.hpp>
#include <services/window/keyboard.h>

using namespace eka2l1::epoc;

static event raw_key(std_scan_code scan, bool pressed) {
    event result{};
    result.type = pressed ? event_code::key_down : event_code::key_up;
    result.key_evt_ = {0, scan, 0, 0};
    return result;
}

// CKeyTranslatorX::TranslateKey suppresses modifier keypresses; WSERV queues
// key up/down after updating its stored modifier state (ky_tran.cpp, EVENT.CPP).
TEST_CASE("Edit key transitions carry Shift without generating character or repeat events", "[window][keyboard]") {
    key_event_translator translator;
    auto down = raw_key(std_key_left_shift, true);
    REQUIRE_FALSE(translator.translate(down));
    REQUIRE(down.key_evt_.code == 0);
    REQUIRE(down.key_evt_.modifiers == (event_modifier_left_shift | event_modifier_shift));
    REQUIRE_FALSE(translator.is_repeatable(std_key_left_shift));

    auto up = raw_key(std_key_left_shift, false);
    REQUIRE_FALSE(translator.translate(up));
    REQUIRE(up.key_evt_.modifiers == 0);
    REQUIRE(translator.modifiers() == 0);
}

TEST_CASE("Edit key modifies navigation and softkeys until released", "[window][keyboard]") {
    key_event_translator translator;
    auto edit = raw_key(std_key_left_shift, true);
    translator.translate(edit);

    auto right = raw_key(std_key_right_arrow, true);
    auto key = translator.translate(right);
    REQUIRE(key);
    REQUIRE(key->type == event_code::key);
    REQUIRE(key->key_evt_.code == key_right_arrow);
    REQUIRE(key->key_evt_.modifiers == (event_modifier_shift | event_modifier_left_shift | event_modifier_repeatable));
    REQUIRE(right.key_evt_.modifiers == (event_modifier_shift | event_modifier_left_shift));

    auto soft = raw_key(std_key_device_0, true);
    auto soft_key = translator.translate(soft);
    REQUIRE(soft_key);
    REQUIRE(soft_key->key_evt_.modifiers == (event_modifier_shift | event_modifier_left_shift));

    edit.type = event_code::key_up;
    translator.translate(edit);
    // Repeats sample the current stored state, not the original keydown's flags.
    REQUIRE(translator.modifiers() == 0);
    right.type = event_code::key_up;
    REQUIRE_FALSE(translator.translate(right));
    REQUIRE(right.key_evt_.modifiers == 0);
    right.type = event_code::key_down;
    REQUIRE(translator.translate(right)->key_evt_.modifiers == event_modifier_repeatable);
}

TEST_CASE("Releasing either Shift preserves the other held Shift", "[window][keyboard]") {
    key_event_translator translator;
    auto left = raw_key(std_key_left_shift, true);
    auto right = raw_key(std_key_right_shift, true);
    translator.translate(left);
    translator.translate(right);
    REQUIRE(translator.modifiers() == (event_modifier_left_shift | event_modifier_right_shift | event_modifier_shift));
    translator.translate(left);
    left.type = event_code::key_up;
    translator.translate(left);
    REQUIRE(left.key_evt_.modifiers == (event_modifier_right_shift | event_modifier_shift));
    REQUIRE_FALSE(translator.is_repeatable(std_key_right_shift));
    right.type = event_code::key_up;
    translator.translate(right);
    REQUIRE(right.key_evt_.modifiers == 0);
}

TEST_CASE("Control and Alt transitions are modifiers rather than repeatable characters", "[window][keyboard]") {
    for (auto scan : {std_key_left_ctrl, std_key_right_ctrl, std_key_left_alt, std_key_right_alt}) {
        key_event_translator translator;
        auto down = raw_key(scan, true);
        REQUIRE_FALSE(translator.translate(down));
        REQUIRE_FALSE(translator.is_repeatable(scan));
        REQUIRE(down.key_evt_.code == 0);
        REQUIRE(translator.modifiers() & key_event_translator::modifier_bit(scan));
        REQUIRE(translator.modifiers() & (scan == std_key_left_ctrl || scan == std_key_right_ctrl ? event_modifier_ctrl : event_modifier_alt));
        auto up = raw_key(scan, false);
        REQUIRE_FALSE(translator.translate(up));
        REQUIRE(up.key_evt_.modifiers == 0);
    }
}

TEST_CASE("Control and Alt aggregates retain the other held side", "[window][keyboard]") {
    for (auto pair : {std::pair{std_key_left_ctrl, std_key_right_ctrl}, std::pair{std_key_left_alt, std_key_right_alt}}) {
        key_event_translator translator;
        auto left = raw_key(pair.first, true), right = raw_key(pair.second, true);
        translator.translate(left); translator.translate(right);
        left.type = event_code::key_up;
        translator.translate(left);
        const auto aggregate = pair.first == std_key_left_ctrl ? event_modifier_ctrl : event_modifier_alt;
        REQUIRE(translator.modifiers() == (key_event_translator::modifier_bit(pair.second) | aggregate));
        right.type = event_code::key_up;
        translator.translate(right);
        REQUIRE(translator.modifiers() == 0);
    }
}

TEST_CASE("ASCII profile generates control letters without rewriting special scans", "[window][keyboard]") {
    key_event_translator translator;
    auto ctrl = raw_key(std_key_left_ctrl, true); translator.translate(ctrl);
    for (std::uint32_t scan = 'A'; scan <= 'Z'; ++scan) {
        auto down = raw_key(static_cast<std_scan_code>(scan), true);
        auto key = translator.translate(down);
        REQUIRE(key);
        REQUIRE(key->key_evt_.scancode == scan);
        REQUIRE(key->key_evt_.code == scan - 'A' + 1);
        REQUIRE(key->key_evt_.modifiers == (event_modifier_ctrl | event_modifier_left_ctrl | event_modifier_repeatable));
        REQUIRE(down.key_evt_.code == 0);
        auto up = raw_key(static_cast<std_scan_code>(scan), false);
        REQUIRE_FALSE(translator.translate(up));
    }
    for (auto scan : {std_key_backspace, std_key_tab, std_key_enter, std_key_right_arrow, std_key_device_0}) {
        auto down = raw_key(scan, true);
        auto key = translator.translate(down);
        REQUIRE(key);
        REQUIRE(key->key_evt_.scancode == scan);
        REQUIRE(key->key_evt_.code == static_cast<std::uint32_t>(map_scancode_to_keycode(scan)));
    }
}

TEST_CASE("ASCII letters follow Shift while control and repeats sample current modifiers", "[window][keyboard]") {
    key_event_translator translator;
    REQUIRE(translator.key_code_for_scan('V') == 'v');
    auto shift = raw_key(std_key_right_shift, true); translator.translate(shift);
    REQUIRE(translator.key_code_for_scan('V') == 'V');
    auto ctrl = raw_key(std_key_right_ctrl, true); translator.translate(ctrl);
    REQUIRE(translator.key_code_for_scan('V') == 22);
    // Same held letter/scan, but repeat delivery must follow the current state.
    ctrl.type = event_code::key_up; translator.translate(ctrl);
    REQUIRE(translator.key_code_for_scan('V') == 'V');
    shift.type = event_code::key_up; translator.translate(shift);
    REQUIRE(translator.key_code_for_scan('V') == 'v');
    auto alt = raw_key(std_key_left_alt, true); translator.translate(alt);
    ctrl.type = event_code::key_down; translator.translate(ctrl);
    // Ctrl+Alt is not a C0 shortcut or a pretend AltGr layout conversion.
    REQUIRE(translator.key_code_for_scan('V') == 'v');
    REQUIRE(translator.modifiers() == (event_modifier_left_alt | event_modifier_alt | event_modifier_right_ctrl | event_modifier_ctrl));
}
