#!/usr/bin/env bash
#
# iOS regression validation (xcodebuildmcp CLI based).
#
# Drives the booted iPhone simulator through known guest apps and asserts they
# still behave, so unrelated emulator changes can be regression-checked quickly.
# Screenshots for every checked state are saved under the results dir for human
# review; the script also makes hard programmatic assertions and exits non-zero
# if any fail.
#
# Assertions read the guest screen. Every screenshot goes through the Vision
# OCR helper in scripts/ocr (built on demand) and is checked for the words that
# screen has to be showing — "Last result" for the calculator's Options menu,
# "Touch to continue" for the Asphalt title, and so on. A changed-pixel count
# proves only that something repainted; naming the text proves the guest
# reached the state, and a failure prints back what it did read.
#
#   Final Battle (0xA0003C62) : reaches the first in-game prompt and does NOT
#                               hit the E32USER-CBase 46 stray-signal panic.
#   Calculator   (0x10005902) : renders its soft-key row, accepts number input,
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
#                               permanently), then asserts a tap reaches the
#                               episode carousel and a swipe pages it. Guards
#                               the raw-touch pointer path (UITouch -> guest
#                               pointer-slot mapping).
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
# Two states carry no text and stay measured instead of read: Asphalt's intro
# movie (guarded against a flat black band by its variance) and the
# calculator's entry display (seven-segment digits Vision cannot recognize).
#
# Requirements: a booted iPhone simulator with EKA2L1 installed and a device
# (e.g. 5320/rm-409) mounted, the apps available, plus `xcodebuildmcp`, `jq`,
# ImageMagick (`magick`) and a Swift toolchain (`xcrun swiftc`, for the OCR
# helper) on PATH. The n95calc suite (part of `all`) additionally needs the N95
# (rm-320) mounted. The angrybirds and asphalt6 suites additionally need the X7
# (rm-707), their respective game installed, and the `axe` HID tool (bundled
# inside xcodebuildmcp; auto-located). It does NOT build the emulator.
#
# Every tap is sent with a post-delay: on Xcode 27 `dtuhidd` activates its
# virtual touchscreen service only once it has a peer and drops anything that
# arrives before that, so a tap whose process exits immediately is reported as
# SUCCEEDED and never reaches the guest (AXe #71).
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
#   EKA2L1_REG_TAP_POST_DELAY
#                            seconds a tap holds the HID connection open after
#                            writing the event (default 0.6)
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
#   EKA2L1_REG_BAND_KEYPAD   normalized x,y,w,h crop of the guest picture that
#   EKA2L1_REG_BAND_FULL     OCR reads, for the keypad and fullscreen layouts
#   EKA2L1_REG_OCR_SCALE     upscale factor before recognition (default 2)

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
A6_ROM="${EKA2L1_REG_A6_ROM:-rm-707}"
A6_INTRO_TIMEOUT="${EKA2L1_REG_A6_INTRO_TIMEOUT:-20}"
A6_MOVIE_WAIT="${EKA2L1_REG_A6_MOVIE_WAIT:-75}"
A6_TIMEOUT="${EKA2L1_REG_A6_TIMEOUT:-240}"
A6_INTRO_STDEV_MAX="${EKA2L1_REG_A6_INTRO_STDEV_MAX:-0.24}"

# Pixels that must differ for a screen to count as "changed" (ignores the small
# clock / FPS-counter noise between captures). Only the calculator's entry
# display still needs this: its seven-segment digits are not recognizable text.
SCREEN_DIFF_MIN="${EKA2L1_REG_SCREEN_DIFF_MIN:-4000}"
# Grayscale stdev (0..1) below which a screenshot counts as blank.
BLANK_STDEV_MAX="0.04"

# Normalized (0..1) crop of the screenshot that holds the guest picture, per
# keypad layout. OCR runs on this region only: the host keypad prints its own
# letters, and the L/R soft-key pills sit on top of the guest's soft-key row.
BAND_KEYPAD="${EKA2L1_REG_BAND_KEYPAD:-0,0.06,1,0.64}"
BAND_FULL="${EKA2L1_REG_BAND_FULL:-0,0.34,1,0.32}"
BAND="$BAND_KEYPAD"
# Guest text is small; Vision reads it far more reliably upscaled.
OCR_SCALE="${EKA2L1_REG_OCR_SCALE:-2}"

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

