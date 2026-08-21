# A ROM breakpoint kills the guest on dyncom, whatever the callback does

## Symptom

On the 5320 (rm-409), Calculator opened its Options menu fine but died the moment
the right softkey dismissed it:

```
KERN-EXEC 3 — Thread Calculator
```

The regression suite caught it as two failures (`RSK closes Options menu`,
`no guest crash`). The kernel log showed an undefined instruction rather than a
bad memory access:

```
cpsr=0x20000000, cpu->TFlag=0, r15=0x814F5124
Undefined instruction encountered in thread Calculator
Last instruction: ldmdavs r8!, {r1, r6, r7, fp, sp, lr}  (0x683868c2)
```

`0x683868c2` is not a plausible instruction for Avkon to be running. Split as
Thumb it is two perfectly ordinary ones — `ldr r2, [r0, #12]` and
`ldr r0, [r7, #0]`. So the memory was fine; the CPU was decoding Thumb code in
ARM mode, and `cpu->TFlag=0` says so outright.

## Narrowing it down

The failure had nothing to do with the Calculator. It was already failing before
the last upstream merge, so the first job was to find what actually turned it on.

Disabling the two `register_rom_export_breakpoint("eikcoctl.dll", 70, ...)`
entries in `builtin_patches.cpp` — the native mirror of
`s60v3_empty_avkon_menu_fix.lua` — turned the suite green. Re-enabling them
reproduced the crash every time.

The obvious next suspicion, that the patch callback jumps somewhere wrong, is
wrong. Two pieces of evidence:

- Replacing the callback body with a log line and nothing else — no register
  writes, no PC redirect — still crashed. Planting the hook is sufficient.
- That log line reported `r1 = 0x00000000` at the hook. The patch only acts when
  `(int32)R1 < 0`, so on this ROM it would never have done anything anyway.

The hook fired exactly once, at `0x814F511C`. The guest died at `0x814F5124`,
eight bytes later.

## Conclusion

The defect is in dyncom's `BKPT_INST` handler
(`src/emu/cpu/src/dyncom/arm_dyncom_interpreter.cpp`):

```c
cpu->RaiseException(exception_type_breakpoint, cpu->Reg[15]);
LOAD_NZCVT;
if (cpu->Reg[15] != pc) goto DISPATCH;
cpu->Reg[15] += cpu->GetInstructionSize();
```

Two things go wrong, and they compound:

1. `LOAD_NZCVT` reloads `TFlag` from `cpu->Cpsr`, but nothing flushed the live
   flags into `Cpsr` before raising the exception. The system call handler in the
   same file does exactly that (`SAVE_NZCVT;` immediately before
   `RaiseSystemCall`); the breakpoint handler does not. `TFlag` therefore comes
   back as 0 on a Thumb breakpoint, and `GetInstructionSize()` answers 4 instead
   of 2.

2. `handle_breakpoint` restores the original instruction and sets PC back to the
   breakpoint address so it can be re-executed by the single step in
   `epoc.cpp`. But that leaves `cpu->Reg[15] == pc`, so the `goto DISPATCH` is
   not taken and the fall-through advances PC *past* the instruction that was
   just restored.

Two mis-steps of 4 bytes each is the observed +8, in ARM mode, in Thumb code.

Note what this means: on dyncom, *any* breakpoint planted in Thumb code derails
the guest regardless of what the callback does. The ROM-export hook is simply the
first patch in this tree to plant one in a Thumb ROM export.

The workaround that made the suite green again drops the two eikcoctl hooks from
the native patch table only. `s60v3_empty_avkon_menu_fix.lua` is left in place:
desktop builds default to dynarmic, whose breakpoint path is separate and was not
tested here, so there is no evidence to justify removing it there.

## Dead ends worth avoiding

- Adding `SAVE_NZCVT;` before the `RaiseException` alone is not enough. It fixes
  the instruction-set half and changes the failure — the guest then dies further
  away with garbage registers — but the skipped-instruction half still derails
  execution. Both need fixing together.
- The `is_thumb` recovery already sitting in `scripts::handle_breakpoint`, which
  takes the mode bit from the registered hook address instead of trusting
  `get_cpsr()`, addresses the same stale-`Cpsr` problem for the *address* only.
  It does not help the resume, and its presence makes it easy to assume the mode
  question is already handled.
- Do not start from the patch table. The offsets (`0xF4` / `0x12C`), the export
  ordinal and the method hash are all fine, and the hash check means a hook that
  resolves at all resolved onto the right bytes.
