# AGENTS.md

An iOS-focused fork of upstream EKA2L1. The goal is a practical, debuggable iOS port
that still preserves upstream emulator behavior — Android, desktop Qt, and the shared
architecture must keep working.

## Priorities

- Fix the general emulator behavior, not the symptom in one title. App/game-specific
  hacks are acceptable only as an explicitly labelled diagnostic step.
- Scope fixes narrowly; only touch shared emulator code when the bug is genuinely
  cross-platform.
- Strip temporary logging, tracing, and debug probes before committing.

## iOS workflow

- Build: `./scripts/build_ios.sh simulator`. Defaults to **Debug**
  (`Debug-iphonesimulator`); set `EKA2L1_IOS_CONFIGURATION=Release` for anything you
  intend to benchmark or regression-test, and make sure you didn't install the stale
  artifact from the other configuration.
- Launch args skip the UI: `-LaunchROMCode rm-707 -LaunchAppUID 0x2000023D`.
- Give a freshly launched guest app ~20s before judging a screenshot — Symbian
  services, window server, and the first frame need time to settle.
- Emulator log: `Documents/data/EKA2L1.log` inside the app data container
  (`xcrun simctl get_app_container booted com.eka2l1.emulator data`).
- Use the XcodeBuildMCP skill before calling XcodeBuildMCP tools. When performing actions XcodeBuildMCP doesn't support (eg. guest touch or system file browser), use AXE tool shipped with XcodeBuildMCP.

### Symbian source-guided diagnosis

For unclear IPC, ABI, descriptor-slot, panic, or service behavior, read the original
contract instead of guessing: the local SDK/OSS tree under `~/Developer/symbian`
first, then `gh search code` against `SymbianSource` repositories. Search by
opcode/export/class/panic name and read *both* the client request construction and
the server completion/cancel paths — argument types, slot numbers, ownership, and
sync-vs-async cancellation are the compatibility target.

A bad guest request and a host lifetime race look alike. Validate guest pointers
defensively, but also prove that stop/close/session teardown cannot race a queued
host callback.

### Symbian patch DLL builds in UTM

The `Windows XP` VM has S60 2nd FP3 (`C:\Symbian\8.1a`), S60 3rd FP2, S60 5th and Belle
(`sbs`) plus the checkout at `C:\eka2l1`; push every edited source, run the matching
UREL command, poll because `utmctl exec` returns early, then validate and install the
E32Image (adjust patch and target names as needed):

```sh
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
VM='Windows XP'

"$UTMCTL" file push "$VM" 'C:\eka2l1\src\patch\mediaclientaudio\src\impl.cpp' < src/patch/mediaclientaudio/src/impl.cpp
wait_utm_build() {
  while ! "$UTMCTL" file pull "$VM" 'C:\eka2l1\patch-build-result.txt' 2>/dev/null | tr -d '\r' | rg -q '^(ok|failed)$'; do sleep 3; done
  test "$("$UTMCTL" file pull "$VM" 'C:\eka2l1\patch-build-result.txt' | tr -d '\r\n ')" = ok
}

# S60 3rd FP2
"$UTMCTL" exec "$VM" --cmd cmd.exe /c 'del /q C:\eka2l1\patch-build-result.txt 2>nul & call devices -setdefault @S60_3rd_FP2_SDK_v1.1:com.nokia.s60 > C:\eka2l1\patch-build.log 2>&1 & cd /d C:\eka2l1\src\patch\mediaclientaudio\group\general & call abld reallyclean gcce >> C:\eka2l1\patch-build.log 2>&1 & call bldmake bldfiles >> C:\eka2l1\patch-build.log 2>&1 & call abld build gcce urel >> C:\eka2l1\patch-build.log 2>&1 & if errorlevel 1 (echo failed> C:\eka2l1\patch-build-result.txt) else (echo ok> C:\eka2l1\patch-build-result.txt)'
wait_utm_build
"$UTMCTL" file pull "$VM" 'C:\S60\devices\S60_3rd_FP2_SDK_v1.1\epoc32\release\GCCE\urel\mediaclientaudio_general.dll' > /tmp/mediaclientaudio_s60v3.dll

# Symbian Belle
"$UTMCTL" exec "$VM" --cmd cmd.exe /c 'del /q C:\eka2l1\patch-build-result.txt 2>nul & set "EPOCROOT=\Nokia\devices\Nokia_Symbian_Belle_SDK_v1.0\" & set "PATH=C:\Perl\bin;C:\Program Files\Common Files\Symbian\tools;C:\Program Files\CodeSourcery\Sourcery G++ Lite\bin;C:\Nokia\devices\Nokia_Symbian_Belle_SDK_v1.0\epoc32\tools\sbs\bin;%PATH%" & cd /d C:\eka2l1\src\patch\mediaclientaudio\group\general & call sbs -b bld.inf -c armv5_urel_gcce4_4_1 > C:\eka2l1\patch-build.log 2>&1 & if errorlevel 1 (echo failed> C:\eka2l1\patch-build-result.txt) else (echo ok> C:\eka2l1\patch-build-result.txt)'
wait_utm_build
"$UTMCTL" file pull "$VM" 'C:\Nokia\devices\Nokia_Symbian_Belle_SDK_v1.0\epoc32\release\armv5\urel\mediaclientaudio_general.dll' > /tmp/mediaclientaudio_belle.dll

~/Developer/symbian/symbian-dll-agent-kit/tools/verify_e32.py /tmp/mediaclientaudio_s60v3.dll
~/Developer/symbian/symbian-dll-agent-kit/tools/verify_e32.py /tmp/mediaclientaudio_belle.dll
PATCH_DLL=/tmp/mediaclientaudio_belle.dll # or /tmp/mediaclientaudio_s60v3.dll
cp "$PATCH_DLL" src/patch/mediaclientaudio/group/mediaclientaudio_general.dll
```