# Seconds an `axe tap` process must stay alive after writing the event. On
# Xcode 27 dtuhidd activates its virtual touchscreen service only once it has a
# peer and silently drops whatever arrives before that, so a tap that exits
# immediately is reported as SUCCEEDED and never reaches the guest.
TAP_POST_DELAY="${EKA2L1_REG_TAP_POST_DELAY:-0.6}"

tap_ref() {
    local ref="$1" i r
    [ -z "$ref" ] && return 1
    for i in 1 2 3 4 5 6; do
        r="$(xcodebuildmcp ui-automation tap --simulator-id "$SIM" --element-ref "$ref" \
             --post-delay "$TAP_POST_DELAY" --output json 2>/dev/null \
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

tap_xy()   { "$AXE" tap -x "$1" -y "$2" --post-delay "$TAP_POST_DELAY" --udid "$SIM" >/dev/null 2>&1; }
touch_xy() { "$AXE" touch -x "$1" -y "$2" --down --up --delay 0.08 --udid "$SIM" >/dev/null 2>&1; }
double_touch_xy() { touch_xy "$1" "$2" && touch_xy "$1" "$2"; }
swipe_xy() { "$AXE" swipe --start-x "$1" --start-y "$2" --end-x "$3" --end-y "$4" --duration "${5:-0.5}" --post-delay "$TAP_POST_DELAY" --udid "$SIM" >/dev/null 2>&1; }
pt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.0f", a*b}'; }

# differing-pixel count between two screenshots (AE can be printed in scientific
# notation for large diffs, so coerce to a plain integer).
screen_diff_px() {
    magick compare -metric AE "$1" "$2" null: 2>&1 | awk 'NR==1{printf "%.0f", $1+0; exit} END{if(NR==0)print 0}'
}
screens_differ() { [ "$(screen_diff_px "$1" "$2")" -ge "$SCREEN_DIFF_MIN" ]; }

# Standard deviation of the centred 3:2 guest display band. Asphalt's early
# logo/movie frames are sparse on black (moderate variance), while the failure
# mode is flat black. This lets the suite prove that it saw the movie, which
# carries no text for OCR to key off.
guest_band_stdev() {
    local dims w h band y
    dims="$(magick identify -format '%w %h' "$1" 2>/dev/null)" || return 1
    w="${dims%% *}"; h="${dims##* }"
    band=$((w * 2 / 3)); y=$(((h - band) / 2))
    magick "$1" -crop "${w}x${band}+0+${y}" +repage -colorspace Gray \
        -format "%[fx:standard_deviation]" info: 2>/dev/null
}

# ---- screen text (OCR) -----------------------------------------------------
# Assertions name what a guest screen has to say. Vision reads the guest band
# out of the screenshot; comparisons run on the letters and digits alone,
# because OCR drifts on case, spacing and punctuation long before it drifts on
# the characters that carry the meaning.

LAST_OCR=""    # recognized text of the screenshot ocr_read last looked at
LAST_FLAT=""   # ... the same text, reduced to lowercase letters and digits

flatten() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

ocr_read() {
    LAST_OCR="$("$SCREENTEXT" "$1" --crop "$BAND" --scale "$OCR_SCALE" 2>/dev/null)"
    LAST_FLAT="$(flatten "$LAST_OCR")"
}

# Match against the screenshot ocr_read last looked at: any of the wanted
# strings for flat_has, all of them for flat_has_all.
flat_has() {
    local want
    for want in "$@"; do
        want="$(flatten "$want")"
        [ -n "$want" ] || continue
        case "$LAST_FLAT" in *"$want"*) return 0 ;; esac
    done
    return 1
}

flat_has_all() {
    local want
    for want in "$@"; do
        want="$(flatten "$want")"
        case "$LAST_FLAT" in *"$want"*) ;; *) return 1 ;; esac
    done
    return 0
}

