# Native-only scripting patches on iOS

## Problem

Upstream EKA2L1 ships a handful of per-game/OS compatibility patches as Lua
scripts under `src/scripts/*.lua` (AstroQuest, Eternal Legacy, Hero of Sparta,
Warhammer 40K, and an S^3 ROM-DLL preload). The iOS port disabled the whole
scripting subsystem (`EKA2L1_ENABLE_SCRIPTING_ABILITY OFF`), so none of those
fixes applied on iOS.

The blocker is the scripting runtime, not the engine. The Lua API layer is a thin
shell over **LuaJIT FFI**: every module calls C exports through `ffi.C.*`, and the
event hooks pass a Lua closure *as a C function pointer* (`breakpoint_hit_lua_func`).
That last step — an FFI callback — needs LuaJIT to generate a machine-code
trampoline at runtime, i.e. writable-executable memory. iOS forbids W^X on
non-jailbroken devices, so FFI callbacks cannot work there, and App Store /
TestFlight builds carry no JIT at all. Plain FFI *calls* would run in interpreter
mode, but the hook-registration API is built entirely on FFI *callbacks*.

## Key observation

The breakpoint engine itself has almost no Lua in it. Across the whole `scripting`
library, only `manager.cpp` touches LuaJIT (5 sites), and all of them are in the
"load a `.lua` file / run its entry chunk" path. Everything else — writing the
`bkpt` instruction, the kernel breakpoint-hit callback, address relocation/patch,
`cpu::set_register`, codeseg loading — is ordinary C++. Critically,
`scripts::register_breakpoint` takes a plain `void(*)()` function pointer, and the
dispatch (`call<T>()`) just invokes it. A captureless C++ lambda / free function
satisfies that with **no runtime code generation**.

So the patches don't need Lua; they need the engine plus a way to register native
callbacks. Since we don't want to expose runtime script loading on iOS anyway,
compiling the fixed patch table directly in C++ is both sufficient and simpler
than porting LuaJIT.

## What changed

A build mode split: the scripting **engine** and the LuaJIT **runtime** are now
independently selectable.

- `EKA2L1_SCRIPTING_LUA` (new CMake option, default ON) gates LuaJIT: the external
  build (`src/external/CMakeLists.txt`), the `liblua` link, the Lua asset copy, and
  a new `ENABLE_SCRIPTING_LUA` configure define.
- iOS now forces `EKA2L1_ENABLE_SCRIPTING_ABILITY ON` + `EKA2L1_SCRIPTING_LUA OFF`
  — the engine is compiled and integrated (`epoc` links `scripting`, the
  `ENABLE_SCRIPTING` breakpoint path in `epoc.cpp` is live), but no LuaJIT.
- In `manager.cpp`, the Lua-only bits (`.lua` parsing in `import_module`, the
  `lua_pcall` entry in `call_module_entry`, the folder watcher, and `lua_gc` in
  `call<T>()`) are guarded by `ENABLE_SCRIPTING_LUA`. The kernel-hook registration
  that used to sit inside `call_module_entry` was extracted into
  `register_kernel_hooks()` so it runs in both modes.
- `import_all_modules()` branches: with Lua it scans `scripts/*.lua` as before;
  without Lua it calls the new `register_builtin_patches()`.
- `builtin_patches.cpp` (new, native-only) is the C++ transcription of the five
  shipped scripts — one `register_breakpoint(...)` per Lua `registerBreakpointHook`
  (argument order matches the C export: `lib, addr, process_uid, uid3, seghash,
  func`), plus the S^3 `domaincli.dll` preload guarded on
  `get_symbian_version_use() >= epocver::epoc95`. Keep it in sync with
  `src/scripts/*.lua`.

Desktop and Android are unaffected: `EKA2L1_SCRIPTING_LUA` defaults ON, so they
still build the full LuaJIT path and load `.lua` files at runtime.

## Verification

- Debug and Release iOS simulator builds compile and link with no LuaJIT.
- Full iOS regression suite: 12/12 PASS (Final Battle, Calculator, N95 Calculator,
  string catalog) — the now-live breakpoint/kernel-hook path does not regress apps
  that have no patches.
- Boot log shows `Built-in native game patches registered`, confirming
  `register_builtin_patches()` runs at startup. The S^3 branch correctly stays
  silent on the S60v3 regression devices (rm-409/rm-320).

Runtime firing of an individual patch was not exercised — none of the five patched
titles are in the regression set. The registration path and engine integration are
proven; landing one of those games would confirm an actual breakpoint hit.
