# dyncom interpreter — deep optimization plan

Follow-up to [`ios_snakes_perf.md`](./ios_snakes_perf.md). After the ASID
instruction-cache fix and the simulator render-scale cap, Snakes gameplay is
**CPU-bound on the dyncom interpreter** (guest os_thread ~99% in
`InterpreterMainLoop`, graphics thread ~80% idle). This plan targets the
interpreter itself.

## Constraints (non-negotiable)
- **No JIT.** iOS forbids W^X / JIT for this app, so dynarmic and 12L1R are out
  of scope here regardless of the A32 bug. This is purely about making the
  *interpreter* faster. (JIT is therefore NOT the ceiling-breaker it would be on
  other platforms — the interpreter is what ships.)
- **Cross-platform.** dyncom is shared with Android and desktop. No iOS-only
  forks of the interpreter; changes must keep all frontends correct.
- **Correctness first.** A wrong translation = silent guest corruption across
  every app. Every stage gates on `scripts/ios_regression_test.sh` (8/8) + a
  differential/fuzz check (below) before landing.

## Baseline hotspot map (Snakes gameplay, `sample` 6 s, os_thread = 3746)
| share | bucket | detail |
|---|---|---|
| ~78% | ARM interpretation | dispatch + inline handlers (~2115), `AddWithCarry` 123, `DataProcessingOperands*` ~290, addressing/`LdnStM*` ~320, `CondPassed` 61 |
| ~12% | guest memory | `ReadMemory32` 161 / `WriteMemory32` 112 / `ReadCode` 90 / `WriteMemory8` 35 + mmu page-walk lambda 64 |
| ~9.5% | present `wait_for` | not dyncom — the reverted double-buffer's target |

## How the interpreter works today (for grounding)
- Basic blocks are decoded once into a "cream" stream (`arm_inst` header +
  per-op struct) in a 128 MB bump buffer, cached by `(asid<<32)|vpc`
  (`instruction_cache`, after the recent fix).
- Execution is a computed-goto threaded dispatch (`GOTO_NEXT_INST` → label
  table). Each handler reads its pre-decoded cream, executes, `INC_PC`,
  `FETCH_INST`.
- **Every taken branch ends the block with `goto DISPATCH`**, which does a
  `std::unordered_map<u64,size_t>::find()` to locate the target block. There is
  **no block linking** — every branch pays a hash lookup.
- Data-processing ops compute their shifter operand through an indirect call
  `inst_cream->shtop_func(...)`.
- Data load/store use a 512-entry direct-mapped TLB fast path
  (`tlb::lookup`, `armstate.cpp`); **`ReadCode` bypasses it** and page-walks.

## Staged plan (ordered by impact ÷ risk)

### Stage 1 — memory fast-paths (low risk, ~3-5%)
- **1a. `ReadCode` via TLB.** `tlb_entry` already carries an unused
  `execute_addr` slot populated with `prot_exec`. Add a `lookup_exec()` and use
  it in `ARMul_State::ReadCode` (armstate.cpp:264) instead of always calling
  `read_code`. Fetches that hit a warm code page skip the page-directory walk.
- **1b. Inline the load/store fast path.** `ReadMemory32`/`WriteMemory32` are
  out-of-line calls invoked from every LDR/STR/LDM/STM handler; each re-fetches
  `core->mem_cache()` and the `InBigEndianMode()` branch. Inline a
  `tlb_read32/tlb_write32` fast path (lookup → deref) at the handler sites,
  falling back to the existing function on miss. Removes call overhead on the
  hottest accessors. Keep the big-endian path in the slow fallback (guest is LE).
- Risk: low. TLB semantics unchanged; only adds a hit path. Verify the exec
  lookup respects `make_dirty`/`flush` exactly like read/write.

### Stage 2 — block chaining (medium risk, the big structural win)
Eliminate the per-branch hash lookup. When `DISPATCH` resolves a branch target
to `ptr`, cache it on the originating branch so the next execution jumps
directly.
- Add to `arm_inst` (or the branch creams `bbl_inst`/`bx_inst`/…): a
  `std::size_t linked_block` + `std::uint32_t linked_vpc` + a
  `std::uint32_t link_generation`.
- In `DISPATCH`, after computing the target key, if the *incoming* branch's
  `linked_generation == current_generation` and `linked_vpc == Reg[15]`, set
  `ptr = linked_block` and skip the `find()`. Otherwise do the lookup and record
  the link.
- **Invalidation via a generation counter:** bump `cache_generation` on every
  full flush (overflow reset, `imb_range`, embedded-interpreter
  `clear_instruction_cache`). Any link with a stale generation is ignored →
  re-resolved. This makes chaining correct across SMC, DLL reload, buffer
  overflow, and the embedded-fallback clears, without walking/patching links.
- Indirect/return branches (`INDIRECT_BRANCH`, `bx`, `ldm pc`) have a dynamic
  target → cache only helps when the target repeats (e.g. tight loops, hot
  callees). Store last-target + verify `linked_vpc == Reg[15]` so a changed
  target just falls back to `find()`. Direct branches (`DIRECT_BRANCH`) have a
  fixed target → always chain after first resolve.
- Expected: branches are very frequent in a tight game loop; removing the hash
  probe per taken branch is the single largest interpreter-internal win.
- Risk: medium — correctness hinges entirely on the generation counter covering
  every cache-mutation path. Heavy tests on SMC / process-switch / overflow.