# What the screen actually said, so a failure carries its own evidence.
ocr_evidence() { echo "      read: $(printf '%s' "$LAST_OCR" | tr '\n' '|')"; }

# check_text "<desc>" <png> <wanted>...  : PASS if any wanted string is on screen
check_text() {
    local desc="$1" png="$2"; shift 2
    ocr_read "$png"
    if flat_has "$@"; then check PASS "$desc"; else check FAIL "$desc"; ocr_evidence; fi
}

# wait_text <shot-name> <budget-seconds> <wanted>... : re-shoot until one of the
# wanted strings shows up. Leaves the last screenshot in WAIT_SHOT and its text
# in LAST_OCR / LAST_FLAT either way.
WAIT_SHOT=""
wait_text() {
    local name="$1" budget="$2"; shift 2
    local deadline=$((SECONDS+budget))
    while :; do
        WAIT_SHOT="$(shot "$name")"
        ocr_read "$WAIT_SHOT"
        flat_has "$@" && return 0
        [ $SECONDS -ge $deadline ] && return 1
        wait_s 5
    done
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
    BAND="$BAND_KEYPAD"
    launch_uid "$FBATTLE_UID"
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    wait_s 8
    local base; base="$(log_baseline)"

    if wait_text fbattle_1_language 60 "english" "deutsch" "italiano"; then
        check PASS "FBattle: language menu lists its languages"
    else
        check FAIL "FBattle: language menu lists its languages"
        ocr_evidence
    fi

    # The menu is drawn before the game starts reading keys, so the first press
    # is regularly swallowed. Press until the language list is actually gone
    # rather than trusting that the key was delivered.
    local i selected=false
    for i in 1 2 3 4; do
        snapshot
        tap_label "1" || true
        wait_s 6
        ocr_read "$(shot fbattle_1_language)"
        if ! flat_has "deutsch" "italiano"; then selected=true; break; fi
    done
    [ "$selected" = true ] || check FAIL "FBattle: select language"

    tap_label "OK"               || check FAIL "FBattle: Start Game (OK)"
    wait_s 8
    tap_label "OK"               || check FAIL "FBattle: confirm intro (OK)"
    echo "    in-game dwell ${INGAME_WAIT}s (the crash used to fire ~60s in)..."
    wait_s "$INGAME_WAIT"

    # The first in-game prompt. Rendering can lag the guest by tens of seconds,
    # so keep re-reading the screen instead of judging one frame; a confirm key
    # lost to a screen transition needs another press rather than a verdict.
    local prompted=false
    for i in 1 2 3; do
        if wait_text fbattle_2_ingame 40 "what do you do" "open your eyes" "go on sleeping"; then
            prompted=true
            break
        fi
        tap_label "OK" || true
    done
    if [ "$prompted" = true ]; then
        check PASS "FBattle: reached the first in-game prompt"
    else
        check FAIL "FBattle: reached the first in-game prompt"
        ocr_evidence
    fi

    assert_no_crash "$base" "FBattle"
}

