# A stability net for upstreaming this fork

This fork carries several hundred commits' worth of change over upstream `master`, and the
intent is to send it back in batches. Most of it touches shared emulator code — kernel,
IPC, services, the interpreter — where a regression is invisible until somebody runs the
one application that used to work. Upstream had no automated way to notice that.

So the batches should not start with behaviour. They should start with the net that
catches a bad batch. That net is now in place: #583 brought CI back from the dead, #584
made it run the unit tests, #586 got the whole thing onto current toolchains and runner
images, #585 fixed a startup crash found while checking that the macOS artifact opens, and
#588 gave branch protection one stable check to require. This document is the plan for
that net: what exists, what PPSSPP (the emulator project with the most mature regression
story) actually does, why EKA2L1 cannot copy it verbatim, and the concrete order in which
to build it.

Two things have changed since the plan was written, and both are recorded in place below:
the net's first two rungs are built and merged, and **upstream accepted the iOS port
itself (#587, 17 Aug 2026)** — which was the open question the whole "iOS plumbing" batch
was waiting on. See [What is left in the fork](#what-is-left-in-the-fork), remeasured on
21 Aug 2026, after #605 and #606 closed out the interpreter and the graphics batches.

## Where upstream stands today

*This section describes upstream as of 16 Aug 2026, before A0 landed. It is kept as the
starting position the rest of the document is measured against; the per-step statuses say
what has since changed.*

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
  its image is older. *Since fixed upstream — `fileutils.cpp` now maps `stat64` onto
  `stat` on Apple targets, and `ekatests` builds and passes on a current macOS SDK.*

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

**Status: merged (#604).** It did not go out on its own in the end: the harness, the CI job
and the interpreter batch it gates travelled together, because the batch is the only thing
that makes the harness's coverage arguable and the harness is the only thing that makes the
batch reviewable. The job is `dyncom-difftest` on `ubuntu-latest`, running
`./scripts/cpu_difftest.sh 1 20000` and feeding the `ci` aggregate check, so branch
protection covers it alongside the build jobs. The harness itself grew during review from a
self-A/B plus a golden ALU oracle into two phases: 20000 single-instruction cases against
the golden model, then 544 whole programs against **dynarmic** as an independent oracle,
with coverage counters that assert the loop accelerator and the VFP host-fast path were
actually exercised rather than silently skipped. The nightly long randomised run is still
not wired up.

### A3. A sanitiser job

One Linux clang build with `-fsanitize=address,undefined`, running `ekatests` and the
difftest. Heap overruns and use-after-free dominate this project's bug history — the
inflate tail-word overread that non-deterministically corrupted the host heap during
patch-DLL decompression was found exactly this way, under ASan.

*Acceptance:* the job is red on a known-bad commit and green on its fix.

**Status: not started, and now the last unbuilt rung of Track A.** Cheap next to A2 and
independent of it — one job on an existing workflow, no new target. The argument stopped
being hypothetical while #599 was being prepared: running the existing suite under ASan for
the first time turned up an uninitialised-member defect that reproduces on upstream's own
tree (see
[Sending the first behavioural batch](#sending-the-first-behavioural-batch)). The suite it
would run already exists and already passes under the sanitiser, and #604 added a second
host-only, ROM-free suite the same job can cover: `dyncom_difftest`.

### A4. Grow the unit tests with the batches, not separately

No coverage target. One rule instead: **every shared-code bug fixed in an upstreamed
batch gets a `src/tests` case that reproduces it.** Inflate tail-word reads, allocator
boundaries, region arithmetic, the INI tokenizer's quoted-comma handling, the
`lower_bound` hit that was never validated — all of these are testable with no ROM and no
device. This is also the most direct answer to "how do we trust a large machine-assisted
batch": each fix arrives with a test that fails without it.

**Status: in force, and it is holding.** Every graphics batch sent so far carried its
tests: `loader/nvg.cpp` and `services/ui/skin/skn.cpp` with #589/#591, `loader/svgb.cpp`
with #593, `loader/gdr.cpp` and `services/fbs/linkedfont.cpp` with #594. Upstream's
`src/tests/epoc` now holds 19 test files against the fork's 23, and the rule cost nothing
to follow — the fixtures were synthesised, not extracted from a ROM.

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

## What is left in the fork

Remeasured on 2026-08-21, with `master` at the merge of #606. **The earlier count — 162
commits split 91/29/42 — is superseded, and not by arithmetic.** Twenty-three PRs landed
between 16 and 21 August, and none of them was a cherry-pick: each was rebuilt on
upstream's tree and reviewed there, so a fork commit's content can be fully upstream while
the commit itself still shows as "ahead". Commit counts stopped being a valid unit of
measurement the moment that started happening. What follows is measured with
`git diff master...ios-next` — by file and by line, which is what actually still differs.
`docs/` and `src/emu/qt/translations/` are excluded throughout.

Five things closed out entirely:

- **The memory model batch is upstream (#599).** Chunk creation, chunk lifetime across
  processes and CPU TLB invalidation, plus a defect that predated the fork. `src/emu/mem`
  is now identical to upstream.
- **The interpreter is upstream (#604, #605)** — and with it A2, since #604 carried the
  `dyncom-difftest` CI job as well as the harness, and #605 then went out behind that gate
  with the three remaining defects (a null addressing function that used to be called, an
  undecodable ARM instruction indexing the translate table with an uninitialised value, and
  Thumb `BKPT` translated as `SVC`). `src/emu/cpu` is now identical to upstream.
- **Audio is upstream (#602, #603).** Stream lifetime, notification delivery, realtime-thread
  safety, and the intro-movie stutter. What is left of "audio and video" is two video files
  that belong to the dispatch/drivers rows.
- **The iOS port is upstream (#587).** `src/emu/ios` differs by 4 files and +69/-7 — the
  font-import and netplay changes made after the PR was cut.
- **Graphics, the window server and the font store are upstream.** #589 (icon decode),
  #590 (NVG path decoding), #591 (Symbian^3 skin overrides and NVG rasterisation),
  #593 (SVGB text), #594 (CJK linked typefaces and imported fonts), #597 (the icon mask
  contract) and finally #606 — window-server redraw and DSA rescale, the FBS font store,
  the screen driver, the AknIconServer contract and the `scdv` patch DLL's C++ source.
  `src/emu/services/src/{window,fbs,ui}` are now identical to upstream. What is still
  graphics work below lives in `dispatch` and `drivers`, which are separate rows.

What remains, by area:

| Area | Files | Lines | Depends on | Verified by | Start with |
|---|---|---|---|---|---|
| Services (non-graphics, non-netplay) | 30 | +1450/-75 | — | `src/intests` once B2 exists | `timezone.cpp` (+666) — the `!TzServer` HLE, with a doc |
| Kernel objects and lifetimes | 21 | +862/-162 | three commits must be unpicked first | `ekatests` + Track B | `e57f9e7e` IPC message refcount (full triage doc, reproducible crash) |
| Netplay and Bluetooth | 21 | +787/-91 | internal order (fixes stack on earlier work) | two-instance manual test | whole batch, in fork order |
| Common, vfs, utils, system, config | 25 | +526/-74 | — | `ekatests` | `flate.cpp` (+18) — the inflate tail-word overread; needs a test written for it (A4) |
| Scripting patches | 7 | +448/-63 | upstream's scripting build state | Track B | `1093f038` resolve ROM hooks by fingerprint |
| Package | 6 | +439/-148 | — | `ekatests` (SIS fixtures exist) | `1af1eefb` SIS targets without a drive letter |
| Patch DLLs | 5 | +342/-0 | a Symbian toolchain to rebuild the binaries | Track B | — |
| Dispatch / GLES HLE | 16 | +289/-33 | — | Track B, per device | — |
| Drivers (graphics and camera backends) | 15 | +247/-15 | — | Track B, per device | — |
| iOS frontend | 4 | +69/-7 | — | device build | whole remainder, one PR |
| Qt / Android frontends | 4 | +23/-65 | — | desktop run | — |
| Graphics, window server, fonts | 0 | — | — | — | **done** (#589–#597, #606) |
| Interpreter (dyncom) | 0 | — | — | — | **done** (#604, #605) |

The netplay row counts `services/{bluetooth,socket,internet}` plus the Bluetooth notifier;
the services row is everything else under `src/emu/services`. Earlier measures split those
two differently, so compare their sum (51 files, +2237/-166) rather than either row.

Three areas are deliberately not rows above, because none of them is a batch:

- **`src/tests`** — 19 files, +873 lines. Under A4 each case travels with the batch whose
  bug it reproduces, so this is not a PR of its own. It is also the one number that should
  *shrink to zero* as a side effect of everything else going out.
- **Build, CI, scripts and top-level files** — 19 files, +2447 lines, and almost all of it
  is iOS-specific infrastructure that lives in this fork by design: the TestFlight and
  signing workflows, `ios_regression_test.sh`, the MetalANGLE fetch, `AGENTS.md`. Only the
  parts upstream would actually run belong in a PR.
- **`docs/`** — 120 files of per-bug write-ups, which are PR material rather than a batch.

Three things the table does not say on its own:

- **Two areas have now reached zero, and both did it the same way.** `src/emu/cpu` went
  out as #604 (the optimisations, carrying A2) and #605 (the three defects the
  optimisation PR deliberately left behind), each behind the gate the previous PR had
  installed. Graphics went out as seven PRs over six days, ending with #606. The pattern
  worth repeating: send the gate first, then send the behaviour that the gate covers, and
  keep bug fixes out of a PR whose subject is performance.
  Writing #605's cases turned up a defect in the harness itself: without scripting
  enabled `COND_CHECK` does not guard `log::filterings`, so any path under test that
  logs took the harness down — which is why nothing had ever reached those paths.
- **Some commits have to be split.** `b1153e25` (a batch of TestFlight crashes) and
  `061cc4d3` (four ThreadSanitizer races) each carry several unrelated root causes, and
  both sit in the kernel row. One root cause per PR means unpicking them first, so the
  file counts above are not PR counts either. Two other split candidates —
  `4a9f96d3` (fbs allocator race plus two teardown UAFs) and `2a53883f` (an NVG icon
  abort plus a memory-model UAF) — have had their graphics and memory-model halves
  upstreamed already, so what is left of them is kernel-only and no longer needs
  splitting.
- **The netplay batch is the one place order is load-bearing.** The later fixes assume the
  earlier ones; sending them out of order produces PRs that do not make sense on their own.

## Sending the first behavioural batch

The memory model went out as #599 and merged the same day. It is the only behavioural
batch sent so far, so what it cost is the best estimate available for the ones after it.

**It was sent as one PR, not one per root cause.** Five defects, all on the subject of who
owns a chunk struct and when the CPU may still hold a translation into it. Rule 4 below
still stands as the default, but two of the five could not have been separated: releasing
a chunk slot on failure moves a destructor to the moment of failure, which changes when a
second, pre-existing defect fires. Bundling was the honest choice there, and saying so in
the PR body cost nothing.

**Porting was by rebuild, not cherry-pick.** Branch from upstream, apply each commit's
hunks, and check the result with `git diff ios-next` — the remainder should be only what
was deliberately left behind (here, one interpreter commit that happened to touch
`mem/src/mmu.cpp`). That check is what makes "the branch matches the fork's final state"
an assertion rather than a hope.

**Running the suite under ASan for the first time found a defect on upstream's tree.**
`multiple_mem_model_chunk` initialised none of its members, while its destructor opens
with `decommit(0, max_size_)` — so a chunk whose creation failed walked a page table array
with a garbage size. It reproduces on an unmodified tree, and it had been sitting behind
the fact that nothing ever ran these tests under a sanitiser. Two lessons:

- **A3 is not a nice-to-have.** One ASan run on an existing test suite produced a
  reproducible SEGV in shared code. That is the whole argument for the job, made in a
  single afternoon.
- **Reviewing your own batch before sending it pays.** The same pass found two dead
  branches in the fork's own fix — a loop guard defending against a case that cannot reach
  it, and a hand-off of a field (`flexible_mem_model_chunk::owner_`) that nothing in the
  tree ever reads.

**"Not testable without a ROM" deserves one attempt before it is asserted.** The batch's
lifetime fixes looked device-only and were described that way in the first draft of the PR.
They are not: two mem-model processes, one attaching to the other's global chunk, is enough
to reproduce the use-after-free — silently on an ordinary build, precisely under ASan. The
TLB half really does need a device, and that distinction is worth drawing per fix rather
than per batch.

## How the batches themselves should be sent

1. **Infrastructure first**, in order: A0 → A1 → A2/A3 → B1. Every later behavioural batch
   then lands behind a gate that already exists. These PRs also carry no behavioural risk,
   which makes them the cheapest way to establish trust. *A0, A1, A1b and A2 are done; A3
   is the next one, and nothing is blocked on it.*
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

| Step | Track | Status | Can be PR'd as-is | Needs maintainer buy-in |
|---|---|---|---|---|
| A0 workflow repair | A | **merged** (#583) | — | discussed first (their CI) |
| A1 `ekatests` repair + `ctest` in CI | A | **merged** (#584) | — | no |
| A1b toolchain modernisation (unplanned) | A | **merged** (#586, #585) | — | no |
| A2 `dyncom_difftest` in CI | A | **merged** (#604, with the interpreter batch) | — | no |
| A3 ASan/UBSan job | A | **next up** (**found a real bug in a trial run**) | yes | no |
| A4 regression tests alongside each batch | A | **in force** since #589 | yes | no |
| B1 headless frontend | B | not started | yes | discuss first (new target) |
| B2 intests driver + committed SIS | B | not started | yes | no |
| B3 screenshot/MSE harness | B | not started | yes | no |
| B4 self-hosted runner | B | not started | no | required |
| B4′ shadow CI on this fork | B | not started | n/a | none |

Outside the plan, the port itself went out and was accepted: #587 (the iOS frontend), #592
and #596 (its CI job), plus #588, which gave upstream one stable required check for branch
protection. Behavioural batches landed so far: #599 (memory model), #600 (the central
repository INI reader), #601 (the domain manager), #602 and #603 (audio and video), and
#604 and #605 (the interpreter, the first of which carried A2 with it), and #606
(the window server, the font store and the screen driver).
