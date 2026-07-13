#!/usr/bin/env bash
#
# iOS regression validation (xcodebuildmcp CLI based).
#
# Drives the booted iPhone simulator through two known guest apps and asserts
# they still behave, so unrelated emulator changes can be regression-checked
# quickly. Screenshots for every checked state are saved under the results dir
# for human review; the script also makes hard programmatic assertions and
# exits non-zero if any fail.
#
#   Final Battle (0xA0003C62) : reaches real in-game play and does NOT hit the
#                               E32USER-CBase 46 stray-signal panic.
#   Calculator   (0x10005902) : renders its default UI, accepts number input,
#                               left soft key opens the Options menu, right soft
#                               key closes it.
#   Angry Birds  (0x20030E51) : Symbian^3 touch-guest suite (opt-in, not part
#                               of `all`): boots the X7 (rm-707), taps the
#                               loading screen once (used to wedge all input
#                               permanently), then asserts the main-menu PLAY
#                               tap and the episode-carousel swipe still
#                               respond. Guards the raw-touch pointer path
#                               (UITouch -> guest pointer-slot mapping).
#   Asphalt 6    (0x2003B2CC) : Symbian^3/Belle compatibility suite (opt-in,
#                               not part of `all`): boots X7, reaches the main
#                               menu, selects Free Race / Nassau / Normal Race,
#                               chooses the Mini, and asserts a rendered race.
#
# Requirements: a booted iPhone simulator with EKA2L1 installed and a device
# (e.g. 5320/rm-409) mounted, the apps available, plus `xcodebuildmcp`, `jq` and
# ImageMagick (`magick`) on PATH. The angrybirds and asphalt6 suites additionally
# need the X7 (rm-707), their respective game installed, and the `axe` HID tool
# (bundled inside xcodebuildmcp; auto-located). It does NOT build.
#
# Regression MUST run against a Release build. Note `build_ios.sh` defaults to
# Debug (artifacts land in Debug-iphonesimulator) — build Release explicitly
# and install that app, or pass it via --install:
#
#   EKA2L1_IOS_CONFIGURATION=Release scripts/build_ios.sh simulator
#   scripts/ios_regression_test.sh --install \
#       build/ios-simulator/src/emu/ios/Release-iphonesimulator/EKA2L1.app
#
# Usage:
#   scripts/ios_regression_test.sh                 # fbattle + calculator
#   scripts/ios_regression_test.sh fbattle         # FBattle only
#   scripts/ios_regression_test.sh calculator      # Calculator only
#   scripts/ios_regression_test.sh angrybirds      # X7 touch suite only
#   scripts/ios_regression_test.sh asphalt6        # X7 Asphalt 6 race suite
#   scripts/ios_regression_test.sh --install <path-to-EKA2L1.app> [suite]
#
# Env overrides:
#   EKA2L1_BUNDLE_ID         default com.eka2l1.emulator
#   EKA2L1_REG_OUTDIR        default /tmp/eka2l1-regression
#   EKA2L1_REG_INGAME_WAIT   FBattle in-game dwell seconds (default 90)
#   EKA2L1_REG_AB_ROM        Angry Birds device firmware code (default rm-707)
#   EKA2L1_REG_AB_TIMEOUT    Angry Birds boot->splash / splash->menu budget
#                            seconds, each phase (default 180)
#   EKA2L1_REG_A6_ROM        Asphalt 6 device firmware code (default rm-707)
#   EKA2L1_REG_A6_TIMEOUT    Asphalt 6 boot and menu-transition budget
#                            seconds, each phase (default 240)

set -uo pipefail