test_calculator() {
    echo "== Calculator ($CALC_UID) =="
    BAND="$BAND_KEYPAD"
    launch_uid "$CALC_UID"
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    wait_s 18
    local base; base="$(log_baseline)"

    # 1) default render, keyed off the guest's own soft-key row. "Options" and
    # "Exit" sit under the host's L/R pills; the centre label does not.
    local s_default
    if wait_text calc_1_default 40 "select"; then
        check PASS "Calculator: default UI shows the Select soft key"
    else
        check FAIL "Calculator: default UI shows the Select soft key"
        ocr_evidence
    fi
    s_default="$WAIT_SHOT"

    # 2) number input -> the entry display repaints. This is the one assertion
    # that cannot be read: the display draws its digits in a seven-segment font
    # that Vision does not recognize, so fall back to comparing the guest band.
    snapshot
    # The digit keys combine "2" and "ABC" into one accessibility label whose
    # separator is locale-dependent ("2, ABC" vs "2、ABC"), so match the digit
    # prefix instead of the whole label.
    tap_label "1"           || check FAIL "Calculator: key 1"
    tap_label "2" prefix    || check FAIL "Calculator: key 2"
    tap_label "3" prefix    || check FAIL "Calculator: key 3"
    wait_s 3
    local s_input; s_input="$(shot calc_2_input)"
    screens_differ "$s_default" "$s_input" \
        && check PASS "Calculator: number input changes the entry display" \
        || check FAIL "Calculator: number input changes the entry display"

    # 3) left soft key opens the Options menu, which is all text
    tap_label "LSK"         || check FAIL "Calculator: press LSK"
    wait_s 4
    local s_menu; s_menu="$(shot calc_3_menu_open)"
    ocr_read "$s_menu"
    if flat_has_all "last result" "memory" "help"; then
        check PASS "Calculator: LSK opens the Options menu (Last result/Memory/Help)"
    else
        check FAIL "Calculator: LSK opens the Options menu (Last result/Memory/Help)"
        ocr_evidence
    fi

    # 4) right soft key closes it: the menu items are gone and the calculator's
    # own soft-key row is back.
    tap_label "RSK"         || check FAIL "Calculator: press RSK"
    wait_s 4
    local s_closed; s_closed="$(shot calc_4_menu_closed)"
    ocr_read "$s_closed"
    if flat_has "select" && ! flat_has "last result" "memory"; then
        check PASS "Calculator: RSK closes the Options menu"
    else
        check FAIL "Calculator: RSK closes the Options menu"
        ocr_evidence
    fi

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
    BAND="$BAND_KEYPAD"
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
    local host_alive=false launch_services i
    for i in 1 2 3 4 5 6 7 8; do
        launch_services="$(xcrun simctl spawn "$SIM" launchctl list 2>/dev/null || true)"
        if [[ "$launch_services" == *"UIKitApplication:$BUNDLE_ID"* ]]; then
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

    # The N95 skin leaves the centre soft key empty, so key off the right one.
    # OCR reads it through the host's R pill as "RExit".
    if wait_text n95calc_1_default 40 "exit"; then
        check PASS "N95Calc: calculator UI shows its Exit soft key"
    else
        check FAIL "N95Calc: calculator UI shows its Exit soft key"
        ocr_evidence
    fi

    assert_no_crash "$base" "N95Calc"
}

