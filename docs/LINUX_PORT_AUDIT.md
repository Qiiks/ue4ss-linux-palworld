# Linux Port Audit: Classification of All Changes

## Classification System

Each change is classified as one of:
- **[GENERIC]** — Benefits every Linux UE4SS build (upstream-worthy)
- **[PALWORLD]** — Palworld-specific workaround (gated to game binary)
- **[TEMPORARY]** — Debug scaffolding that should be removed (already removed in cleanup commit)

---

## 1. `bit_cast_mfp` — PMF Zero-Initialization

**File:** `deps/first/Unreal/include/Unreal/VersionedContainer/UnrealVirtualImpl/UnrealVirtualBaseVC.hpp`

**Classification:** [GENERIC]

**Rationale:** The Itanium ABI's 16-byte pointer-to-member-function representation is a platform reality, not game-specific. The union-based cast only initialized 8 of 16 bytes, leaving the `this` adjustment field as stack garbage. This affects ALL Linux builds, not just Palworld. The fix (zero-initialize before memcpy) is correct for any Itanium ABI target.

---

## 2. Palworld UObject Vtable Offset Override

**File:** `deps/first/Unreal/src/UnrealInitializer.cpp`

**Classification:** [PALWORLD]

**Rationale:** Palworld's modified UE5.1 engine has an extra virtual function slot in UObject between `OverridePerObjectConfigSection` and `ProcessEvent`. This shifts ProcessEvent (+8), GetFunctionCallspace (+8), CallRemoteFunction (+8), and ProcessConsoleExec (+8). Other UObject virtuals (PostLoad, BeginDestroy, FinishDestroy) are at standard offsets, confirming this is a local modification, not an engine-wide ABI difference.

**Gating:** Runtime detection via `readlink("/proc/self/exe")` checking for "PalServer". Only applied when the game binary is Palworld.

---

## 3. `LUA_USE_LONGJMP` Build Definition

**File:** `deps/first/LuaRaw/CMakeLists.txt`

**Classification:** [GENERIC]

**Rationale:** `libsteam_api.so` (Steamworks) exports `__cxa_throw` and `__gxx_personality_v0`, which intercept C++ exceptions and call `abort()`. This affects ANY game that ships Steamworks on Linux, not just Palworld. When Lua is compiled as C++ (which UE4SS does), Lua's error handling uses C++ `throw/catch`, which gets intercepted. Defining `LUA_USE_LONGJMP` makes Lua use `_longjmp/_setjmp` instead, bypassing the crash reporter. This is the correct fix for any Linux UE4SS build with Steamworks.

**Gating:** Applied only when `LUA_COMPILE_AS_CPP=ON` AND platform is Linux.

---

## 4. FName(StringViewType) Null-Termination

**File:** `deps/first/Unreal/include/Unreal/NameTypes.hpp`

**Classification:** [GENERIC]

**Rationale:** `std::basic_string_view::data()` is NOT guaranteed to be null-terminated per the C++ standard (C++17). This is a correctness bug on ALL platforms — it happens to work on Windows because the underlying string is usually null-terminated. The fix creates a null-terminated copy before passing to the engine's FName constructor. Not gated to any platform.

---

## 5. `Function::reset_address()` — Clear `m_is_ready`

**File:** `deps/first/Function/include/Function/Function.hpp`

**Classification:** [GENERIC]

**Rationale:** `reset_address()` cleared the function address but didn't clear `m_is_ready`, leaving the Function object in an inconsistent state (address=0 but is_ready=true). This caused crashes when the stale function pointer was used. This is a correctness bug on ALL platforms.

---

## 6. FMemory Uses SystemMalloc on Linux

**File:** `deps/first/Unreal/src/Core/HAL/UnrealMemory.cpp`

**Classification:** [GENERIC] (with documented rationale)

**Rationale:** UE4SS runs on a detached background thread. The engine's `FMallocBinned2` uses `pthread_getspecific` for per-thread allocation caches. On the game thread, the TLS cache is initialized during engine boot. On UE4SS's background thread, the TLS cache may not be set up, causing the allocator to crash. UE4SS's internal containers (TMap, TSparseArray, TArray) are self-contained and don't interact with the engine's garbage collector, so using the system allocator is safe.