BUNDLE_ID="${EKA2L1_BUNDLE_ID:-com.eka2l1.emulator}"
OUTDIR="${EKA2L1_REG_OUTDIR:-/tmp/eka2l1-regression}"
INGAME_WAIT="${EKA2L1_REG_INGAME_WAIT:-90}"
FBATTLE_UID="0xA0003C62"
CALC_UID="0x10005902"
AB_UID="0x20030E51"
A6_UID="0x2003B2CC"
AB_ROM="${EKA2L1_REG_AB_ROM:-rm-707}"
AB_TIMEOUT="${EKA2L1_REG_AB_TIMEOUT:-180}"
# Full-screen transitions (splash -> menu -> episode select) repaint most of the
# guest band; idle animations (clouds, sun rays, LOADING pulse) don't come
# close. Used instead of SCREEN_DIFF_MIN for the Angry Birds assertions.
AB_DIFF_MIN="${EKA2L1_REG_AB_DIFF_MIN:-150000}"
A6_ROM="${EKA2L1_REG_A6_ROM:-rm-707}"
A6_TIMEOUT="${EKA2L1_REG_A6_TIMEOUT:-240}"
A6_DIFF_MIN="${EKA2L1_REG_A6_DIFF_MIN:-80000}"

# Pixels that must differ for a screen to count as "changed" (ignores the small
# clock / FPS-counter noise between captures).
SCREEN_DIFF_MIN="${EKA2L1_REG_SCREEN_DIFF_MIN:-4000}"
# Grayscale stdev (0..1) below which a screenshot counts as blank.
BLANK_STDEV_MAX="0.04"

CRASH_REGEX='Active scheduler dump|E32USER-CBase|panicked|access violation|Emulation halt|KERN-EXEC|Unhandled'

PASS=0; FAIL=0
declare -a RESULTS

INSTALL_APP=""
if [ "${1:-}" = "--install" ]; then
    INSTALL_APP="${2:-}"; shift 2
fi
SUITE="${1:-all}"

# ---- helpers ---------------------------------------------------------------