test_angrybirds() {
    echo "== Angry Birds ($AB_UID on $AB_ROM) =="
    if ! find_axe; then
        check FAIL "AngryBirds: axe HID tool located"
        return
    fi

    BAND="$BAND_FULL"
    launch_uid "$AB_UID" "$AB_ROM" fullscreen
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    local base; base="$(log_baseline)"

    # Resolved up front: the loading screen is short-lived, so the trigger tap
    # must not wait on a describe-ui round trip after the first frame lands.
    screen_size || { check FAIL "AngryBirds: read screen geometry"; return; }

    # 1) Boot. The Rovio copyright card and the loading screen come first, but
    # both are short-lived and a fast boot can be at the PLAY menu by the time
    # the first screenshot lands, so take any of the game's own screens.
    wait_s 10
    if ! wait_text ab_1_splash "$AB_TIMEOUT" "loading" "rovio" "play" "score"; then
        check FAIL "AngryBirds: boot renders the game UI"
        ocr_evidence
        assert_no_crash "$base" "AngryBirds"
        return
    fi
    check PASS "AngryBirds: boot renders the game UI"

    # 2) Tap the loading screen once. This is the regression trigger: the
    # UITouch identity from this tap must not poison the guest pointer slots
    # (pre-fix it permanently killed all later gestures on Symbian^3 guests).
    tap_xy "$(pt "$SCR_W" 0.5)" "$(pt "$SCR_H" 0.5)"
    echo "    tapped the loading screen; waiting for the main menu..."

    # 3) The first touch must leave the UI alive and interactive: the main menu
    # prints PLAY. The guest queues pointer events it is not reading yet, so
    # that tap can instead be delivered to the menu the moment it opens and
    # take the game straight to the episode carousel (SCORE / n of 189 on each
    # card) — accept either.
    if ! wait_text ab_2_menu "$AB_TIMEOUT" "play" "score"; then
        check FAIL "AngryBirds: menu survives the first touch"
        ocr_evidence
        assert_no_crash "$base" "AngryBirds"
        return
    fi
    check PASS "AngryBirds: menu survives the first touch"

    # 4) PLAY sits at the centre of the letterboxed guest band. Whichever tap
    # got there, the episode carousel is what proves a tap reached the guest.
    if ! flat_has "score"; then
        wait_s 5
        tap_xy "$(pt "$SCR_W" 0.5)" "$(pt "$SCR_H" 0.5)"
    fi
    if wait_text ab_3_episodes 60 "score"; then
        check PASS "AngryBirds: tap opens the episode carousel (touch alive after loading tap)"
    else
        check FAIL "AngryBirds: tap opens the episode carousel (touch alive after loading tap)"
        ocr_evidence
        assert_no_crash "$base" "AngryBirds"
        return
    fi

    # 5) Paging the carousel must bring different episode cards into view (the
    # names and their star totals are what OCR compares; a settled carousel
    # reads back byte-identical). Let the cards finish sliding in first: a
    # gesture during the transition is dropped, and a half-drawn reference
    # frame would differ from the settled one for the wrong reason.
    wait_s 8
    ocr_read "$(shot ab_3_episodes)"
    local before="$LAST_FLAT"

    # Retry across band rows and then the opposite direction: a drag that
    # starts on a card is swallowed, and a carousel already sitting on its
    # last page cannot move any further.
    local y sx ex i moved=false
    for i in 1 2 3; do
        case $i in
            1) y="$(pt "$SCR_H" 0.54)"; sx=0.8; ex=0.2 ;;
            2) y="$(pt "$SCR_H" 0.46)"; sx=0.8; ex=0.2 ;;
            *) y="$(pt "$SCR_H" 0.58)"; sx=0.2; ex=0.8 ;;
        esac
        swipe_xy "$(pt "$SCR_W" "$sx")" "$y" "$(pt "$SCR_W" "$ex")" "$y" 0.5
        wait_s 4
        ocr_read "$(shot ab_4_swiped)"
        if [ -n "$LAST_FLAT" ] && [ "$LAST_FLAT" != "$before" ]; then
            moved=true
            break
        fi
        before="$LAST_FLAT"
    done
    if [ "$moved" = true ]; then
        check PASS "AngryBirds: swipe pages the carousel (drag responds)"
    else
        check FAIL "AngryBirds: swipe pages the carousel (drag responds)"
        ocr_evidence
    fi

    assert_no_crash "$base" "AngryBirds"
}

