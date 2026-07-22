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
#   N95 Calc     (0x10005902) : boots Calculator on the N95 (rm-320) and asserts
#                               the HOST process survives boot and the UI
#                               renders. Guards the patch-DLL inflate tail-word
#                               overread that nondeterministically corrupted the
#                               host heap on this device.
#   Angry Birds  (0x20030E51) : Symbian^3 touch-guest suite (opt-in, not part
#                               of `all`): boots the X7 (rm-707), taps the
#                               loading screen once (used to wedge all input
#                               permanently), then asserts the main-menu PLAY
#                               tap and the episode-carousel swipe still
#                               respond. Guards the raw-touch pointer path
#                               (UITouch -> guest pointer-slot mapping).
#   Asphalt 6    (0x2003B2CC) : Symbian^3/Belle compatibility suite (opt-in,
#                               not part of `all`): boots X7, asserts the early
#                               Gameloft movie renders, reaches the main menu,
#                               selects Free Race / Nassau / Normal Race,
#                               chooses the Mini, and asserts a rendered race.
#   strings      (no sim)     : reconciles the Localizable string catalog with
#                               the build's .stringsdata. FAILs on new/stale
#                               entries (an agent must fix them); a pure
#                               formatting drift is rewritten and `git add`ed.
#
# Requirements: a booted iPhone simulator with EKA2L1 installed and a device
# (e.g. 5320/rm-409) mounted, the apps available, plus `xcodebuildmcp`, `jq` and
# ImageMagick (`magick`) on PATH. The n95calc suite (part of `all`) additionally
# needs the N95 (rm-320) mounted. The angrybirds and asphalt6 suites additionally
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
#   scripts/ios_regression_test.sh                 # fbattle + calculator + n95calc + strings
#   scripts/ios_regression_test.sh fbattle         # FBattle only
#   scripts/ios_regression_test.sh calculator      # Calculator only
#   scripts/ios_regression_test.sh n95calc         # N95 boot/host-survival only
#   scripts/ios_regression_test.sh angrybirds      # X7 touch suite only
#   scripts/ios_regression_test.sh asphalt6        # X7 Asphalt 6 race suite
#   scripts/ios_regression_test.sh strings         # string catalog sync check (no simulator)
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
#   EKA2L1_REG_A6_INTRO_TIMEOUT
#                            budget to observe a Gameloft movie frame (default 20)
#   EKA2L1_REG_A6_MOVIE_WAIT earliest seconds after launch at which the stable
#                            interactive title is accepted (default 75)
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
A6_INTRO_TIMEOUT="${EKA2L1_REG_A6_INTRO_TIMEOUT:-20}"
A6_MOVIE_WAIT="${EKA2L1_REG_A6_MOVIE_WAIT:-75}"
A6_TIMEOUT="${EKA2L1_REG_A6_TIMEOUT:-240}"
A6_INTRO_STDEV_MAX="${EKA2L1_REG_A6_INTRO_STDEV_MAX:-0.24}"
# Normalized RMSE for a real Asphalt page transition. The main-menu showroom
# animation stays well below this even though ImageMagick's HDRI `AE` metric
# reports a large value, which previously made every later assertion pass.
A6_RMSE_MIN="${EKA2L1_REG_A6_RMSE_MIN:-0.10}"
# The interactive title fills and brightens the guest band. The preceding
# Gameloft/Asphalt movies remain sparse, so do not accept them merely because
# the fixed minimum movie time elapsed.
A6_TITLE_STDEV_MIN="${EKA2L1_REG_A6_TITLE_STDEV_MIN:-0.13}"
A6_TITLE_MEAN_MIN="${EKA2L1_REG_A6_TITLE_MEAN_MIN:-0.65}"

# Pixels that must differ for a screen to count as "changed" (ignores the small
# clock / FPS-counter noise between captures).
SCREEN_DIFF_MIN="${EKA2L1_REG_SCREEN_DIFF_MIN:-4000}"
# Grayscale stdev (0..1) below which a screenshot counts as blank.
BLANK_STDEV_MAX="0.04"

CRASH_REGEX='Active scheduler dump|E32USER-CBase|panicked|access violation|Emulation halt|KERN-EXEC|Unhandled'

# Repo root + string catalog, for the `strings` suite (static, no simulator).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCSTRINGS="${EKA2L1_XCSTRINGS:-$REPO_ROOT/src/emu/ios/Resources/Localizable.xcstrings}"

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

