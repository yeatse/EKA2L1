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
#
# Requirements: a booted iPhone simulator with EKA2L1 installed and a device
# (e.g. 5320/rm-409) mounted, the apps available, plus `xcodebuildmcp`, `jq` and
# ImageMagick (`magick`) on PATH. It does NOT build — install the app first
# (e.g. `EKA2L1_IOS_CONFIGURATION=Release scripts/build_ios.sh simulator` then
# `xcrun simctl install booted <app>`), or pass --install <app.app>.
#
# Usage:
#   scripts/ios_regression_test.sh                 # run both suites
#   scripts/ios_regression_test.sh fbattle         # FBattle only
#   scripts/ios_regression_test.sh calculator      # Calculator only
#   scripts/ios_regression_test.sh --install <path-to-EKA2L1.app> [suite]
#
# Env overrides:
#   EKA2L1_BUNDLE_ID         default com.eka2l1.emulator
#   EKA2L1_REG_OUTDIR        default /tmp/eka2l1-regression
#   EKA2L1_REG_INGAME_WAIT   FBattle in-game dwell seconds (default 90)

set -uo pipefail

BUNDLE_ID="${EKA2L1_BUNDLE_ID:-com.eka2l1.emulator}"
OUTDIR="${EKA2L1_REG_OUTDIR:-/tmp/eka2l1-regression}"
INGAME_WAIT="${EKA2L1_REG_INGAME_WAIT:-90}"
FBATTLE_UID="0xA0003C62"
CALC_UID="0x10005902"

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

launch_uid() {
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
    wait_s 2
    # -EKA2L1RegressionMode forces the classic keypad layout regardless of the
    # persisted preference, so the soft-key assertions below stay stable no
    # matter which layout the developer last selected (lands in NSArgumentDomain,
    # so it never overwrites the saved value).
    xcrun simctl launch "$SIM" "$BUNDLE_ID" -EKA2L1RegressionMode 1 -LaunchROMCode rm-409 -LaunchAppUID "$1" >/dev/null 2>&1
}

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
    all|"")     test_fbattle; test_calculator ;;
    *) die "unknown suite: $SUITE (use fbattle|calculator|all)" ;;
esac

echo
echo "===== regression summary ====="
printf '%s\n' "${RESULTS[@]}"
echo "------------------------------"
echo "PASS=$PASS FAIL=$FAIL   screenshots in $OUTDIR"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
