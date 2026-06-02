# AGENTS.md

This repository is an iOS-focused fork of upstream EKA2L1. Agent work should
preserve upstream emulator behavior while making the iOS port practical,
testable, and debuggable.

## Priorities

- Treat iOS adaptation as the main project focus, but avoid broad rewrites of
  shared emulator code unless the bug is genuinely cross-platform.
- Prefer small, well-scoped fixes that keep Android, desktop Qt, and upstream
  architecture intact.
- Do not add app/game-specific hacks unless they are explicitly marked as a
  temporary diagnostic step. Final fixes should explain the general emulator
  behavior being corrected.
- Keep temporary logging, tracing, and debug probes out of final commits.

## iOS Workflow

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling
  XcodeBuildMCP tools.
- Build the simulator app with:

  ```sh
  ./scripts/build_ios.sh simulator
  ```

- Launch directly into a known app by UID when debugging. For example, open
  ZipManager with XcodeBuildMCP:

  ```sh
  xcodebuildmcp simulator launch-app --json '{
    "simulatorId": "booted",
    "bundleId": "com.eka2l1.emulator",
    "launchArgs": ["-LaunchAppUID", "0x2000023D"]
  }' --output json
  ```

- After launching an app, wait about 20 seconds before judging screenshots;
  Symbian services, window server, and first-frame rendering often need time to
  settle.
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

- Reset noisy runtime logging before final verification unless the task is
  specifically about diagnostics.

- Debugging should start from symptoms and logs, then narrow toward root cause. Avoid landing
  fixes that only mask one title.

## Verification

- For iOS changes, verify at least the affected app path plus a known-good
  control app when feasible.
- Inspect emulator logs for crashes, panics, access violations, graphics halts,
  and leftover temporary diagnostics.
- Visual success should be verified from screenshots or simulator state, not
  only from a successful process launch.

## Documentation

- Update `IOS_PORTING_TASKS.md` for meaningful iOS fixes, verification results,
  and known follow-ups.
- Keep documentation concise and outcome-focused. Avoid dumping low-level trace
  details unless they are necessary to reproduce or verify the issue.
- For lengthy investigation write-ups of complex problems, split each into its own
  topic file under `docs/`, and leave only a reference link plus a one-line core
  conclusion in `IOS_PORTING_TASKS.md`.
