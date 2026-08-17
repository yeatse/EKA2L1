# A stability net for upstreaming this fork

This fork is roughly 300 commits ahead of upstream `master`, and the intent is to send
those changes back in batches. Most of them touch shared emulator code — kernel, IPC,
services, the interpreter — where a regression is invisible until somebody runs the one
application that used to work. Upstream currently has no automated way to notice that.

So the batches should not start with behaviour. They should start with the net that
catches a bad batch. That net is now in place: #583 brought CI back from the dead, #584
made it run the unit tests, #586 got the whole thing onto current toolchains and runner
images, and #585 fixed a startup crash found while checking that the macOS artifact opens. This document is the plan for that net: what exists, what PPSSPP
(the emulator project with the most mature regression story) actually does, why EKA2L1
cannot copy it verbatim, and the concrete order in which to build it.

## Where upstream stands today

- `.github/workflows/build.yml` does trigger on `push` and `pull_request` — and **it has
  been failing on every single run**, in a way that is easy to miss: each job dies in
  *Set up job*, before one step executes. GitHub hard-fails any workflow referencing
  `actions/upload-artifact` v1/v2 or `actions/cache` v1, and this one references both. Run
  31083801253 (master, 2026-08-06) is the last one, and every retained run before it, back
  to January 2026, failed too. Nothing has been built by CI for months, and PR
  authors have been looking at a red X that says nothing about their change.
  The rest of the workflow rotted alongside it: `actions/checkout@v2`, the removed
  `::set-output` syntax, the retired `ubuntu-20.04` image, `macos-latest` now being arm64
  (which open-source Qt 5.15.2 has no binaries for), signing and release actions pinned to
  Node versions Actions no longer runs, and a Windows OpenSSL download from a host that no
  longer resolves. "Turn CI back on" is really "rebuild CI".
  *(Note for anyone reading this in the fork: the fork's own copy was switched to
  `workflow_dispatch` so it would stop firing here. Upstream's is not.)*
- `EKA2L1_BUILD_TESTS` defaults to `ON` and `src/tests/CMakeLists.txt` registers
  `ekatests` with CTest — but the workflow builds only the `eka2l1_qt` target and never
  invokes `ctest`. The unit tests are configured, never built, never run.
- What that costs is already documented: see
  [Restoring the `ekatests` build](./ekatests-build-and-runtime-failures.md). Bringing the
  target back to life required fixing a link failure, a cross-build header collision, a
  stale call signature, and then **eight failing assertions that turned out to be three
  real bugs** in `bitmap_allocator`, `basic_pystr::as_int()`, and the directory iterator.
  Those are shipped bugs in shared code, found the moment a dormant test target was run.
- `src/intests` is already the right shape for guest-level regression testing: a Symbian
  test application plus a checked-in `expected/` tree covering Chunk, IPC, CodeSeg,
  EComServer, FbsBitmap, FbsFontStore, FileIO, WindowServer, CmdAndParams. But per its
  README the whole loop is manual — build the SIS, install it, run the app, read
  `DebugPrint` by eye. Nothing diffs it, nothing gates on it.
- There is no headless frontend. `src/emu` has `qt`, `android`, `ios` and nothing that a
  script can drive.
- Assets this fork can contribute immediately: `dyncom_difftest` (a host-only,
  ROM-free differential harness for the interpreter, driven by `scripts/cpu_difftest.sh`)
  and `scripts/ios_regression_test.sh` (screenshot assertions with pixel-difference
  thresholds against real guest applications).

## What PPSSPP actually does

Verified against the current tree, not from memory. `hrydgard/ppsspp`'s
`.github/workflows/build.yml` triggers on `push` (master and tags) **and
`pull_request`**, across a matrix of Ubuntu (clang and gcc), Android (arm64/arm32/x86_64,
plus VR and libretro), macOS, iOS, Windows (x64 and ARM64) and LoongArch. Every
configuration then runs up to three layers of tests:

1. **Unit tests** — `./PPSSPPUnitTest ALL`. Pure host-side logic, no emulation.
2. **Headless golden-output tests** — `python test.py -g --graphics=software`. `test.py`
   feeds ~300 `.prx`/`.elf` homebrew tests from the `pspautotests` submodule into
   `PPSSPPHeadless --root <path> --compare --timeout=5` over stdin; the emulator diffs the
   guest's own output against a checked-in `.expected` file per test. Tests are bucketed
   into `tests_good` (must pass, gates CI), `tests_next` (known-broken, informational) and
   `tests_ignored`. **Software rendering is the trick that makes this deterministic on CI
   machines with no GPU.**
3. **Frame-dump replay** — `frametests.py` replays recorded `.ppdmp` GE command streams
   through the headless binary, renders an image, and compares it to a checked-in
   reference by **mean squared error** against a `maxMse` tolerance, emitting an HTML
   report with the images and diffs.

Outside CI, PPSSPP closes the loop with user-side compatibility reporting
(report.ppsspp.org) and a per-title `compat.ini` of behaviour flags.

The load-bearing fact for us: **pspautotests is homebrew PPSSPP wrote itself and can
redistribute.** That is what lets guest-level tests live in public CI.

## The constraint that forces two tracks

EKA2L1 cannot run a single line of guest code without a Symbian ROM, and ROMs are
copyrighted. They cannot be committed, cached, or handed to a fork's pull request (which
by design gets no repository secrets). Any plan that puts guest tests in the public PR
path is dead on arrival.