**Note:** This is a documented engine restriction. A future improvement would be to run UE4SS initialization on the game thread (via a hook callback) to enable engine allocation.

---

## 7. GMalloc Heuristic (BSS Scan with Vtable Validation)

**File:** `UE4SS/src/UE4SSProgram.cpp`

**Classification:** [GENERIC]

**Rationale:** On stripped Linux binaries, `dlsym` cannot find `GMalloc`. The heuristic scans BSS for the `FMalloc**` → `FMalloc*` → instance → vtable chain, validating the vtable's no-op pattern at vtable[2]. This is needed for any stripped Linux UE game binary.

---

## 8. FMallocBinned2 Vtable Offset Shift Detection

**File:** `UE4SS/src/UE4SSProgram.cpp`

**Classification:** [GENERIC]

**Rationale:** On the Itanium ABI, `FMallocBinned2`'s vtable has an extra virtual slot (vtable[2] = no-op `xor eax,eax; ret`), shifting Malloc/Realloc/Free by +8 bytes. This is detected at runtime by checking if vtable[2] is the no-op pattern. This is an Itanium ABI difference, not Palworld-specific.

---

## 9. GUObjectArray Chunked Access (24-byte FUObjectItem)

**File:** `deps/first/Unreal/src/UObjectArray.cpp`

**Classification:** [GENERIC]

**Rationale:** UE5's `FChunkedFixedUObjectArray` uses chunked storage with 24-byte `FUObjectItem` on Linux (vs 16-byte on Windows due to different alignment/padding). The chunked access code handles this correctly. This is needed for any UE5 Linux game.

---

## 10. Per-Iteration SIGSEGV Recovery in ForEachUObject

**File:** `deps/first/Unreal/src/UObjectGlobals.cpp`, `UE4SS/src/main_linux.cpp`

**Classification:** [GENERIC]

**Rationale:** The engine's GC can free objects and leave stale `FUObjectItem` entries that still have non-null Object pointers to freed-but-mapped memory. On Windows, this is handled differently. On Linux, the per-iteration `sigsetjmp/siglongjmp` recovery skips stale entries instead of crashing. This is needed for any Linux UE game where GC runs during object iteration.

---

## 11. PalworldNameProvider (Engine Find-Or-Add)

**File:** `deps/first/Unreal/src/NameTypes.cpp`

**Classification:** [PALWORLD]

**Rationale:** On stripped Linux binaries, `dlsym` cannot find the FName constructor. The `PalworldNameProvider` locates the engine's find-or-add function by scanning for a specific code pattern in the binary. The function address is game-specific (different binary = different address), but the scanning approach is generic. The name "PalworldNameProvider" should be generalized to "LinuxNameProvider" for upstreaming.

---

## 12. PostInitialize Skips (GUObjectArray Element Count Check)

**File:** `deps/first/Unreal/src/UnrealInitializer.cpp`

**Classification:** [GENERIC]

**Rationale:** On stripped Linux binaries, if the GUObjectArray heuristic finds the wrong address, the element count may be 0 or very small. The check `if (UObjectArray::GetNumElements() < 1000)` skips PostInitialize to avoid crashing on invalid object iteration. This is a safety check for any Linux build where the GUObjectArray address might be wrong.

---

## 13. ScanOverrides (Skip PatternSleuth Scanner)

**File:** `deps/first/Unreal/src/UnrealInitializer.cpp`

**Classification:** [GENERIC]

**Rationale:** PatternSleuth's scanner crashes on stripped Linux binaries with empty signature containers. The overrides are set directly (GUObjectArray, GMalloc, etc.) instead of using the scanner. This is needed for any stripped Linux UE game.

---

## 14. KismetStringLibrary Conv_NameToString Setup

**File:** `deps/first/Unreal/src/UnrealInitializer.cpp`

**Classification:** [GENERIC]

