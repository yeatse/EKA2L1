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

For unclear IPC, ABI, descriptor, panic, or service behavior, consult
`~/Developer/symbian` first, then `gh search code` in `SymbianSource` repositories.
Read both client request construction and server completion/cancellation for slot
numbers, types, ownership, and sync/async semantics. For suspected lifetime bugs,
check guest pointer validity and stop/close/session teardown against queued callbacks.

### Symbian patch DLL builds in UTM

Use `/Applications/UTM.app/Contents/MacOS/utmctl` with the `Windows XP` VM and
checkout `C:\eka2l1`. When changing patch sources:

- Push all edited sources, including `src/patch/priv`; build `priv` first with the
  same SDK/platform. Rebuild every variant that shares the changed source.
- Select the SDK from each variant's `group/target.inf`. EKA1 `_v81a` uses S60 2nd
  FP3 and `abld build armi urel`; GCCE variants use `abld build gcce urel` after
  `bldmake bldfiles`. Belle uses `sbs -b bld.inf -c armv5_urel_gcce4_4_1`.
- S60 5th GCCE needs `C:\PROGRA~1\CSL Arm Toolchain\bin` on PATH. Belle needs its
  SDK's `EPOCROOT`, SBS tools, and CodeSourcery toolchain.
- `utmctl exec` returns before the build finishes: clear any old result marker,
  poll for completion, and inspect the build log before pulling the UREL DLL.
- Validate with `~/Developer/symbian/symbian-dll-agent-kit/tools/verify_e32.py`
  before replacing the checked-in DLL. Its ARMv5 CPU check does not apply to EKA1;
  compare those headers with the existing binary instead.

### TestFlight crash symbolication

Find the build's commit and `EKA2L1-testflight-dSYM-<sha>` artifact with
`gh run list -R yeatse/EKA2L1 --workflow "iOS TestFlight"`. Require an exact
`dwarfdump --uuid` match before using `xcrun atos -arch arm64 -o <DWARF binary>
-l <image load address>`. Compare available reports from the same build before
settling on a cause. Keep crash reports and downloaded symbols out of commits.

### Physical device

For behavior the simulator cannot validate, use iPhone Air, UDID
`77611A2B-2A02-51FA-BAFC-2104F1D8011A`, team `L6JP27B8YR`, with
`EKA2L1_IOS_DEVELOPMENT_TEAM` and `EKA2L1_IOS_DEVICE` for
`scripts/build_ios.sh install`. The device must be unlocked. Retry empty or
connection-reset `devicectl device copy from` results. If screen or sound cannot
be checked through available tools, ask the user to confirm them.

## Verification

Size verification to the change. Documentation-only changes need a diff review,
not an emulator build. For emulator behavior changes, run the default regression
suite once against the final **Release** simulator build:

```sh
scripts/ios_regression_test.sh --install build/ios-simulator/src/emu/ios/Release-iphonesimulator/EKA2L1.app
```

Add `scripts/ios_regression_test.sh angrybirds` for input/touch or Symbian^3 changes.
See the script header for other suites and prerequisites; screenshots land in
`/tmp/eka2l1-regression`. Cover the affected app path and a known-good control,
reusing suite coverage where it overlaps. Confirm the result visually and scan the
log for panics, access violations, graphics halts, and leftover diagnostics.

Reuse passing results for the same change across `ios-next` and upstream PR
preparation. Repeat only affected checks when subsequent code changes, conflict
resolution, relevant base differences, or failures invalidate those results;
changing branches alone is not a reason to rebuild or rerun the suite. Record the
tested revision/configuration and results in the commit or PR. Investigate failures
before landing; report unrelated pre-existing issues without expanding the fix.

## Upstream contributions

- Develop and validate on the fork, PR against `EKA2L1/EKA2L1:master`, then sync the
  fork's `master` and merge it into `ios-next`. No second fork-internal PR for the
  same changes.
- Inspect the current upstream diff and select only relevant hunks; fork commits
  and whole files can contain unrelated changes. Keep fork-only docs out of the
  upstream PR; put the rationale in the commit message or PR description.
- Reuse the fork's verification as described above. Do not require a second full
  simulator run on an upstream worktree or revert each fix just to produce a PR
  table. Add targeted checks only for a concrete gap in coverage; use upstream CI
  for platform-specific build and test coverage.
- When adding tests, derive expected behavior from SDK/OSS contracts. Run
  `ekatests` from its build directory so relative assets resolve, and check that
  the run completed rather than trusting a partial summary after a fatal signal.
- Review generated translation diffs after Qt builds; discard only build-generated
  changes, preserving pre-existing edits.
- Specify the repository in `gh` commands: `-R EKA2L1/EKA2L1` for upstream,
  `-R yeatse/EKA2L1` for fork workflows.

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

- Default to the commit message for small crash fixes, routine bug fixes, and
  small features; do not create a separate document for them. Write an English
  file in `docs/` only when a complex investigation or design has lasting value
  beyond the commit: symptom, useful diagnostic findings, and conclusion/fix.
  Skip reproduction commands; no fixed template.
- When adding a document, add a `| date | [title](./file.md) |` row to `docs/README.md`.
- `docs/IOS_PORTING_PLAN.md` and `docs/IOS_PORTING_TASKS.md` are archived history —
  don't add to them.
- For genuinely tricky fixes, put symptom / root cause / fix in the commit message
  (see `fedc6bc` for length and tone). Routine fixes don't need it.