# Normalized root-mean-square difference (0..1). Unlike AE in HDRI builds this
# is comparable across machines and does not turn small animated regions into
# a false full-page transition.
screen_rmse() {
    magick compare -metric RMSE "$1" "$2" null: 2>&1 \
        | sed -n 's/.*(\([^)]*\)).*/\1/p' | head -1
}

a6_screens_differ() {
    local d; d="$(screen_rmse "$1" "$2")"
    awk -v d="${d:-0}" -v m="$A6_RMSE_MIN" 'BEGIN{exit !(d>=m)}'
}

is_blank() {
    local sd; sd="$(magick "$1" -colorspace Gray -format "%[fx:standard_deviation]" info: 2>/dev/null)"
    awk -v s="${sd:-0}" -v m="$BLANK_STDEV_MAX" 'BEGIN{exit !(s<m)}'
}

# Standard deviation of the centred 3:2 guest display band. Asphalt's early
# logo/movie frames are sparse on black (moderate variance), while the failure
# mode is flat black and the later interactive title fills nearly the whole
# band. This lets the suite prove that it saw the movie, not merely the title.
guest_band_stdev() {
    local dims w h band y
    dims="$(magick identify -format '%w %h' "$1" 2>/dev/null)" || return 1
    w="${dims%% *}"; h="${dims##* }"
    band=$((w * 2 / 3)); y=$(((h - band) / 2))
    magick "$1" -crop "${w}x${band}+0+${y}" +repage -colorspace Gray \
        -format "%[fx:standard_deviation]" info: 2>/dev/null
}

guest_band_mean() {
    local dims w h band y
    dims="$(magick identify -format '%w %h' "$1" 2>/dev/null)" || return 1
    w="${dims%% *}"; h="${dims##* }"
    band=$((w * 2 / 3)); y=$(((h - band) / 2))
    magick "$1" -crop "${w}x${band}+0+${y}" +repage -colorspace Gray \
        -format "%[fx:mean]" info: 2>/dev/null
}