Hence two tracks, with different triggers and different owners:

| | Track A — public CI | Track B — ROM-gated |
|---|---|---|
| Trigger | every push and pull request, forks included | maintainer-initiated / self-hosted |
| Needs | nothing but the checkout | a ROM, a mounted device, installed applications |
| Catches | build breakage, host-layer logic bugs, CPU semantic drift, memory errors | kernel, service, IPC and rendering regressions in real guest behaviour |

Track B **cannot** run on fork pull requests. That is a property of GitHub's secret model,
not a policy choice, and any proposal should say so up front so it is not mistaken for a
demand that every contributor own a ROM.

## Track A — four steps, each a standalone PR

### A0. Make the workflow run again

The triggers are already right; nothing about them needs changing. What needs changing is
everything the workflow depends on: actions bumped to v4, `::set-output` replaced with
`$GITHUB_OUTPUT`, retired runner images replaced (`ubuntu-24.04`, and `macos-15-intel` to
keep the x86_64 Qt 5.15.2 build that arm64 `macos-latest` cannot provide), the Windows
OpenSSL download dropped because the host serving it no longer resolves and Qt has no
replacement package, APK signing done inline with `apksigner` instead of an unmaintained
action — and, so that fork
pull requests are not red by construction, signing skipped with an unsigned APK uploaded
when the secrets are absent. `fail-fast: false` stays, so one platform's failure still
reports the others. Rolling releases stay restricted to a push on `master`.

No test steps are added here. The point is only to make "every PR has a signal" true again,
on infrastructure that still exists.

*Acceptance:* a green build on every matrix entry.

**Status: done and verified**, on branch `ci/modernize-build-workflow` (based on upstream
`master`, five commits). Four rounds on this fork's Actions were needed, because each fix
uncovered the next failure — worth recording, since it is what "CI has not run in months"
actually costs:

1. Deprecated actions replaced → jobs finally reach a step.
2. Linux missed `qtbase5-private-dev` (`displaywidget.cpp` includes the Qt private header
   `qpa/qplatformnativeinterface.h`); macOS could not configure because CMake 4 refuses
   capstone's `cmake_policy(SET CMP0048 OLD)`; `tools_openssl_x64` no longer exists.
3. CMake pinned to 3.31.6 and Windows moved to `windows-2022` — the vendored dependency
   tree cannot be configured by CMake 4 at all (capstone's policy, plus glm, fmt, spdlog
   and dynarmic declaring a minimum below 3.5), and CMake 3.31 predates the Visual Studio
   2026 that `windows-latest` switched to in June 2026.
