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
- Use the XcodeBuildMCP skill before calling XcodeBuildMCP tools.

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

The `Windows XP` VM has S60 3rd FP2 (`abld`) and Belle (`sbs`) plus the checkout
at `C:\eka2l1`; push every edited source, run the matching GCCE UREL command, poll
because `utmctl exec` returns early, then validate and install the E32Image (adjust
patch and target names as needed):

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

## Documentation

- When you root-cause a non-trivial bug, write it up as its own English file in
  `docs/`: symptom, how you narrowed it down (including dead ends worth avoiding),
  conclusion/fix. Skip reproduction commands; no fixed template.
- Add a `| date | [title](./file.md) |` row to `docs/README.md`.
- `docs/IOS_PORTING_PLAN.md` and `docs/IOS_PORTING_TASKS.md` are archived history —
  don't add to them.
- For genuinely tricky fixes, put symptom / root cause / fix in the commit message
  (see `fedc6bc` for length and tone). Routine fixes don't need it.