test_asphalt6() {
    echo "== Asphalt 6 ($A6_UID on $A6_ROM) =="
    if ! find_axe; then
        check FAIL "Asphalt6: axe HID tool located"
        return
    fi

    BAND="$BAND_FULL"
    local launch_started=$SECONDS
    launch_uid "$A6_UID" "$A6_ROM" fullscreen
    LOG="$(log_path)"; [ -z "$LOG" ] && die "cannot find emulator log"
    local base; base="$(log_baseline)"

    # The Symbian^3 video client must be patched into EKA2L1's FFmpeg-backed
    # player. Without the versioned v100 DLL, both intro movies consume their
    # normal time but render black before the title appears. Patch DLLs are
    # read straight out of the app bundle; nothing is staged into the data
    # container.
    local app_bundle; app_bundle="$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" app 2>/dev/null)"
    if [ -n "$app_bundle" ] && [ -f "$app_bundle/emures/patch/mediaclientvideo_v100.dll" ]; then
        check PASS "Asphalt6: Symbian^3 video patch shipped"
    else
        check FAIL "Asphalt6: Symbian^3 video patch shipped"
    fi

    # Ignore the brief SwiftUI/app-list frame at launch. Require a moderately
    # sparse non-black frame in the centred guest band before the interactive
    # title is eligible to appear; this is the animated Gameloft/movie content.
    # The movies are the one thing here with no text to read: the failure mode
    # they guard against is a flat black band, which the variance catches.
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
    # for the interactive title. "Touch to continue" is printed by the title
    # only — the preceding logo movies carry no text, which is what used to let
    # one of them pass as "main menu reached".
    local remaining=$((launch_started+A6_MOVIE_WAIT-SECONDS))
    [ "$remaining" -gt 0 ] && wait_s "$remaining"
    if ! wait_text a6_1_splash "$A6_TIMEOUT" "touch to continue"; then
        check FAIL "Asphalt6: interactive title invites a touch after the intro movies"
        ocr_evidence
        assert_no_crash "$base" "Asphalt6"
        return
    fi
    check PASS "Asphalt6: interactive title invites a touch after the intro movies"
    local s_splash="$WAIT_SHOT"

    screen_size || { check FAIL "Asphalt6: read screen geometry"; return; }
    local cx cy
    cx="$(pt "$SCR_W" 0.50)"; cy="$(pt "$SCR_H" 0.50)"

    # Use a physical down/up event on the stable "Touch to continue" title. The
    # title can swallow the first one while it is still fading in.
    touch_xy "$cx" "$cy"

    deadline=$((SECONDS+A6_TIMEOUT))
    local reached_menu=false
    while :; do
        wait_s 8
        ocr_read "$(shot a6_2_menu)"
        if flat_has "free race"; then reached_menu=true; break; fi
        [ $SECONDS -ge $deadline ] && break
        flat_has "touch to continue" && touch_xy "$cx" "$cy"
    done
    if [ "$reached_menu" != true ]; then
        check FAIL "Asphalt6: main menu lists Free Race"
        ocr_evidence
        assert_no_crash "$base" "Asphalt6"
        return
    fi
    check PASS "Asphalt6: main menu lists Free Race"

    # Main menu: Free Race is the second item in the right-hand list. Let the
    # showroom transition finish first — the guest drops pointer events that
    # land while a screen is still animating in — and confirm with the same
    # select-then-activate double touch the carousel cards below use.
    wait_s 8
    double_touch_xy "$(pt "$SCR_W" 0.85)" "$(pt "$SCR_H" 0.42)"
    wait_s 10
    # Nassau also names the race-mode screen that follows, so key the track
    # carousel off its country line.
    check_text "Asphalt6: Free Race opens the Nassau/Bahamas track card" \
        "$(shot a6_3_track)" "bahamas"

    # Selected carousel cards use a two-tap confirmation gesture.
    double_touch_xy "$(pt "$SCR_W" 0.48)" "$(pt "$SCR_H" 0.53)"
    wait_s 12
    check_text "Asphalt6: Nassau opens race-mode select (Elimination/Collector)" \
        "$(shot a6_4_mode)" "elimination" "collector"

    double_touch_xy "$(pt "$SCR_W" 0.30)" "$(pt "$SCR_H" 0.46)"
    wait_s 15
    check_text "Asphalt6: Normal Race opens car select (Top Speed/Handling)" \
        "$(shot a6_5_car)" "top speed" "handling"

    # RACE and the following two confirmation arrows share the bottom-right
    # location. Each uses the same selected-control double-tap behavior.
    local next_x next_y
    next_x="$(pt "$SCR_W" 0.91)"; next_y="$(pt "$SCR_H" 0.60)"
    double_touch_xy "$next_x" "$next_y"
    wait_s 25
    shot a6_6_preview >/dev/null
    double_touch_xy "$next_x" "$next_y"
    wait_s 10
    double_touch_xy "$(pt "$SCR_W" 0.93)" "$next_y"
    wait_s 25

    # The race HUD prints the speedometer and the position readout. Requiring
    # the car-select stats to be gone keeps a stalled selection screen — which
    # also prints km/h — from passing as a race.
    ocr_read "$(shot a6_7_race)"
    if flat_has "kmh" && ! flat_has "top speed" "free race"; then
        check PASS "Asphalt6: Nassau race renders its in-game HUD"
    else
        check FAIL "Asphalt6: Nassau race renders its in-game HUD"
        ocr_evidence
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
    done < <(find "$REPO_ROOT/src/emu/ios/App" -name '*.swift' 2>/dev/null)
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
SCREENTEXT=""
if [ "$SUITE" != strings ]; then
    need xcodebuildmcp; need jq; need magick
    SCREENTEXT="$("$REPO_ROOT/scripts/ocr/build.sh")" || die "cannot build the screentext OCR helper"
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