4. macOS then failed to compile: the bundled boost uses `std::unary_function`, which
   libc++ no longer declares, and miniBAE's old C trips `-Wint-conversion` and
   `-Wimplicit-function-declaration`, errors by default since Clang 16.

The last two are the only source changes; everything else is workflow-only. All four jobs
are green and produce artifacts (run 31935443699 on this fork), and the Android job was
confirmed to take the unsigned path when no signing secret is present. The change went
upstream as PR 583, where the `pull_request` run is green on all four jobs and
`roll-release` correctly skips.

Two paths could not be exercised from a fork — the signing branch needs the secrets, and
`roll-release` only runs on a push to `master`. Both were settled when upstream merged the
PR: that push signed the APK with `apksigner` (build tools 37.0.0), moved the `continous`
tag to the merge commit, and refreshed all four release assets.

Two things are deliberately left for the maintainer to decide:

- **Windows has no TLS backend.** Qt retired `tools_openssl_x64` with OpenSSL 1.1, and
  Qt 5.15.2 cannot load the OpenSSL 3 package that replaced it, so the in-app updater
  cannot reach api.github.com. Shipping an unusable library instead would only hide it.
  The real fix is a Qt bump.
- **The CMake and Visual Studio pins are a holding action.** They should come off once the
  vendored submodules configure under CMake 4.

### A1. Fix `ekatests`, then run it in CI

Split the repair described in
[the ekatests write-up](./ekatests-build-and-runtime-failures.md) out of this fork as its
own PR: generated `configure.h`/`version.h` moved into each target's binary include
directory (so iOS, desktop and test build trees stop overwriting each other's feature
configuration), headless frontend stubs owned by the test target, the stale applist call
signature, and the three shared-code bug fixes the restored tests exposed. Then add
`--target ekatests` and `ctest --output-on-failure` to the workflow.

This is the highest-value single step in the plan, and it doubles as the argument for the
rest of it: the fixes *are* the evidence for what a dormant test target costs.

*Acceptance:* `ctest` green on all desktop platforms; a deliberately reverted bug fix
turns it red.

**Status: done and verified**, on branch `ci/ekatests-in-ci`, squashed into one commit
covering the build repair, the three shared-code bugs and the CI wiring. Ported onto upstream's tree by
building there and following the failures, not by cherry-picking the fork's commit; the
`as_int()` result is byte-identical to the fork's, and each headless stub was checked
against upstream's own declaration.

Both halves of the acceptance criterion hold: `ctest` reports `100% tests passed` on
Windows, macOS and Linux, and reverting only the allocator fix turns all three red with
`64 test cases | 60 passed | 4 failed`. That second run also answers a question the first
cannot — the suite really executes, rather than matching zero tests and exiting 0.

Two things the port surfaced that are not in the fork's commit:

- On Windows the test executable is not built next to the runtime DLLs the frontend build
  copies into `bin`, so `ctest` failed with `0xC0000135` until the test's `PATH` was
  pointed at them, and the fixtures are copied next to the executable, which on a
  multi-config generator is not where CTest runs from.
- The suite cannot be built on a current macOS toolchain at all: SDK 26 no longer declares
  `stat64`, which `fileutils.cpp` uses on every POSIX target. CI did not catch it because
  its image is older. Worth its own small PR.

Upstream merged A0 as PR 583, so this went out as a standalone PR rather than a stacked
one.

### A1b. Modernise the toolchain (unplanned, but it blocked everything else)

Not in the original plan: the pins #583 had to introduce — CMake 3.31, Visual Studio 2022,
an Intel macOS runner — were holding CI on retiring ground, and the tree did not build on a
current toolchain at all. Sent as #586: capstone/fmt/spdlog/glm bumped, the policy floor
relaxed for the vendored subtree instead of pinning CMake, Qt 6 (which the frontend already
supported, and which gives Windows its TLS backend back), all three runners on `latest`,
arm64 ffmpeg built from the submodule's own script, and Discord's Game SDK replaced with
discord-rpc so nothing prebuilt or network-fetched is left in a build.