### Stage 3 — ALU/flag micro-opts (low-medium risk, ~3-5%)
- **3a. `AddWithCarry`** (123 samples): replace the manual carry/overflow bit
  math with `__builtin_add_overflow` / `__builtin_sub_overflow` (clang/gcc
  intrinsics, both supported) for carry+overflow in one op. Mechanical, easy to
  differential-test against the old implementation exhaustively.
- **3b. (defer) Lazy NZCV flags.** Storing result+operands and computing flags
  only when a conditional reads them is the classic interpreter win but is a
  large, error-prone rework of flag semantics (MSR/MRS, SPSR, shifter carry).
  High risk; revisit only if Stage 1-3a aren't enough.

### Stage 4 — shifter-operand specialization (medium, optional)
The `shtop_func` indirect call per data-processing instruction defeats branch
prediction. Specialize the common handlers (immediate, LSL-by-imm, register)
into dedicated labels that inline the shift, leaving the indirect path only for
rare register-specified shifts. Medium gain, adds handler labels.

### Stage 5 — instruction fusion / superinstructions (medium-high, structural)
Since JIT is off the table, the way to attack the ~78% dispatch share (beyond
block chaining) is to **execute more work per dispatch**. At translation time
(`InterpreterTranslateBlock`) detect common adjacent patterns and emit one fused
cream + handler, halving the `GOTO_NEXT_INST`/`FETCH_INST`/`INC_PC` overhead for
that pair. High-value candidates for the Symbian (ARMv5/v6 + Thumb) guest:
- `CMP/SUBS Rn,#imm` + conditional `B` → fused compare-and-branch (the dominant
  loop/condition idiom).
- `SUBS Rn,#1` + `BNE` → loop-counter decrement-and-branch.
- address-calc + access: `ADD Rd,Rn,#imm` (or shifted reg) immediately consumed
  by `LDR/STR [Rd]`.
- back-to-back `LDR`/`STR` and `MOV`+use pairs.
- Thumb 16-bit pairs benefit most (dispatch cost is a larger fraction there).

Rules: only fuse *within* a basic block; never fuse if the first op's flags are
consumed by something other than the fused branch, or if the `S` bit makes the
intermediate state observable; a jump that lands on the second op's PC simply
misses the (start-PC-keyed) cache and re-translates a fresh block from there, so
fusion can't be entered mid-pair → no correctness hazard. Start with the two
compare/sub-and-branch fusions (biggest, cleanest), measure, then widen.
- Risk: medium-high — fused flag/branch semantics must exactly match running the
  two ops separately; lean hard on the differential/fuzz harness.

## Realistic ceiling (no JIT)
Stages 1-5 target the ~12% memory + the ~78% dispatch (block chaining + fusion)
+ ~5% ALU. The interpreter dispatch+execute is the hard floor, but chaining and
fusion meaningfully shrink the dispatch share. A plausible net is **~20-30% CPU
reduction** → Snakes ~30 → ~38-45 FPS on the simulator, with more headroom on
device (no software-blit tax). Diminishing returns past that — the interpreter
is the product, so squeeze dispatch (Stages 2 + 5) hardest.

## Verification strategy (per stage)
1. `scripts/ios_regression_test.sh` → 8/8 (Final Battle 90 s in-game +
   Calculator input/menus, no guest panic).
2. Re-`sample` Snakes gameplay; confirm the targeted hotspot actually dropped
   and nothing new appeared.
3. **Differential correctness** for the risky stages (2, 3): reuse the existing
   CPU test harness (`src/emu/cpu/src/12l1r/tests/`, `src/tests/`) and/or the
   12L1R fuzz path (`FLAG_ENABLE_FUZZ` runs interpreter alongside JIT and
   compares state) to diff old-vs-new interpreter register/memory/flag state
   over randomized instruction streams — with explicit cases for SMC,
   cross-page branches, process switches, and cache overflow (the block-chaining
   invalidation paths).
4. Land stages independently (each its own commit) so any regression bisects
   cleanly; keep block chaining behind a compile/runtime switch until proven.

## Suggested order
1 → 3a (quick, safe, bankable) → 2 block chaining → 5 instruction fusion (the two
dispatch-share wins, with the test harness in place) → 4 shifter specialization
(if still short).

## Status (2026-06-14)
Landed and committed: **Stage 1a** (ReadCode via TLB), **Stage 3a** (inline
AddWithCarry), **Stage 2** (direct-mapped L1 in front of the block map). Snakes
gameplay went from a steady ~30-32 to a steady ~34 FPS; regression 8/8 throughout.
ReadCode self-time dropped ~90→~22 and AddWithCarry left the profile; the block-L1
gain was within noise (the per-block lookup was already amortised) but is correct
and not harmful.

**Stage 5 (instruction fusion) deliberately not done.** Assessment: it only
removes per-pair *dispatch* overhead (not the CMP/branch execution), so ~3-5%;
retrofitting look-ahead matching into dyncom's one-instruction-at-a-time
translation pipeline + a synthesized dispatch-table entry is invasive and
correctness is only verifiable here via the regression script (no interpreter
differential harness). Risk/reward judged unfavourable — banked stages 1-3
instead. If revisited, build a differential interpreter test harness first
(Stage 5 verification note above). **Stage 4 (shifter specialization)** likewise
deferred. No JIT (iOS W^X) — the interpreter is the product, so further gains
need the fusion/specialization work behind a proper test harness.