a6_is_title() {
    local sd mean
    sd="$(guest_band_stdev "$1")"; mean="$(guest_band_mean "$1")"
    awk -v s="${sd:-0}" -v m="${mean:-0}" -v slo="$A6_TITLE_STDEV_MIN" \
        -v mlo="$A6_TITLE_MEAN_MIN" 'BEGIN{exit !(s>=slo && m>=mlo)}'
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

# N95 (rm-320) Calculator boot. Guards the patch-DLL inflate tail-word overread:
# the deflate bit reader used to load heap garbage past the end of the
# compressed E32 image, nondeterministically corrupting decompressed patch-DLL
# code and killing the whole host process during boot (random stacks in
# font/bitmap paths; rm-320 was the reproducing device while rm-409 booted
# fine). The assertion that matters here is host-process survival, which the
# other suites never check because their failure mode was guest-side.
test_n95calc() {
    echo "== N95 Calculator ($CALC_UID on rm-320) =="
    local crash_stamp="$OUTDIR/.n95_launch_stamp"
    touch "$crash_stamp"

    launch_uid "$CALC_UID" rm-320
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    wait_s 2
    local base; base="$(log_baseline)"
    wait_s 22

    # launchctl can publish the UIKitApplication label a few seconds after the
    # first rendered frame when this suite follows another guest. Poll instead
    # of turning that registration race into a false host-crash result.
    local host_alive=false i
    for i in 1 2 3 4 5 6 7 8; do
        if xcrun simctl spawn "$SIM" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BUNDLE_ID"; then
            host_alive=true
            break
        fi
        wait_s 1
    done

    local host_crash
    host_crash="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'EKA2L1*.ips' -newer "$crash_stamp" 2>/dev/null | head -1)"
    if [ -z "$host_crash" ] && [ "$host_alive" = true ]; then
        check PASS "N95Calc: host process survives boot"
    else
        check FAIL "N95Calc: host process survives boot"
        [ -n "$host_crash" ] && echo "      crash report: $host_crash"
    fi

    local s_boot; s_boot="$(shot n95calc_1_default)"
    is_blank "$s_boot" && check FAIL "N95Calc: default UI rendered (non-blank)" \
                       || check PASS "N95Calc: default UI rendered (non-blank)"

    assert_no_crash "$base" "N95Calc"
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

    local launch_started=$SECONDS
    launch_uid "$A6_UID" "$A6_ROM" fullscreen
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    local base; base="$(log_baseline)"

    # The Symbian^3 video client must be patched into EKA2L1's FFmpeg-backed
    # player. Without the versioned v100 DLL, both intro movies consume their
    # normal time but render black before the title appears.
    local patch_dll="$(dirname "$LOG")/patch/mediaclientvideo_v100.dll"
    if [ -f "$patch_dll" ]; then
        check PASS "Asphalt6: Symbian^3 video patch staged"
    else
        check FAIL "Asphalt6: Symbian^3 video patch staged"
    fi

    # Ignore the brief SwiftUI/app-list frame at launch. Require a moderately
    # sparse non-black frame in the centred guest band before the interactive
    # title is eligible to appear; this is the animated Gameloft/movie content.
    wait_s 2
    local s_intro="" intro_sd=0 deadline=$((SECONDS+A6_INTRO_TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        s_intro="$(shot a6_0_gameloft_intro)"
        intro_sd="$(guest_band_stdev "$s_intro")"
        if awk -v s="${intro_sd:-0}" -v lo="$BLANK_STDEV_MAX" -v hi="$A6_INTRO_STDEV_MAX" \
            'BEGIN{exit !(s>=lo && s<=hi)}'; then
            break
        fi
        wait_s 1
    done
    if awk -v s="${intro_sd:-0}" -v lo="$BLANK_STDEV_MAX" -v hi="$A6_INTRO_STDEV_MAX" \
        'BEGIN{exit !(s>=lo && s<=hi)}'; then
        check PASS "Asphalt6: early Gameloft movie rendered"
    else
        check FAIL "Asphalt6: early Gameloft movie rendered"
        assert_no_crash "$base" "Asphalt6"
        return
    fi

    # Let both bundled movies reach their earliest expected finish, then wait
    # for the filled, bright interactive title. On slower dyncom runs 75 wall
    # seconds can still be the Asphalt-logo movie; treating its later change as
    # "main menu reached" was the source of the old false positive.
    local remaining=$((launch_started+A6_MOVIE_WAIT-SECONDS))
    [ "$remaining" -gt 0 ] && wait_s "$remaining"
    local s_splash=""; s_splash="$(shot a6_1_splash)"
    deadline=$((SECONDS+A6_TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        a6_is_title "$s_splash" && break
        wait_s 6
        s_splash="$(shot a6_1_splash)"
    done
    if ! a6_is_title "$s_splash"; then
        check FAIL "Asphalt6: stable interactive title rendered after intro movies"
        assert_no_crash "$base" "Asphalt6"
        return
    fi
    check PASS "Asphalt6: stable interactive title rendered after intro movies"

    screen_size || { check FAIL "Asphalt6: read screen geometry"; return; }
    local cx cy
    cx="$(pt "$SCR_W" 0.50)"; cy="$(pt "$SCR_H" 0.50)"

    # Use a physical down/up event on the stable "Touch to continue" title.
    touch_xy "$cx" "$cy"

    local s_menu=""
    deadline=$((SECONDS+A6_TIMEOUT))
    while [ $SECONDS -lt $deadline ]; do
        wait_s 8
        s_menu="$(shot a6_2_menu)"
        is_blank "$s_menu" && continue
        a6_screens_differ "$s_splash" "$s_menu" && break
        touch_xy "$cx" "$cy"
    done
    if ! a6_screens_differ "$s_splash" "$s_menu"; then
        check FAIL "Asphalt6: reached main menu"
        assert_no_crash "$base" "Asphalt6"
        return
    fi
    # Capture a settled menu reference. It is also the negative reference for
    # the final in-game assertion, so returning to or remaining on the showroom
    # can no longer pass as a race.
    wait_s 6
    s_menu="$(shot a6_2_menu)"
    check PASS "Asphalt6: reached main menu"

    # Main menu: Free Race is the second item in the right-hand list.
    touch_xy "$(pt "$SCR_W" 0.85)" "$(pt "$SCR_H" 0.42)"
    wait_s 10
    local s_track; s_track="$(shot a6_3_track)"
    if a6_screens_differ "$s_menu" "$s_track"; then
        check PASS "Asphalt6: Free Race opens track select"
    else
        check FAIL "Asphalt6: Free Race opens track select"
    fi

    # Selected carousel cards use a two-tap confirmation gesture.
    double_touch_xy "$(pt "$SCR_W" 0.48)" "$(pt "$SCR_H" 0.53)"
    wait_s 12
    local s_mode; s_mode="$(shot a6_4_mode)"
    if a6_screens_differ "$s_track" "$s_mode"; then
        check PASS "Asphalt6: Nassau opens race-mode select"
    else
        check FAIL "Asphalt6: Nassau opens race-mode select"
    fi

    double_touch_xy "$(pt "$SCR_W" 0.30)" "$(pt "$SCR_H" 0.46)"
    wait_s 15
    local s_car; s_car="$(shot a6_5_car)"
    if a6_screens_differ "$s_mode" "$s_car"; then
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

    if ! is_blank "$s_race" && a6_screens_differ "$s_preview" "$s_race" \
        && a6_screens_differ "$s_menu" "$s_race"; then
        check PASS "Asphalt6: Nassau race renders in-game"
    else
        check FAIL "Asphalt6: Nassau race renders in-game"
    fi

    assert_no_crash "$base" "Asphalt6"
}

# Static (no-simulator) suite: keep the Localizable string catalog in sync with
# source. The keys used by the app are read straight out of the build's
# .stringsdata (the Swift compiler's extraction; the lightweight `xcstringstool
# extract` disagrees with it), and compared against the catalog's keys:
#   - new (referenced but missing) or stale (orphaned) keys -> FAIL so an agent
#     reconciles them by hand.
#   - otherwise a pure canonical-formatting drift -> rewrite + `git add`.
# We deliberately do NOT use `xcstringstool sync` for the new/stale verdict:
# under Xcode 26.6 its ingestion regressed and marks every key stale. The set
# comparison is immune to that; formatting still uses sync but with
# --skip-marking-strings-stale (never stales, keeps every key) and a guard.
# Needs the app to have been built (for the .stringsdata); SKIPs cleanly if the
# data is missing or older than the current sources.
test_strings() {
    echo "== String catalog =="
    echo "   $XCSTRINGS"
    if ! command -v xcrun >/dev/null 2>&1; then check FAIL "strings: xcrun available"; return; fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "      python3 not on PATH"; check PASS "strings: SKIPPED (needs python3)"; return
    fi
    [ -f "$XCSTRINGS" ] || { check FAIL "strings: catalog exists"; return; }

    # Locate a stringsdata dir: env override, else the build output holding the
    # newest .stringsdata overall (skip asan / CompilerId probe dirs). Selecting
    # by the freshest file — not a fixed one like ContentView — matters because
    # an incremental build only regenerates the sources that changed.
    local ddir="${EKA2L1_STRINGSDATA_DIR:-}" newest_data=0
    if [ -z "$ddir" ]; then
        local newest="" bestm=0 f m
        while IFS= read -r f; do
            case "$f" in *"/Objects-normal-asan/"*|*"/CompilerId"*) continue ;; esac
            m="$(stat -f '%m' "$f" 2>/dev/null || echo 0)"
            if [ "$m" -gt "$bestm" ]; then bestm="$m"; newest="$f"; fi
        done < <(find "$REPO_ROOT/build" -type f -name '*.stringsdata' 2>/dev/null)
        [ -n "$newest" ] && ddir="$(dirname "$newest")"
    fi
    if [ -z "$ddir" ] || [ ! -d "$ddir" ]; then
        echo "      no .stringsdata found — build the app first (or set EKA2L1_STRINGSDATA_DIR)"
        check PASS "strings: SKIPPED (no build stringsdata)"; return
    fi
    echo "      stringsdata: $ddir"

    # Guard against stale data: if the newest source out-dates the newest
    # extraction, the verdict would be wrong, so skip rather than fail spuriously.
    local newest_src=0 m f
    while IFS= read -r f; do
        m="$(stat -f '%m' "$f" 2>/dev/null || echo 0)"; [ "$m" -gt "$newest_src" ] && newest_src="$m"
    done < <(find "$REPO_ROOT/src/emu/ios" -name '*.swift' 2>/dev/null)
    while IFS= read -r f; do
        m="$(stat -f '%m' "$f" 2>/dev/null || echo 0)"; [ "$m" -gt "$newest_data" ] && newest_data="$m"
    done < <(find "$ddir" -name '*.stringsdata' 2>/dev/null)
    if [ "$newest_src" -gt "$newest_data" ]; then
        echo "      sources are newer than the stringsdata — rebuild before checking"
        check PASS "strings: SKIPPED (stringsdata stale; rebuild)"; return
    fi

    # Reconcile by key set: keys referenced in source (union of every
    # .stringsdata Localizable table) vs. keys in the catalog.
    local recon
    recon="$(python3 - "$XCSTRINGS" "$ddir" <<'PY'
import json, sys, glob, os
xc = json.load(open(sys.argv[1]))
cat = set(xc['strings'].keys())
ref = set()
for f in glob.glob(os.path.join(sys.argv[2], '*.stringsdata')):
    try: d = json.load(open(f))
    except Exception: continue
    for e in d.get('tables', {}).get('Localizable', []):
        if e.get('key'): ref.add(e['key'])
if not ref:
    print("ERR"); sys.exit(0)
print("NEW "   + ",".join(sorted(ref - cat)))
print("STALE " + ",".join(sorted(cat - ref)))
PY
)"
    if printf '%s\n' "$recon" | grep -q '^ERR$'; then
        echo "      stringsdata carried no Localizable keys — rebuild the app"
        check PASS "strings: SKIPPED (empty extraction)"; return
    fi
    local new stale
    new="$(printf '%s\n' "$recon" | sed -n 's/^NEW //p')"
    stale="$(printf '%s\n' "$recon" | sed -n 's/^STALE //p')"

    if [ -n "$new" ] || [ -n "$stale" ]; then
        check FAIL "strings: catalog in sync with source"
        [ -n "$new" ]   && echo "      NEW   (used in source, missing from catalog): $new"
        [ -n "$stale" ] && echo "      STALE (in catalog, no longer referenced):    $stale"
        echo "      -> an agent must reconcile: add the new keys (translate or verbatim), delete the stale ones."
        return
    fi

    # Keys are in sync. Canonicalise the formatting to match what Xcode writes:
    # plain `sync` produces the canonical layout, and (under Xcode 26.6) also
    # marks every key stale — but the key-set check above already proved none
    # are really stale, so those markers are spurious and stripped by line. The
    # result is byte-identical to an Xcode save; stage it if it changed.
    local work; work="$(mktemp -d)"; cp "$XCSTRINGS" "$work/f.xcstrings"
    local args=() f
    for f in "$ddir"/*.stringsdata; do args+=(--stringsdata "$f"); done
    xcrun xcstringstool sync "$work/f.xcstrings" "${args[@]}" >/dev/null 2>&1
    sed '/^[[:space:]]*"extractionState" : "stale",$/d' "$work/f.xcstrings" > "$work/canon.xcstrings"

    # Safety: only touch the file if the rewrite is valid JSON, keeps the exact
    # same key set, and carries no leftover extractionState.
    local safe
    safe="$(python3 - "$XCSTRINGS" "$work/canon.xcstrings" <<'PY'
import json, sys
try:
    a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
except Exception:
    print("UNSAFE"); sys.exit(0)
ok = set(a['strings']) == set(b['strings']) and \
     not any('extractionState' in v for v in b['strings'].values())
print("OK" if ok else "UNSAFE")
PY
)"
    if [ "$safe" != OK ]; then
        check PASS "strings: catalog in sync (formatting rewrite skipped — unsafe)"
    elif diff -q "$XCSTRINGS" "$work/canon.xcstrings" >/dev/null 2>&1; then
        check PASS "strings: catalog in sync (no changes)"
    else
        cp "$work/canon.xcstrings" "$XCSTRINGS"
        if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            git -C "$REPO_ROOT" add "$XCSTRINGS" >/dev/null 2>&1
            check PASS "strings: formatting normalised and staged"
        else
            check PASS "strings: formatting normalised (not a git tree; left unstaged)"
        fi
    fi
    rm -rf "$work"
}

# ---- main ------------------------------------------------------------------

need xcrun
if [ "$SUITE" != strings ]; then
    need xcodebuildmcp; need jq; need magick
    SIM="$(booted_sim)"; [ -z "$SIM" ] && die "no booted iPhone simulator"
else
    SIM=""
fi
mkdir -p "$OUTDIR"
[ -n "$SIM" ] && echo "simulator: $SIM"
echo "results:   $OUTDIR"

if [ -n "$INSTALL_APP" ]; then
    [ -n "$SIM" ] || die "--install requires a booted simulator"
    [ -d "$INSTALL_APP" ] || die "app not found: $INSTALL_APP"
    echo "installing $INSTALL_APP"
    xcrun simctl install "$SIM" "$INSTALL_APP" || die "install failed"
fi

case "$SUITE" in
    fbattle)    test_fbattle ;;
    calculator|calc) test_calculator ;;
    n95calc)    test_n95calc ;;
    angrybirds|ab) test_angrybirds ;;
    asphalt6|asphalt|a6) test_asphalt6 ;;
    strings)    test_strings ;;
    all|"")     test_fbattle; test_calculator; test_n95calc; test_strings ;;
    *) die "unknown suite: $SUITE (use fbattle|calculator|n95calc|angrybirds|asphalt6|strings|all)" ;;
esac

echo
echo "===== regression summary ====="
printf '%s\n' "${RESULTS[@]}"
echo "------------------------------"
echo "PASS=$PASS FAIL=$FAIL   screenshots in $OUTDIR"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