Checking that the macOS artifact actually opens turned up four more: a signature invalidated
by the bundle fixups (Apple Silicon kills the process), the Qt platform plugin never copied
under Qt 6, an SDL2 framework copied in a way codesign rejects, and guest memory commits
failing on 16 KB host pages under W^X. A fifth, a null dispatcher when no device is
installed, was not architecture specific and went out separately as #585.

*Status: merged.*

### A2. Run the interpreter differential harness in CI

`dyncom_difftest` needs no ROM and no GPU, so it belongs in Track A as-is. Fixed-seed
short run on every PR (tens of seconds); long randomised run nightly, seed printed so a
failure is reproducible. Without this gate, none of the interpreter optimisations in this
fork (Thumb de-indirection, translation-time bulk-loop acceleration, the LDM/STM block
cursor) can be upstreamed responsibly.

*Acceptance:* the harness exits non-zero on the first divergence and the failing seed is
in the log.

### A3. A sanitiser job

One Linux clang build with `-fsanitize=address,undefined`, running `ekatests` and the
difftest. Heap overruns and use-after-free dominate this project's bug history — the
inflate tail-word overread that non-deterministically corrupted the host heap during
patch-DLL decompression was found exactly this way, under ASan.

*Acceptance:* the job is red on a known-bad commit and green on its fix.

### A4. Grow the unit tests with the batches, not separately

No coverage target. One rule instead: **every shared-code bug fixed in an upstreamed
batch gets a `src/tests` case that reproduces it.** Inflate tail-word reads, allocator
boundaries, region arithmetic, the INI tokenizer's quoted-comma handling, the
`lower_bound` hit that was never validated — all of these are testable with no ROM and no
device. This is also the most direct answer to "how do we trust a large machine-assisted
batch": each fix arrives with a test that fails without it.

## Track B — guest-level regression, gated on a ROM

### B1. A headless frontend

The prerequisite for everything else here: an `eka2l1_headless` target taking a ROM/device
and an application UID, rendering in software, with a timeout, a meaningful exit code and
optional screenshot output. The contract already exists in miniature — the stubs the
`ekatests` target grew (host UI operations fail cleanly instead of leaving an async
request pending) are exactly what a headless frontend must provide.

### B2. Automate `src/intests` — EKA2L1's `test.py`

The golden outputs are already checked in; what is missing is the driver. Install the SIS
through the headless binary, run the test application, capture `DebugPrint`, diff against
`expected/`, and summarise pass/fail/timeout — with PPSSPP's `good`/`next` bucketing so
known-unimplemented areas stay informational instead of blocking.

This is the closest analogue to what makes PPSSPP's net work, and it aims straight at the
area this fork changed most: IPC argument layout, descriptor slots, and service
completion/cancellation semantics. The built SIS should be committed as a binary artifact
— requiring every contributor to own a Symbian toolchain would make the suite unusable.

### B3. Screenshot regression with an MSE tolerance

A platform-neutral port of `scripts/ios_regression_test.sh`: boot an application headless,
sample frames on a schedule, compare against a reference image by mean squared error or
differing-pixel count. Two lessons from the iOS version are worth carrying over — a
freshly launched guest application needs on the order of 20 seconds before any assertion
is fair, and a single global threshold does not work (a full-screen transition and a
carousel page change differ by an order of magnitude in pixels touched). Reference images
contain no ROM material and can be public; *producing* them needs a ROM, which is why this
sits in Track B.

### B4. Where Track B runs

Two options, and the second costs upstream nothing:

- A self-hosted runner owned by the maintainer with ROMs resident, triggered on `push` and
  on labelled PRs only.
- **A shadow CI on this fork.** Track B runs here, and every upstream PR carries its
  results — the intests summary, screenshots, the relevant log excerpts — in the
  description. For a project with essentially one maintainer this is far more realistic
  than asking them to run each batch themselves, and it needs no upstream change at all.

## What has gone up so far

The graphics batch was started first, because its bugs sit in pure decoding functions and
so could carry the kind of test the rest of this document argues for.