`group/target.inf` names the SDK per variant. The EKA1 `_v81a` variants build with
`@S60_2nd_FP3:com.nokia.series60` and **`abld build armi urel`** (the SDK's classic GCC,
no PATH juggling needed); output lands in
`C:\Symbian\8.1a\S60_2nd_FP3\Epoc32\release\armi\urel\`. `verify_e32.py` rejects
those with `CPU expected ARMv5, got 0x0000` — that check only applies to EKA2 images, so
compare the header against the currently checked-in binary instead. `_general` builds
with `@S60_5th_Edition_SDK_v1.0:com.nokia.s60` and `gcce urel`, needs
`C:\PROGRA~1\CSL Arm Toolchain\bin` on PATH, and its output is under
`C:\S60\devices\S60_5th_Edition_SDK_v1.0\epoc32\release\GCCE\urel\`.

Build `src/patch/priv` (same SDK, same platform) first and push its sources too — a
stale `priv.lib` in the SDK shows up as undefined references to things like
`ConvertFreqEnumToNumber`. When one `src/*.cpp` feeds several variants, rebuild **all**
of them; shipping one stale binary means two different implementations of one file.

### TestFlight crash symbolication

Map the build to a commit with `gh run list --workflow "iOS TestFlight"`, download
that run's `EKA2L1-testflight-dSYM-<sha>` artifact, and require an exact
`dwarfdump --uuid` match before trusting any symbol. `xcrun atos -arch arm64 -o
<dSYM DWARF binary> -l <image load address>` resolves unsymbolicated frames.

Compare every report from the same build before editing code: watchdog reports often
share one lock cycle, and a random-looking main-thread crash can be secondary heap
corruption. Keep exported crash files and downloaded symbols out of commits.

### Physical device

The simulator runs on the build host, so it hides device-only bugs (e.g. resources
staged from `__FILE__`-relative paths). Verify device-facing fixes on hardware:
iPhone Air, UDID `77611A2B-2A02-51FA-BAFC-2104F1D8011A`, team `L6JP27B8YR`
(`EKA2L1_IOS_DEVELOPMENT_TEAM` + `EKA2L1_IOS_DEVICE` env for
`scripts/build_ios.sh install`).

Quirks: the device must be unlocked or `devicectl ... process launch` errors
"Locked"; `devicectl device copy from` intermittently returns empty or "Connection
reset", so retry; there is no CLI screenshot — ask the user to confirm screen and
sound visually.

## Verification

Run the regression script against a **Release** simulator build before concluding any
emulator-affecting change:

```sh
scripts/ios_regression_test.sh --install build/ios-simulator/src/emu/ios/Release-iphonesimulator/EKA2L1.app
scripts/ios_regression_test.sh                 # re-run without reinstalling
scripts/ios_regression_test.sh angrybirds      # input/touch or Symbian^3 changes
```

The default suite drives Final Battle and Calculator (plus the N95 calculator checks);
`angrybirds` covers the touch path and needs X7/rm-707 with Angry Birds installed.
Screenshots land in `/tmp/eka2l1-regression`. Non-zero exit means a regression —
investigate before landing. Needs a booted simulator with a device (e.g. 5320/rm-409)
mounted and the apps installed, plus `xcodebuildmcp`, `jq`, and ImageMagick.

Beyond the script: check the affected app path plus a known-good control app, confirm
success visually rather than from a clean process launch, and scan the log for panics,
access violations, graphics halts, and leftover diagnostics. If a previously working
flow breaks after a change, treat it as a regression from that change and narrow the
diff rather than debugging the broken flow in isolation.

## Upstream contributions

Changes flow one way: develop on the fork, PR against `EKA2L1/EKA2L1:master`, then sync
the fork's `master` and merge it into `ios-next`. No second fork-internal PR for the
same commits. Upstream has no `docs/` — strip the fork's write-ups, the reasoning goes
in the commit message.

- **Select by file, not by commit.** `git diff HEAD ios-next -- <file>` empty means the
  file is fully upstreamed; a file usually carries several unrelated fork batches, so
  take hunks, not the fork's final version.
- **Revert each fix alone** and table the result in the PR description. Commit first —
  both `git checkout -- <file>` and `git checkout HEAD -- <file>` silently discard
  uncommitted work. Confirm the binary actually recompiled before believing a harness.
- **Anchor fixtures to the official contract**, not to EKA2L1: copy expected values from
  the SDK headers instead of back-computing them from the code under test.
- **`ekatests`** runs from its own build dir (`build/desk-check/src/tests/`; the x86_64
  `build/a1-tests` has never built it) — asset paths are relative. Catch2 dies on a
  fatal signal printing a *partial* summary that looks like pre-existing failures, so
  compare `--list-tests` counts with the run summary. Declare `epoc::object_table` last
  in a test, or the *next* case dies before it starts.
- **Building the Qt frontend runs lupdate and dirties 26 `.ts` files** (`build_ios.sh`
  and `--target eka2l1_qt` alike): commit before building, then
  `git checkout -- src/emu/qt/translations/`. A whole-file `.ts` diff with an empty
  `git diff <merge-base> ios-next -- <file>` is just the fork lagging — take upstream's.
- **Validate on a clean `upstream/master` worktree**: submodules need
  `git submodule update --init --recursive`, Apple Silicon configure needs
  `src/external/ffmpeg/macos/arm64` copied in, and `ios_regression_test.sh` must come
  from `ios-next` into the worktree's `scripts/` (it derives `REPO_ROOT` from its path).
  Red there isn't automatically a regression — featmgr feature 1012 and the akn icon
  server gate were never upstreamed, so the Calculator softkey checks fail.
- **CI sees what the local loop cannot**: Windows link requirements of vendored C
  libraries, case-sensitive filesystems, and sanitizer checks macOS disables. Budget a
  round or two. `gh` here resolves to upstream; the fork's iOS workflows need
  `-R yeatse/EKA2L1`.

## Code comments

- One or two lines, and only for what the code cannot say itself: a contract, a
  constraint, a consequence that is not obvious from reading on. Never restate what
  the statement below already says.
- No comment is the right answer for self-explanatory code. Don't narrate a rename,
  a parameter or an ordinary call.
- Long rationale — how the bug was found, what was ruled out, why the alternative
  was rejected — goes in the commit message, the PR description or `docs/`. Don't
  park it in the source.
- Don't write history into the code ("older builds did X", "this used to be Y").
  git and `docs/` already hold it.

## Documentation

- When you root-cause a non-trivial bug, write it up as its own English file in
  `docs/`: symptom, how you narrowed it down (including dead ends worth avoiding),
  conclusion/fix. Skip reproduction commands; no fixed template.
- Add a `| date | [title](./file.md) |` row to `docs/README.md`.
- `docs/IOS_PORTING_PLAN.md` and `docs/IOS_PORTING_TASKS.md` are archived history —
  don't add to them.
- For genuinely tricky fixes, put symptom / root cause / fix in the commit message
  (see `fedc6bc` for length and tone). Routine fixes don't need it.