die() { echo "FATAL: $*" >&2; exit 2; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

booted_sim() {
    xcrun simctl list devices booted 2>/dev/null \
        | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p' | head -1
}

log_path() {
    local data; data="$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data 2>/dev/null)"
    [ -n "$data" ] && echo "$data/Documents/data/EKA2L1.log"
}

wait_s() { local e=$((SECONDS+$1)); until [ $SECONDS -ge $e ]; do sleep 1; done; }

# snapshot-ui; caches JSON to $SNAP. Also nudges the renderer to present a fresh
# frame (the guest screen often lags behind a tap by a few seconds).
SNAP="$OUTDIR/.snapshot.json"
snapshot() {
    xcodebuildmcp simulator snapshot-ui --simulator-id "$SIM" --output json 2>/dev/null >"$SNAP" || true
}

# ref_for "<exact label>"  OR  ref_for "<prefix>" prefix
ref_for() {
    local want="$1" mode="${2:-exact}"
    jq -r '.data.capture.targets[]' "$SNAP" 2>/dev/null | awk -F'|' -v w="$want" -v m="$mode" '
        { lbl=$4 }
        m=="exact"  && lbl==w        { print $1; exit }
        m=="prefix" && index(lbl,w)==1 { print $1; exit }'
}

tap_ref() {
    local ref="$1" i r
    [ -z "$ref" ] && return 1
    for i in 1 2 3 4 5 6; do
        r="$(xcodebuildmcp ui-automation tap --simulator-id "$SIM" --element-ref "$ref" --output json 2>/dev/null \
             | grep -o '"status": "[A-Z]*"' | head -1)"
        echo "$r" | grep -q SUCCEEDED && return 0
        sleep 1
    done
    return 1
}

# tap_label "<label>" [exact|prefix] : resolve from a fresh snapshot, then tap.
tap_label() {
    snapshot
    local ref; ref="$(ref_for "$1" "${2:-exact}")"
    [ -z "$ref" ] && { echo "    ! no element for label '$1'" >&2; return 1; }
    tap_ref "$ref"
}

shot() {
    local name="$1"
    local path="$OUTDIR/$name.png"
    snapshot                 # force a fresh frame before capturing
    wait_s 2
    xcrun simctl io "$SIM" screenshot "$path" >/dev/null 2>&1
    echo "$path"
}

# launch_uid <uid> [rom] [keypad-layout]
# Default (no layout): -EKA2L1RegressionMode forces the classic keypad layout
# regardless of the persisted preference, so soft-key assertions stay stable no
# matter which layout the developer last selected (lands in NSArgumentDomain,
# so it never overwrites the saved value). With an explicit layout, RegressionMode
# must NOT be passed — it pins classic and overrides -LaunchKeypadLayout.
launch_uid() {
    local uid="$1" rom="${2:-rm-409}" layout="${3:-}"
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
    wait_s 2
    local args=(-LaunchROMCode "$rom" -LaunchAppUID "$uid")
    if [ -n "$layout" ]; then
        args+=(-LaunchKeypadLayout "$layout")
    else
        args+=(-EKA2L1RegressionMode 1)
    fi
    xcrun simctl launch "$SIM" "$BUNDLE_ID" "${args[@]}" >/dev/null 2>&1
}

# ---- coordinate touch (axe) -------------------------------------------------
# Touch guests (fullscreen layout) expose no accessibility elements for the
# guest screen, so ui-automation elementRef taps can't reach them. Drive them
# with the AXe HID tool that ships inside xcodebuildmcp.

AXE=""
find_axe() {
    AXE="$(command -v axe 2>/dev/null || true)"
    [ -n "$AXE" ] && return 0
    AXE="$(ls -t /opt/homebrew/Cellar/xcodebuildmcp/*/libexec/bundled/axe 2>/dev/null | head -1)"
    [ -n "$AXE" ] && return 0
    AXE="$(ls -t "$HOME"/.npm/_npx/*/node_modules/xcodebuildmcp/bundled/axe 2>/dev/null | head -1)"
    [ -n "$AXE" ]
}

# Window size in points -> SCR_W / SCR_H (guest coords are derived from it).
screen_size() {
    local frame
    frame="$("$AXE" describe-ui --udid "$SIM" 2>/dev/null | jq -r '.[0].frame | "\(.width) \(.height)"' 2>/dev/null)"
    SCR_W="${frame%% *}"; SCR_H="${frame##* }"
    [ -n "$SCR_W" ] && [ "$SCR_W" != null ] && [ "${SCR_W%.*}" -gt 0 ] 2>/dev/null
}

tap_xy()   { "$AXE" tap -x "$1" -y "$2" --udid "$SIM" >/dev/null 2>&1; }
touch_xy() { "$AXE" touch -x "$1" -y "$2" --down --up --delay 0.08 --udid "$SIM" >/dev/null 2>&1; }
double_touch_xy() { touch_xy "$1" "$2" && touch_xy "$1" "$2"; }
swipe_xy() { "$AXE" swipe --start-x "$1" --start-y "$2" --end-x "$3" --end-y "$4" --duration "${5:-0.5}" --udid "$SIM" >/dev/null 2>&1; }
pt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.0f", a*b}'; }

# differing-pixel count between two screenshots (AE can be printed in scientific
# notation for large diffs, so coerce to a plain integer).
screen_diff_px() {
    magick compare -metric AE "$1" "$2" null: 2>&1 | awk 'NR==1{printf "%.0f", $1+0; exit} END{if(NR==0)print 0}'
}
screens_differ() { [ "$(screen_diff_px "$1" "$2")" -ge "$SCREEN_DIFF_MIN" ]; }

is_blank() {
    local sd; sd="$(magick "$1" -colorspace Gray -format "%[fx:standard_deviation]" info: 2>/dev/null)"
    awk -v s="${sd:-0}" -v m="$BLANK_STDEV_MAX" 'BEGIN{exit !(s<m)}'
}

# crash check over log lines added since a recorded baseline
log_baseline() { wc -l < "$LOG" 2>/dev/null | tr -d ' '; }
assert_no_crash() {
    local base="$1" stage="$2" hit
    hit="$(tail -n "+$((base+1))" "$LOG" 2>/dev/null | grep -niE "$CRASH_REGEX" | head -3)"
    if [ -n "$hit" ]; then
        check FAIL "$stage: no guest crash"
        echo "$hit" | sed 's/^/      /'
    else
        check PASS "$stage: no guest crash"
    fi
}

check() { # check PASS|FAIL "<desc>"
    if [ "$1" = PASS ]; then PASS=$((PASS+1)); RESULTS+=("  PASS  $2"); echo "  [PASS] $2"
    else FAIL=$((FAIL+1)); RESULTS+=("  FAIL  $2"); echo "  [FAIL] $2"; fi
}

# ---- suites ----------------------------------------------------------------

test_fbattle() {
    echo "== Final Battle ($FBATTLE_UID) =="
    launch_uid "$FBATTLE_UID"
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    wait_s 8
    local base; base="$(log_baseline)"
    local s_lang; s_lang="$(shot fbattle_1_language)"
    is_blank "$s_lang" && check FAIL "FBattle: language screen rendered" \
                       || check PASS "FBattle: language screen rendered"

    snapshot                                  # warm up (first tap after launch is flaky)
    tap_label "1"                || check FAIL "FBattle: select language"
    wait_s 6
    tap_label "OK"               || check FAIL "FBattle: Start Game (OK)"
    wait_s 8
    tap_label "OK"               || check FAIL "FBattle: confirm intro (OK)"
    echo "    in-game dwell ${INGAME_WAIT}s (the crash used to fire ~60s in)..."
    wait_s "$INGAME_WAIT"

    # Force a few fresh frames; rendering can lag the guest by tens of seconds.
    local s_game i
    for i in 1 2 3; do s_game="$(shot fbattle_2_ingame)"; screens_differ "$s_lang" "$s_game" && break; wait_s 8; done
    screens_differ "$s_lang" "$s_game" \
        && check PASS "FBattle: advanced past language menu into game" \
        || check FAIL "FBattle: advanced past language menu into game"

    assert_no_crash "$base" "FBattle"
}

test_calculator() {
    echo "== Calculator ($CALC_UID) =="
    launch_uid "$CALC_UID"
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    wait_s 18
    local base; base="$(log_baseline)"

    # 1) default render
    local s_default; s_default="$(shot calc_1_default)"
    is_blank "$s_default" && check FAIL "Calculator: default UI rendered (non-blank)" \
                          || check PASS "Calculator: default UI rendered (non-blank)"

    # 2) number input -> display changes
    snapshot
    tap_label "1"           || check FAIL "Calculator: key 1"
    tap_label "2, ABC"      || tap_label "2" prefix || check FAIL "Calculator: key 2"
    tap_label "3, DEF"      || tap_label "3" prefix || check FAIL "Calculator: key 3"
    wait_s 3
    local s_input; s_input="$(shot calc_2_input)"
    screens_differ "$s_default" "$s_input" \
        && check PASS "Calculator: number input changes display" \
        || check FAIL "Calculator: number input changes display"

    # 3) left soft key opens the Options menu
    tap_label "LSK"         || check FAIL "Calculator: press LSK"
    wait_s 4
    local s_menu; s_menu="$(shot calc_3_menu_open)"
    screens_differ "$s_input" "$s_menu" \
        && check PASS "Calculator: LSK opens Options menu" \
        || check FAIL "Calculator: LSK opens Options menu"

    # 4) right soft key closes it
    tap_label "RSK"         || check FAIL "Calculator: press RSK"
    wait_s 4
    local s_closed; s_closed="$(shot calc_4_menu_closed)"
    screens_differ "$s_menu" "$s_closed" \
        && check PASS "Calculator: RSK closes Options menu" \
        || check FAIL "Calculator: RSK closes Options menu"

    assert_no_crash "$base" "Calculator"
}

test_angrybirds() {
    echo "== Angry Birds ($AB_UID on $AB_ROM) =="
    if ! find_axe; then
        check FAIL "AngryBirds: axe HID tool located"
        return
    fi

    launch_uid "$AB_UID" "$AB_ROM" fullscreen
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    local base; base="$(log_baseline)"

    # 1) Wait for the first rendered guest frame (the Rovio splash). Until the
    # guest presents, the emulator screen is solid black; the SwiftUI app list
    # flashes for <5s at launch which the initial dwell skips past.
    wait_s 10
    local s_splash="" deadline=$((SECONDS+AB_TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        s_splash="$(shot ab_1_splash)"
        is_blank "$s_splash" || break
        wait_s 5
    done
    if is_blank "$s_splash"; then
        check FAIL "AngryBirds: splash rendered (boot)"
        assert_no_crash "$base" "AngryBirds"
        return
    fi
    check PASS "AngryBirds: splash rendered (boot)"

    screen_size || { check FAIL "AngryBirds: read screen geometry"; return; }

    # 2) Tap the loading screen once. This is the regression trigger: the
    # UITouch identity from this tap must not poison the guest pointer slots
    # (pre-fix it permanently killed all later gestures on Symbian^3 guests).
    tap_xy "$(pt "$SCR_W" 0.5)" "$(pt "$SCR_H" 0.5)"
    echo "    tapped the loading screen; waiting for the main menu..."

    # 3) Wait for the main menu: a full-band repaint relative to the splash.
    local s_menu="" diff=0
    deadline=$((SECONDS+AB_TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        wait_s 8
        s_menu="$(shot ab_2_menu)"
        is_blank "$s_menu" && continue
        diff="$(screen_diff_px "$s_splash" "$s_menu")"
        [ "$diff" -ge "$AB_DIFF_MIN" ] && break
    done
    if [ "$diff" -lt "$AB_DIFF_MIN" ]; then
        check FAIL "AngryBirds: reached main menu"
        assert_no_crash "$base" "AngryBirds"
        return
    fi
    check PASS "AngryBirds: reached main menu"
    wait_s 5

    # 4) PLAY sits at the centre of the letterboxed guest band (= screen
    # centre). It must respond even though the loading screen was tapped.
    s_menu="$(shot ab_2_menu)"
    tap_xy "$(pt "$SCR_W" 0.5)" "$(pt "$SCR_H" 0.5)"
    wait_s 6
    local s_episodes; s_episodes="$(shot ab_3_episodes)"
    if [ "$(screen_diff_px "$s_menu" "$s_episodes")" -ge "$AB_DIFF_MIN" ]; then
        check PASS "AngryBirds: PLAY tap opens episode select (touch alive after loading tap)"
    else
        check FAIL "AngryBirds: PLAY tap opens episode select (touch alive after loading tap)"
    fi

    # 5) Swipe the episode carousel (drag path: down -> moves -> up).
    local y; y="$(pt "$SCR_H" 0.54)"
    swipe_xy "$(pt "$SCR_W" 0.8)" "$y" "$(pt "$SCR_W" 0.2)" "$y" 0.5
    wait_s 4
    local s_swiped; s_swiped="$(shot ab_4_swiped)"
    if [ "$(screen_diff_px "$s_episodes" "$s_swiped")" -ge "$AB_DIFF_MIN" ]; then
        check PASS "AngryBirds: carousel swipe scrolls episodes (drag responds)"
    else
        check FAIL "AngryBirds: carousel swipe scrolls episodes (drag responds)"
    fi

    assert_no_crash "$base" "AngryBirds"
}

test_asphalt6() {
    echo "== Asphalt 6 ($A6_UID on $A6_ROM) =="
    if ! find_axe; then
        check FAIL "Asphalt6: axe HID tool located"
        return
    fi

    launch_uid "$A6_UID" "$A6_ROM" fullscreen
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    local base; base="$(log_baseline)"

    # Asphalt performs a long native-resource initialization before presenting
    # the Gameloft splash. Ignore the brief SwiftUI/app-list frame at launch.
    wait_s 12
    local s_splash="" deadline=$((SECONDS+A6_TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        s_splash="$(shot a6_1_splash)"
        is_blank "$s_splash" || break
        wait_s 6
    done
    if is_blank "$s_splash"; then
        check FAIL "Asphalt6: splash rendered"
        assert_no_crash "$base" "Asphalt6"
        return
    fi
    check PASS "Asphalt6: splash rendered"

    screen_size || { check FAIL "Asphalt6: read screen geometry"; return; }
    local cx cy
    cx="$(pt "$SCR_W" 0.50)"; cy="$(pt "$SCR_H" 0.50)"

    # The first non-blank frame can precede "Touch to continue". Give the
    # intro enough time to settle, then use a physical down/up event.
    wait_s 35
    touch_xy "$cx" "$cy"

    local s_menu="" diff=0
    deadline=$((SECONDS+A6_TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        wait_s 8
        s_menu="$(shot a6_2_menu)"
        is_blank "$s_menu" && continue
        diff="$(screen_diff_px "$s_splash" "$s_menu")"
        [ "$diff" -ge "$A6_DIFF_MIN" ] && break
        touch_xy "$cx" "$cy"
    done
    if [ "$diff" -lt "$A6_DIFF_MIN" ]; then
        check FAIL "Asphalt6: reached main menu"
        assert_no_crash "$base" "Asphalt6"
        return
    fi
    check PASS "Asphalt6: reached main menu"

    # Main menu: Free Race is the second item in the right-hand list.
    touch_xy "$(pt "$SCR_W" 0.85)" "$(pt "$SCR_H" 0.42)"
    wait_s 10
    local s_track; s_track="$(shot a6_3_track)"
    if [ "$(screen_diff_px "$s_menu" "$s_track")" -ge "$A6_DIFF_MIN" ]; then
        check PASS "Asphalt6: Free Race opens track select"
    else
        check FAIL "Asphalt6: Free Race opens track select"
    fi

    # Selected carousel cards use a two-tap confirmation gesture.
    double_touch_xy "$(pt "$SCR_W" 0.48)" "$(pt "$SCR_H" 0.53)"
    wait_s 12
    local s_mode; s_mode="$(shot a6_4_mode)"
    if [ "$(screen_diff_px "$s_track" "$s_mode")" -ge "$A6_DIFF_MIN" ]; then
        check PASS "Asphalt6: Nassau opens race-mode select"
    else
        check FAIL "Asphalt6: Nassau opens race-mode select"
    fi

    double_touch_xy "$(pt "$SCR_W" 0.30)" "$(pt "$SCR_H" 0.46)"
    wait_s 15
    local s_car; s_car="$(shot a6_5_car)"
    if [ "$(screen_diff_px "$s_mode" "$s_car")" -ge "$A6_DIFF_MIN" ]; then
        check PASS "Asphalt6: Normal Race opens car select"
    else
        check FAIL "Asphalt6: Normal Race opens car select"
    fi

    # RACE and the following two confirmation arrows share the bottom-right
    # location. Each uses the same selected-control double-tap behavior.
    local next_x next_y
    next_x="$(pt "$SCR_W" 0.91)"; next_y="$(pt "$SCR_H" 0.60)"
    double_touch_xy "$next_x" "$next_y"
    wait_s 25
    local s_preview; s_preview="$(shot a6_6_preview)"
    double_touch_xy "$next_x" "$next_y"
    wait_s 10
    double_touch_xy "$(pt "$SCR_W" 0.93)" "$next_y"
    wait_s 25
    local s_race; s_race="$(shot a6_7_race)"

    if ! is_blank "$s_race" && [ "$(screen_diff_px "$s_preview" "$s_race")" -ge "$A6_DIFF_MIN" ]; then
        check PASS "Asphalt6: Nassau race renders in-game"
    else
        check FAIL "Asphalt6: Nassau race renders in-game"
    fi

    assert_no_crash "$base" "Asphalt6"
}

# ---- main ------------------------------------------------------------------

need xcodebuildmcp; need jq; need magick; need xcrun
SIM="$(booted_sim)"; [ -z "$SIM" ] && die "no booted iPhone simulator"
mkdir -p "$OUTDIR"
echo "simulator: $SIM"
echo "results:   $OUTDIR"

if [ -n "$INSTALL_APP" ]; then
    [ -d "$INSTALL_APP" ] || die "app not found: $INSTALL_APP"
    echo "installing $INSTALL_APP"
    xcrun simctl install "$SIM" "$INSTALL_APP" || die "install failed"
fi

case "$SUITE" in
    fbattle)    test_fbattle ;;
    calculator|calc) test_calculator ;;
    angrybirds|ab) test_angrybirds ;;
    asphalt6|asphalt|a6) test_asphalt6 ;;
    all|"")     test_fbattle; test_calculator ;;
    *) die "unknown suite: $SUITE (use fbattle|calculator|angrybirds|asphalt6|all)" ;;
esac

echo
echo "===== regression summary ====="
printf '%s\n' "${RESULTS[@]}"
echo "------------------------------"
echo "PASS=$PASS FAIL=$FAIL   screenshots in $OUTDIR"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