| PR | What | Tests added | Fork commits it covers |
|---|---|---|---|
| #589 | MBM index bounds check, colour-key icon mask read as a stencil, lunasvg 3.5.0 | 8 (`fbs/bitmap`, `svg_icon`, `loader/mbm`) | `3f29c98d`, the mask half of the icon work, the lunasvg bump |
| #590 | Four NVG path decoding bugs: signed coordinates, close-path, relative dispatch, missing `VG_SCWARC_TO` | 5 (`loader/nvg`) | the decoder half of `9271a231`, all of `2a53883f`'s NVG half |

`ekatests` went from 203 assertions / 64 cases to **251 / 77** across the two.

Two habits came out of these that apply to every later batch:

- **Sweep the whole file, not the commit.** Picking `9271a231` apart gave three of the four
  NVG bugs; the fourth (`VG_SCWARC_TO` absent from the command table, so a small clockwise
  arc was skipped *without* consuming its five coordinates and every later segment read
  the wrong values) came from an earlier commit touching the same file. `git log
  master..ios -- <file>` before starting, then `git diff HEAD ios -- <file>` before opening
  the PR — an empty diff means the file is fully upstreamed and cannot conflict later.
- **Revert-verify each fix on its own.** Both PRs stated, per fix, which cases fail when
  only that fix is undone. This is what makes a test more than decoration, and it is cheap
  when the code under test is a pure function.

The remaining graphics work needs the FBS server and so cannot be tested this way: NVG
extended bitmaps blitted guest-side and skin item overrides (the other two thirds of
`9271a231`), the NVG colour plane (`15045245`), empty-redraw blanking (`f4bf86ab`), and
CJK linked fonts (`5679fd6c`, which already carries 528 lines of its own tests).

## What is left in the fork

Measured on 2026-08-17, with `master` at the merge of #586. The fork is 328 commits ahead
and 17 behind. **171 of those commits touch shared emulator code** — everything outside
`src/emu/ios`, the iOS workflows and the docs. Of those:

