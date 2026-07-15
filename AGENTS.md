# AGENTS.md

This repository is an iOS-focused fork of upstream EKA2L1. Agent work should preserve upstream emulator behavior while making the iOS port practical, testable, and debuggable.

## Priorities

- Treat iOS adaptation as the main project focus, but avoid broad rewrites of shared emulator code unless the bug is genuinely cross-platform.
- Prefer small, well-scoped fixes that keep Android, desktop Qt, and upstream architecture intact.
- Do not add app/game-specific hacks unless they are explicitly marked as a temporary diagnostic step. Final fixes should explain the general emulator behavior being corrected.
- Keep temporary logging, tracing, and debug probes out of final commits.

## iOS Workflow

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
- Build the simulator app with:

  ```sh
  ./scripts/build_ios.sh simulator
  ```

- Launch directly into a known app by UID when debugging. For example, open ZipManager with XcodeBuildMCP:

  ```sh
  xcodebuildmcp simulator launch-app --json '{
    "simulatorId": "booted",
    "bundleId": "com.eka2l1.emulator",
    "launchArgs": ["-LaunchAppUID", "0x2000023D"]
  }' --output json
  ```

- After launching an app, wait about 20 seconds before judging screenshots; Symbian services, window server, and first-frame rendering often need time to settle.
- For screenshots, get the booted simulator UDID, then use XcodeBuildMCP:

  ```sh
  SIM_ID=$(xcrun simctl list devices booted | sed -n 's/.*(\([A-F0-9-]*\)) (Booted).*/\1/p' | head -1)
  xcodebuildmcp simulator screenshot --simulator-id "$SIM_ID" --return-format path --output json
  ```

- For logs, prefer the emulator log inside the app container:

  ```sh
  APPDATA=$(xcrun simctl get_app_container booted com.eka2l1.emulator data)
  LOG="$APPDATA/Documents/data/EKA2L1.log"
  tail -200 "$LOG"
  ```

- Reset noisy runtime logging before final verification unless the task is specifically about diagnostics.
- Debugging should start from symptoms and logs, then narrow toward root cause. Avoid landing fixes that only mask one title.

### Symbian source-guided diagnosis

- For unclear IPC, ABI, descriptor-slot, panic, or service behavior, verify the contract from Symbian source before guessing. Search the local SDK/includes and OSS tree under `~/Developer/symbian` first; if the component is absent, use `gh search code` against `SymbianSource` repositories.
- Search by opcode/export/class/panic name, then read both client request construction and server completion/cancel paths. Treat argument types, slot numbers, ownership, and synchronous-vs-asynchronous cancellation in the original source as the compatibility target.
- Separate a bad guest request from a host lifetime race: validate guest pointers defensively, but also prove that stop/close/session teardown cannot race a queued host callback. Prefer fixing the general service/driver contract over title-specific behavior.

### TestFlight crash symbolication

- Record the app build, crash image load address, and EKA2L1 UUID from `.ips`/`.crash`. Map the build to a commit with `gh run list --workflow "iOS TestFlight"`, then download that run's `EKA2L1-testflight-dSYM-<sha>` artifact.
- Run `dwarfdump --uuid EKA2L1.app.dSYM` and require an exact UUID match before trusting symbols. Use `xcrun atos -arch arm64 -o <dSYM DWARF binary> -l <image load address> <addresses...>` when frames are not already symbolicated.
- Compare all reports from the same build before editing code; watchdogs often reveal a shared lock cycle, while random-looking main-thread crashes can be secondary heap corruption. Keep exported crash files and downloaded symbols out of commits.

### Physical device (devicectl)

The simulator runs on the build host, so it can hide device-only bugs (e.g. resources staged from `__FILE__`-relative paths). Verify device-facing fixes on real hardware. Known device: iPhone Air, UDID `77611A2B-2A02-51FA-BAFC-2104F1D8011A`.

```sh
UDID=77611A2B-2A02-51FA-BAFC-2104F1D8011A          # or: xcrun devicectl list devices

# Build + install (signing env required):
EKA2L1_IOS_DEVELOPMENT_TEAM=L6JP27B8YR EKA2L1_IOS_DEVICE=$UDID scripts/build_ios.sh install

# Launch directly into an app by UID (device must be UNLOCKED, else errors "Locked"):
xcrun devicectl device process launch --device $UDID --terminate-existing \
  com.eka2l1.emulator -LaunchAppUID 0x2000730F

# Pull the emulator log (retry: copy-from occasionally returns empty / "Connection reset"):
xcrun devicectl device copy from --device $UDID --domain-type appDataContainer \
  --domain-identifier com.eka2l1.emulator --source Documents/data/EKA2L1.log --destination /tmp/EKA2L1.log

# Inspect the sandbox file tree (e.g. confirm data/patch staged):
xcrun devicectl device info files --device $UDID --domain-type appDataContainer \
  --domain-identifier com.eka2l1.emulator | grep data/patch
```

- The device cannot be screenshotted via CLI — ask the user to confirm screen and sound visually.

## Verification

- For iOS changes, verify at least the affected app path plus a known-good control app when feasible.
- Run the regression script before concluding any emulator-affecting change. Regression MUST run against a **Release** build (`build_ios.sh` defaults to Debug, which lands in `Debug-iphonesimulator` — do not regression-test that artifact, and double-check you are not installing a stale app from the other configuration):

  ```sh
  # Build + install the Release simulator app first:
  EKA2L1_IOS_CONFIGURATION=Release scripts/build_ios.sh simulator
  scripts/ios_regression_test.sh --install build/ios-simulator/src/emu/ios/Release-iphonesimulator/EKA2L1.app
  scripts/ios_regression_test.sh                 # re-run without reinstalling
  ```

  It drives the booted simulator through Final Battle (must reach in-game with no `E32USER-CBase 46` stray-signal panic) and Calculator (default render, number input, left soft key opens the Options menu, right soft key closes it), asserts no guest crash, and saves per-state screenshots under `/tmp/eka2l1-regression`. A non-zero exit means a regression — investigate before landing. Requires a booted simulator with a device (e.g. 5320/rm-409) mounted and both apps installed, plus `xcodebuildmcp`, `jq`, ImageMagick (`magick`).
- For changes touching the input/touch path or Symbian^3 behavior, additionally run the touch-guest suite (needs the X7/rm-707 device with Angry Birds installed; taps the loading screen, then asserts the menu PLAY tap and carousel swipe still respond):

  ```sh
  scripts/ios_regression_test.sh angrybirds
  ```
- Inspect emulator logs for crashes, panics, access violations, graphics halts, and leftover temporary diagnostics.
- Visual success should be verified from screenshots or simulator state, not only from a successful process launch.
- If a previously passing app or flow stops working after a code change, treat it as a regression caused by that change first. Do not keep debugging the broken flow in isolation — revert or narrow the diff instead.

## Documentation

- `docs/IOS_PORTING_PLAN.md` and `docs/IOS_PORTING_TASKS.md` are archived planning history from the initial port; the port is largely done now, so don't add to them.
- When you root-cause a non-trivial bug, write it up as its own file in `docs/`, in English. Cover the key reasoning: symptom, how you narrowed it down (including dead ends worth avoiding next time), and the conclusion/fix. Skip step-by-step reproduction commands. No fixed template — structure it however fits the problem.
- Add an entry to `docs/README.md` (date, link, summary within ~100 words) for each new doc.
- For a commit that fixes a genuinely tricky bug, briefly describe the symptom, root cause, and fix in the commit message — see `fedc6bc` for the expected length and tone. Routine fixes don't need this treatment.