**Rationale:** On stripped Linux binaries, `dlsym` cannot find `FName::ToString`. The `Conv_NameToString` approach (calling `UKismetStringLibrary::Conv_NameToString` via ProcessEvent) is the LTO-proof, version-stable alternative. This is the standard UE4SS approach for stripped binaries and is already in the upstream code (PR #1175).

---

## 15. Default__Object / Default__Struct Lookups

**File:** `deps/first/Unreal/src/UnrealInitializer.cpp`

**Classification:** [GENERIC]

**Rationale:** These lookups were temporarily disabled on Linux due to the `bit_cast_mfp` and vtable offset bugs preventing `GetFullName()` from working. With both bugs fixed, the lookups succeed normally. The `#ifdef __linux__` guard is needed because the lookup uses `StaticFindObject_InternalSlow` which requires `GetFullName()` to work (which requires the vtable fix). On Windows, the lookup works without any special handling.

---

## 16. Signal Handler (SIGSEGV/SIGABRT Recovery)

**File:** `UE4SS/src/main_linux.cpp`

**Classification:** [GENERIC]

**Rationale:** The signal handler provides SIGSEGV recovery for UE4SS's background thread. This is needed because UE4SS runs on a separate thread from the game, and accessing engine data structures can occasionally hit stale pointers. The handler uses `sigsetjmp/siglongjmp` to recover. This is a Linux-specific safety mechanism.

---

## 17. Thread Stack Size (8MB)

**File:** `UE4SS/src/main_linux.cpp`

**Classification:** [GENERIC]

**Rationale:** UE4SS's background thread needs a large stack for deep call chains (ForEachUObject → GetFullName → ToString → Conv_NameToString → ProcessEvent). The default thread stack size may be insufficient. Setting 8MB via `pthread_attr_setstacksize` is a safe default.

---

## 18. FName::ToString FString Leak Fix (pre-reserve) — PR #12 (2026-08-03)

**Files:** `deps/first/Unreal/src/NameTypes.cpp`, `UE4SS/src/UE4SSProgram.cpp`

**Classification:** [GENERIC]

**Rationale:** The Scan ToString path let the game allocate the FString output via its
TLS-cache allocator, then the fork's dtor freed it with glibc — an allocator mismatch
that leaks ~300B/call (425MB/min under object-walking mods). Fix: pre-reserve the
fork-owned FStringOut (`Reset(NAME_SIZE+16)`) so the game appends into existing
capacity and never allocates; the fork dtor frees its own buffer. Also guards the
Linux dlsym/AOB fname_to_string override from clobbering a Lua scan override.

---

## 19. GameEngine::Tick — AOB fallback + slot 0x308 — PRs #6/#7 (2026-08-01)

**File:** `UE4SS/src/UE4SSProgram.cpp`, `deps/first/Unreal/src/UnrealInitializer.cpp`

**Classification:** [PALWORLD]

**Rationale:** Palworld strips `UGameEngine::Tick` from dynsym (dlsym fails) and the
baked vtable slot 0x2F0 points at `UEngine::PostExit` (a silent dead hook). Correct
slot is 0x308 (RE-verified: call-site dispatch at FEngineLoop::Tick, runtime stack
sample, GameInstance fingerprint). The 24-byte AOB (`55 41 57 41 56 41 55 41 54 53
48 83 EC 58 49 89 FC 48 8B BF E0 09 00 00`, exactly 1 hit) is the update-resilient
fallback for the stripped-symbol case. Restores game-thread timers.

---

## 20. Lifecycle-hook deadlock — PR #5 (2026-08-01)

**File:** `UE4SS/src/Mod/LuaMod.cpp`, `LuaMod.hpp`

**Classification:** [GENERIC]

**Rationale:** 13 unconditional lifecycle hooks took the Lua mutex on the game thread
while the async thread held it through a 5ms sleep → permanent deadlock on any actor
spawn/despawn (player join/leave). Fix: empty-callback early returns before the lock
+ sleep moved outside the lock + 13 sticky atomic flags (release-on-emplace,
acquire-on-check; monotonic, never cleared).

---

## 21. Allocation-free Linux crash handler — PR #8 (2026-08-01)

**File:** `UE4SS/src/CrashDumper.cpp`

**Classification:** [GENERIC]

**Rationale:** linux_crash_handler allocated/locked inside itself (fmt::format,
std::string, get_now_as_string) → heap-corruption crashes deadlocked the game thread
inside the handler (the "signal 0 + empty minidump" wedge saga). New handler: static
buffers + snprintf + raw write, O_CLOEXEC, time(), fork()-writer child, offline
addr2line symbolization.

---

## 22. Sticky-atomic tick-path gates + adaptive async sleep — PR #9 (2026-08-01)

**File:** `UE4SS/src/Mod/LuaMod.cpp`, `LuaMod.hpp`

**Classification:** [GENERIC]

**Rationale:** engine_tick_hook/process_event_hook took 3+ recursive-mutex lock cycles
per tick. Sticky-atomic fast paths gate before the first lock; update_async sleep is
now adaptive (50ms idle / just-before-due when actions are queued).

---

## 23. ForEachUObject walk — remove 4-chunk cap + flags filter — PR #10 (2026-08-01)

**File:** `deps/first/Unreal/src/UObjectGlobals.cpp`

**Classification:** [GENERIC]

**Rationale:** The chunked walk hard-capped at 4 chunks (262,144 of 403,389 objects)
and skipped items whose EInternalObjectFlags word was 0 — but zero is the steady
state for live objects, so only root-set engine assets survived (3.9k of 274k).
Both removed; the per-iteration recovery wrapper is the real safety mechanism.

---

## 24. SettingsManager never throws — PR #2 (2026-08-01)

**File:** `UE4SS/src/SettingsManager.cpp`

**Classification:** [GENERIC]

**Rationale:** `std::stoll("")` on an empty [EngineVersionOverride] threw through
libsteam_api's broken `__gxx_personality_v0` → abort (SIGABRT, no log file).
C-style non-throwing parsing with base-10 default (base-16 only for explicit 0x).

---

## 25. Shipped settings: GUI console default off — PR #13 (2026-08-03)

**File:** `assets/UE4SS-settings.ini`

**Classification:** [PALWORLD]

**Rationale:** DebuggingGUI::setup SIGSEGVs on headless dedicated servers
(issue #1 Crash 1). Shipped template defaults ConsoleEnabled=0/GuiConsoleEnabled=0/
GuiConsoleVisible=0.

---

## Summary

| # | Change | Classification |
|---|--------|---------------|
| 1 | bit_cast_mfp zero-init | [GENERIC] |
| 2 | Palworld vtable override | [PALWORLD] |
| 3 | LUA_USE_LONGJMP | [GENERIC] |
| 4 | FName null-termination | [GENERIC] |
| 5 | reset_address m_is_ready | [GENERIC] |
| 6 | FMemory SystemMalloc | [GENERIC] |
| 7 | GMalloc heuristic | [GENERIC] |
| 8 | FMallocBinned2 vtable shift | [GENERIC] |
| 9 | GUObjectArray chunked access | [GENERIC] |
| 10 | Per-iteration SIGSEGV recovery | [GENERIC] |
| 11 | PalworldNameProvider | [PALWORLD] |
| 12 | PostInitialize element count check | [GENERIC] |
| 13 | ScanOverrides skip | [GENERIC] |
| 14 | Conv_NameToString setup | [GENERIC] |
| 15 | Default__Object lookups | [GENERIC] |
| 16 | Signal handler | [GENERIC] |
| 17 | Thread stack size | [GENERIC] |
| 18 | FName::ToString pre-reserve (PR #12) | [GENERIC] |
| 19 | GameEngine::Tick slot 0x308 + AOB (PRs #6/#7) | [PALWORLD] |
| 20 | Lifecycle-hook deadlock (PR #5) | [GENERIC] |
| 21 | Allocation-free crash handler (PR #8) | [GENERIC] |
| 22 | Tick-path gates + adaptive sleep (PR #9) | [GENERIC] |
| 23 | Walk: remove 4-chunk cap + flags filter (PR #10) | [GENERIC] |
| 24 | SettingsManager never throws (PR #2) | [GENERIC] |
| 25 | GUI console default off (PR #13) | [PALWORLD] |

**Palworld-specific:** 4 changes (#2, #11, #19, #25), all properly gated.
**Generic upstream fixes:** 21 changes, benefiting all Linux UE4SS builds.
**Temporary debug code:** 0 remaining (all removed in cleanup commit).