- 5 have already landed upstream in another shape: the `ekatests` repair (#584), the
  dependency bumps, the host-page `mprotect` alignment and the `PROT_EXEC` strip (#586,
  where the last two were rewritten to key off the host page size rather than the
  platform).
- 2 pairs cancel out — a dyncom translation cache and an EKA1 screen-mode change, each
  reverted in the fork.

**162 remain.** They are not equally sendable, and the useful split is by that rather than
by subsystem:

- **A — cross-platform fixes.** Nothing iOS about them; a Qt or Android user hits the same
  bug. These can be sent today. **91 commits.**
- **B — found on iOS, shared benefit.** Real fixes in shared code, but discovered through
  an iOS symptom, so each PR has to answer "is this a bug on Qt and Android too?" — often
  yes, sometimes the answer is that the iOS backend is the only caller that gets there.
  **29 commits.**
- **C — the iOS port's own plumbing in shared files.** EAGL and MetalANGLE contexts, the
  AudioUnit driver, CoreMotion and AVFoundation backends, the bundle resource layout, the
  `#if EKA2L1_IOS` branches in shared CMake. These only mean anything alongside the port
  itself, so they are not a queue to work through — they wait on whether upstream wants
  the iOS frontend at all, which is the maintainer's call. **42 commits.**

| Batch | A | B | C | Depends on | Verified by | Start with |
|---|---|---|---|---|---|---|
| Graphics, window server, fonts | 15 | 12 | 4 | — | Track B, per device | started — #589 and #590 landed; next is the FBS half of `9271a231` plus `15045245` |
| Kernel objects and lifetimes | 19 | 5 | 3 | — | `ekatests` + Track B | `e57f9e7e` IPC message refcount (full triage doc, reproducible crash) |
| Audio and video | 10 | 3 | 5 | — | Track B, audible checks | `92137f22` stop the hardware stream before freeing callback state |
| Interpreter performance | 18 | 0 | 0 | **A2** (`dyncom_difftest` in CI) | difftest + FPS measurements | `985fabb4` ASID-tagged instruction cache |
| Services and packaging | 13 | 2 | 3 | — | `src/intests` once B2 exists | `1af1eefb` SIS targets without a drive letter |
| Netplay | 8 | 0 | 4 | internal order (fixes stack on earlier work) | two-instance manual test | whole batch, in fork order |
| Memory model | 4 | 0 | 0 | — | `ekatests` + Track B | `51bbb0fd` fail chunk creation instead of returning a hollow chunk |
| Scripting patches | 3 | 0 | 1 | upstream's scripting build state | Track B | `1093f038` resolve ROM hooks by fingerprint |
| Camera | 0 | 3 | 1 | the iOS camera backend | device test | — (B/C only) |
| iOS port plumbing | 1 | 4 | 21 | **maintainer decision on the port** | — | — |

Three things the table does not say on its own:

- **Some commits have to be split.** `4a9f96d3` (fbs allocator race plus two teardown
  UAFs), `b1153e25` (a batch of TestFlight crashes), `061cc4d3` (four ThreadSanitizer
  races) and `2a53883f` (an NVG icon abort plus a memory-model UAF) each carry two or
  three unrelated root causes. One root cause per PR means unpicking them first, and the
  estimates above count commits, not PRs. `2a53883f` and `9271a231` have now been split
  this way — their NVG decoder halves went up as #590, and what is left of each is the
  memory-model UAF and the FBS-dependent icon work respectively.
- **The interpreter batch is the reason A2 matters.** Eighteen optimisations to the
  interpreter cannot be reviewed by reading them. The difftest harness is in the same
  batch (it was written alongside them) and should go first, as its own PR, so everything
  after it lands behind a gate.
- **The netplay batch is the one place order is load-bearing.** The later fixes assume the
  earlier ones; sending them out of order produces PRs that do not make sense on their own.

## How the batches themselves should be sent

1. **Infrastructure first**, in order: A0 → A1 → A2/A3 → B1. Every later behavioural batch
   then lands behind a gate that already exists. These PRs also carry no behavioural risk,
   which makes them the cheapest way to establish trust.
2. **iOS-only changes and shared-emulator changes never share a PR.** A shared-code PR must
   be able to explain why the bug is also a bug on Qt and Android.
3. **A checklist per PR**: Track A green; Track B shadow results attached; the affected
   application plus one known-good control application shown working; the log scanned for
   panics, access violations, graphics halts and leftover diagnostics.
4. **Stay bisectable** — one root cause per PR, no bundling. The per-bug documents in
   `docs/` are ready-made PR descriptions and materially reduce review cost.
5. **Open an issue before the PR** for anything that touches the maintainer's own ground —
   A0 (the workflow) and B1 (a new target) in particular.

## Deliberately out of scope

Worth doing eventually, wrong thing to attach to this plan:

- **Compatibility telemetry** in the style of report.ppsspp.org, with a per-title flag file
  like `compat.ini`. EKA2L1 has neither the per-application flag infrastructure nor a
  server, and it raises privacy questions that deserve their own discussion.
- **Frame-dump replay.** EKA2L1 has no GPU command-stream dump format, so this is a
  subsystem to design, not a checklist item — even though it is the most valuable long-term
  addition of the three.
- **Savestate versioning tests**, which should wait until the state format settles.

## Sequencing

| Step | Track | Can be PR'd as-is | Needs maintainer buy-in |
|---|---|---|---|
| A0 workflow repair (it fails at job set-up today) | A | yes | discuss first (their CI) |
| A1 `ekatests` repair + `ctest` in CI | A | yes | no |
| A2 `dyncom_difftest` in CI | A | yes | no |
| A3 ASan/UBSan job | A | yes | no |
| A4 regression tests alongside each batch | A | yes | no |
| B1 headless frontend | B | yes | discuss first (new target) |
| B2 intests driver + committed SIS | B | yes | no |
| B3 screenshot/MSE harness | B | yes | no |
| B4 self-hosted runner | B | no | required |
| B4′ shadow CI on this fork | B | n/a | none |
