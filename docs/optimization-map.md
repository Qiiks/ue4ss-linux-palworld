# Palworld Server + UE4SS Fork — Master Optimization Map

**Server:** v1.0.2.101103 (UE 5.1), obnyis/palworld-dedicated-server, Coolify on Oracle Cloud 149.118.136.203
**Fork:** Qiiks/ue4ss-linux-palworld (upstream BlackBookOfficial), deployable = linux-native @ 8c427ed (leak fix + review fixes + GUI default; test lib caa1a4f7, live lib a00f8356)
**Date:** 2026-08-03 · **Constraint:** feature-preserving only (never trade features for performance)

Evidence key: 🔬 measured (perf/gdb/soak A/B) · 🧪 community (multi-source, consistent) · 💭 design (dump/mechanism-derived, unmeasured)

---

## 0. Status legend

| Status | Meaning |
|---|---|
| ✅ APPLIED | live (or test → pending promotion) |
| 🔧 QUEUED | designed, awaits soak/approval |
| 📐 DESIGNED | mapped, needs instrumented test before applying |
| 🚫 VETOED | user constraint (feature cut / overbuilt / risk) |
| 🔍 INVESTIGATING | lane in flight |

---

## 1. Config layer (PalWorldSettings.ini / env) — all server-side

| # | Setting | Current | Candidate | Effect (evidence) | Status |
|---|---|---|---|---|---|
| 1.1 | NetServerMaxTickRate | 60 (live) / 120 (test) | keep 60 | 8.3→16.6ms/tick budget; >60 doesn't fix rubberbanding; test intentionally heavy | ✅ APPLIED (live), test heavy-by-design |
| 1.2 | EnableHotReloadSystem | 0 | — | dev feature; double-register hooks on 24/7 | ✅ APPLIED |
| 1.3 | ItemContainerForceMarkDirtyInterval | 5.0 | — | cuts container re-sync traffic | ✅ APPLIED |
| 1.4 | ServerReplicatePawnCullDistance | 10000 | — | pals pop in ~100m | ✅ APPLIED |
| 1.5 | PhysicsActiveDropItemMaxNum | capped | — | stops physics sim of excess items (items still exist) | ✅ APPLIED |
| 1.6 | Log rotation | 5-day gz | — | disk hygiene | ✅ APPLIED |
| 1.7 | Daily restart | 20:00 UTC, REST-API-driven | — | bounds memory climb (community floor) | ✅ APPLIED |
| 1.8 | bEnableInvaderEnemy | true | false | 🧪 ~50% RAM-growth cut (Nodecraft/XGaming/ConnectHosting) | 📐 TRADEABLE (loses base raids) — user decision |
| 1.9 | AutoSaveSpan | 30s | 300-600s | 🧪 serialize-hitch frequency; crash-loss window grows | 📐 TRADEABLE — user decision |
| 1.10 | DropItemMaxNum / AliveMaxHours | 3000 / 1.0 | 1000 / 0.5 | 🧪 loose-item actor cull, serialization payload | 📐 TRADEABLE (oldest drops purge) |
| 1.11 | PalSpawnNumRate | 3.0 (user's 3×) | keep | #1 controllable sim cost — user chose 3× deliberately | 🚫 VETOED (user preference) |
| 1.12 | BaseCampWorkerMaxNum ini | 15 | — | **confirmed no-op bug** (real lever is DT_BaseCampLevelData) | 🔍 DEAD (no-op) |
| 1.13 | WorkSpeedRate | 1.0 | — | single global multiplier (players+pals); compensation lever only | 📐 (if ever needed) |
| 1.14 | Legacy threading args | image defaults | — | 1.0 docs reversed; image sets MULTITHREAD_ENABLED | 🚫 SKIP (A/B only) |
| 1.15 | GC keys (TimeBetweenPurgingPendingKillObjects etc.) | image 30s | 5s | only reclaimable fraction is pending-kill backlog | 📐 A/B candidate (data pending) |
| 1.16 | MALLOC_TRIM_THRESHOLD | — | — | dead on glibc ≥2.34 (GLIBC_TUNABLES) | 🚫 DEAD |

## 2. Game internals (pak-verified + live-binary-verified)

Full analysis: `docs/palworld-worker-ai-analysis.md` (addenda A-F). Summary:

- **Worker AI is 100% significance-gated** — live gdb proof: all 42 action components, 8 worker pawns, 39 AI controllers have tick flags set but enable byte=0, never registered. `UPalBaseCampManager::Tick` (slot 103, 0x6ff6f30): Timer@+0x300 vs Interval@+0x2FC → UpdateCamp → WorkerDirector → action Ticks (slot 92). **NOTHING escapes the gate.** The game already implements the user's philosophy.
- **Significance tiers** (BP_PalBaseCampManager CDO, 5 entries): -1m=0.1s, 500m=1.5s, 2500m=2.5s, 4500m=5s, 6500m+=10s+bUpdateSimple. Per-frame budget BaseCampTickInvokeMaxNumInOneTick=5.
- **Work progress structurally protected**: UPalWorkProgress own accumulator (ProgressTimeSinceLastTick + TickProcessMinInterval + AutoWorkSelfAmountBySec rate); WPM independent tickfn exists but never registered live. Progress advances only via worker actions in the gated cycle.
- **Work-catch-up semantics unmeasured** (community gap #2): does a late camp tick credit full Δt (rate preserved) or drop it? Decides whether significance tuning is free.

| # | Lever | What | Feature impact | Evidence | Status |
|---|---|---|---|---|---|
| 2.1 | Significance far-tier tuning (4500m: 5→8s, 6500m: 10→20s, add 12km tier) | pak-patch BaseCampSignificanceInfoList | none observable (nobody watches 4.5km+; bUpdateSimple already on) | 💭 design, dump-verified fields | 📐 requires catch-up measurement first |
| 2.2 | BaseCampTickInvokeMaxNumInOneTick 5→1 | pak | camp updates spread over more frames (latency only) | 💭 FPSFriendlyBases sets 1 | 📐 A/B on test |
| 2.3 | BaseCampWorkerEventTriggerInterval 90→180s | pak (PalGameSetting CDO) | sanity/event evaluations halved; events rarer | 🔬 CDO value 90.0 verified | 📐 mild, feature-safe |
| 2.4 | MinAIActionComponentTickInterval 0.05→0.2 | pak | **MOOT — components never tick-enabled** | 🔬 live | 🚫 DEAD |
| 2.5 | WorkerMaxNum via DT_BaseCampLevelData | pak | fewer workers/base | — | 🚫 VETOED (feature cut) |
| 2.6 | Work-catch-up runtime test (WorkProbe mod) | game-thread probe of UPalWorkProgress | none (measurement only) | 💭→🔬 | ✅ ANSWERED — see §12 |

## 3. Mod layer (UE4SS Lua)

| # | Mod | State | Notes | Status |
|---|---|---|---|---|
| 3.1 | AlphaRespawnScheduler | ✅ live+test | 10-min boss cooldown (was 1h); LoopAsync-based (works) | ✅ |
| 3.2 | PalServerOptimizer v1.2.1 | ✅ live+test | ragdoll off, mesh-tick, dropped-item budget; classification memoization (60s TTL LRU — cache hits 116 vs 4 misses live), real-clock drop deltas, ragdoll re-assert; proximity-wake DISABLED (v1.2 UAF crash) | ✅ |
| 3.3 | ServerMaintenance v1.7 | ✅ live+test | LoopAsync snapshots (RSS/lua/objs 5-min), config.lua system, game-thread census (EngineTick), auto_trim probe (default OFF) | ✅ |
| 3.4 | UE4SSStatus | ✅ live+test | print-only, zero risk | ✅ |
| 3.5 | **PSO v1.2.1** | ✅ shipped | memoize per monster (GetAddress), os.clock deltas, ragdoll re-assert; proximity-wake reverted (UAF on freed actor — strong IsValid can't run in sweep) | ✅ (UAF fixed) |
| 3.6 | **SM v1.7** | ✅ shipped | game-thread TrimAllocator probe (config-gated, default OFF — soak baseline must stay clean) | ✅ |
| 3.7 | **WorkProbe v1.8.x** | ✅ shipped | catch-up measurement DONE (§12); per-tier distance bucketing; 5 findings on fork Lua bindings (§10) | ✅ |

## 4. Fork layer (UE4SS C++)

Deployable = b23ad7c: walk fixes (address filter / split / KSL name), deadlock fix (13 lazy hooks), sticky atomics, mem API (TrimAllocator/GetObjectCount), EngineTick slot 0x308 fix (restored game-thread timers — PSO loops + census now fire).

| # | Item | State | Notes | Status |
|---|---|---|---|---|
| 4.1 | Upstream PRs #2-#13 | ✅ ALL MERGED 2026-08-02/03 | settings-never-throw, ksl-name, walk-fix, lifecycle-hook-deadlock, engine-tick-slot-0x308, AOB-fallback, crash-dumper, tick-path-gates, walk-live-objects, leak-fix (#12), GUI-default (#13) | ✅ |
| 4.2 | GameEngine::Tick AOB fallback | ✅ PR #7 merged | 24B signature @ 0xaa3cfe0, exactly 1 hit; dlsym fails on stripped dynsym | ✅ |
| 4.3 | Linux crash dumper | ✅ PR #8 merged | allocation-free + fork()-writer; old handler allocated inside → wedged game thread (the "signal 0 + empty dump" saga) | ✅ |
| 4.4 | ForEachUObject cost | 🔬 0.5-1.1% | census + PSO classification walk the object array; walk fixed (PR #10: 45k→348k slots, 3.9k→274k live objects); 1.61% GetFlagsInternal spike = PSO classification pass (memoized in v1.2.1) | 📐 |
| 4.5 | Hook dispatch per-tick cost | ✅ PR #9 merged | sticky-atomic fast paths + adaptive async sleep; engine_tick_hook self 0.04% | ✅ |

## 5. Host/infra layer (NEW findings)

| # | Item | Finding | Evidence | Status |
|---|---|---|---|---|
| 5.1 | **Docker seccomp filter** | **~4.9% test / ~7.9% live of game CPU in __seccomp_filter** | 🔬 perf A/B (confined vs unconfined, both servers) | ✅ test applied; live → maintenance window |
| 5.2 | Memory soak (four-signal) | objs flat (357386/160112) while RSS climbs 3-6MB/hr = allocator pools, not objects → **Trim is the lever, GC won't help** | 🔬 7h+ soak | ✅ data |
| 5.3 | _blake3_compress_xof_avx512 ~1.5% | SteamNetworkingSockets DTLS crypto | 🔬 | irreducible |
| 5.4 | Unresolved worker addrs 0x755ff44/0x755f8e0 (~7-9%) | stripped binary, no symbols | 🔬 | 🔍 rev-2 |
| 5.5 | syscall path total | ~15% confined → ~10.5% unconfined | 🔬 | ✅ (5.1) |
| 5.6 | Save bloat | corpses/spent-eggs/referenced-growth; cleanup tools require stopped server (PST GUI bulk cleanup, palworld-save-tools); no live cleanup exists | 🧪 | 📐 (maintenance-window tool) |

## 6. Frontier experiments (community-first measurements)

| # | Experiment | What it proves | Status |
|---|---|---|---|
| 6.1 | Work-catch-up measurement (WorkProbe) | whether significance tuning is free (rate-preserving) or costly (rate-losing) — no public data exists | 🔧 QUEUED |
| 6.2 | Significance-tier A/B | measured CPU/behavior delta of far-tier tuning on the populated world | 📐 after 6.1 |
| 6.3 | Seccomp A/B | done — 4.9%/7.9% recovered | ✅ DONE |
| 6.4 | UE4SS-on-Linux safe-API matrix | our crash taxonomy (load-map hook, async-thread UE API, EngineTick) is frontier knowledge — document for mod authors | 📐 (skill KB exists, formalize) |

## 7. Recommended order

1. ✅ Seccomp → live at next maintenance window (20:00 UTC) — free 8%
2. 🔧 WorkProbe (6.1) → catch-up data → significance-tier A/B (6.2) on test
3. 🔧 SM v1.7 (Trim policy) + PSO v1.2 after the 48h soak completes
4. 🔍 rev-2 fork findings (AOB signature, crash dumper) → upstream PRs
5. 📐 Tradeable configs (1.8 invader, 1.9 autosave, 1.10 drops) — user decision, no action without it

---

## 8. rev-2 fork RE findings (2026-08-01) — T1-T4

### T1 — EngineTick resolution: NOT an AOB — dlsym, and why it failed
The Linux port's "AOB scan" is a dlsym override (`UE4SSProgram.cpp:1682` → `try_resolve("UGameEngine::Tick")`); Palworld's Linux server strips those symbols from dynsym → null. The fork itself documents why upstream Windows patterns can't work (`UE4SSProgram.cpp:959`). Working path = vtable slot 0x308 (b23ad7c, 0x2F0 was PostExit — silent dead hook).
**Verified signature** (24 bytes, exactly 1 hit in 140MB binary): UGameEngine::Tick @ 0xaa3cfe0:
`55 41 57 41 56 41 55 41 54 53 48 83 EC 58 49 89 FC 48 8B BF E0 09 00 00`
PR design: reuse the existing dl_iterate_phdr exec-segment scanner (StaticConstructObject path, `UE4SSProgram.cpp:1711`) + prologue sanity; keep vtable as is_palworld-gated fallback. → **PR #7 candidate.**

### T2 — CrashDumper: CreateFileW is #ifdef _WIN32-only; the real Linux bug is the handler itself
Linux has `linux_crash_handler` (open/write/backtrace_symbols_fd) but it calls allocating/locking functions (`fmt::format`, `std::string`, `get_now_as_string`, `UE4SS_DBG`) → heap-corruption crashes **deadlock the game thread inside the handler** — the wedge-saga signature. Fix (minimal, mergeable): static buffers + snprintf + raw write, O_CLOEXEC, time() not the string helper, working-dir captured once at enable(), stderr fallback, offline addr2line, optional fork()-writer. Ensure-paths must NOT route through the handler. → **PR #8 candidate.**

### T3 — Fork hotspots (ranked, all fork-internal)
1. **engine_tick_hook** (`LuaMod.cpp:4262`): 3+ recursive-mutex lock cycles + vector moves per tick (now live post-0x308). Gate the whole tick path with the codebase's own sticky-atomic pattern (`LuaMod.cpp:6696`) before any lock — ~5 lock cycles/tick saved.
2. **update_async** (`LuaMod.cpp:7519`): fixed 5ms sleep = 200Hz wake; adaptive (5ms busy / 25-50ms idle).
3. process_simple_actions: minor vector churn (folds into #1).
4. ForEachUObject ~0.7%: census cadence tuning.
5. FName: hot sites static-cached; the "23-byte wrapper" unverified (need pointer).

### T4 — Live CPU (idle ~43%) fully explained
| ~16% | kernel syscall+seccomp (pthread_sigmask storm ~12% of chains, game wait path) |
| ~20% | game main-loop region 0x780xx (pool-pop + double-dispatch helper) |
| ~16% | rdtsc/pause busy-spin cluster 0x7760f40 on task-graph workers (spin-while-idle) |
| ~11% | UE4SS LuaMod region (EngineTick dispatch + async loop — now active) |
| ~1.2% | save pipeline (blake3 IOThreadPool + PalSave-Pool) |
| ~0.9% | ForEachUObject + update_async |

**Verdict:** the 43% is game-side spin/syscall churn, not object churn — consistent with objs flat / RSS climbing (allocator pools → Trim stays the lever). UE4SS's own ~11% is measurable and attackable via T3#1.

---

## 9. Night-session delivery (2026-08-01) — fork fixes, WorkProbe, PSO v1.2

### Shipped + verified (all on test container, soak continues)
- **T1 AOB fallback** for UGameEngine::Tick (PR #7): dlsym fails on Palworld (stripped dynsym); verified 24B signature, exactly 1 hit. Functional proof: PSO game-thread loops + census run on schedule.
- **T2 crash-handler fix** (PR #8): allocation-free, fork()-writer Linux handler — the old handler allocated inside (wedged game thread on heap-corruption crashes; the "signal 0 + empty report" saga).
- **T3 tick-path gates** (PR #9): 4 sticky atomic flags gate EngineTick/ProcessEvent hooks before the first mutex; adaptive async sleep (50ms idle / next-due wake). Perf after: engine_tick_hook self 0.04%.
- **Perf re-measure**: libUE4SS total ~1.3-2.8% of game CPU; GetFlagsInternal 1.61% spike = PSO classification passes (sampling-window artifact of the 60s sweep, proves mod-Lua is the fork-side cost — attacked via PSO v1.2, not the tick machinery).
- **WorkProbe v1.1** (assets/Mods/WorkProbe): UPalWorkProgress catch-up probe. Playerless finding: all slots frozen at zero with stable addresses — work sim doesn't run without players; experiment needs a player on test (18211/test123).
- **PSO v1.2** (assets/Mods/PalServerOptimizer): classification memoization (60s TTL LRU), real-clock drop deltas, ragdoll re-assert, dormancy proximity-wake. Loaded clean, zero crashes.

### Queued (not started)
- **Seccomp → live** at the 20:00 UTC daily maintenance window (test already unconfined; A/B measured ~5-8% CPU).
- **WorkProbe catch-up data** — needs a player on the test server.
- **Significance-tier pak tuning** — gated on WorkProbe catch-up semantics (Phase 4 decision).

---

## 10. Live promotion + WorkProbe camp instrumentation (2026-08-01 night, full autonomy)

### Live fully promoted (22:13 UTC) — the entire fixed stack
- New lib `6e4f9538` (walk-live-objects + T3 gates + T1 AOB + T2 crash handler + review fixes), PSO v1.2.1 (proximity-wake DISABLED — the v1.2 UAF fix), SM v1.7, WorkProbe v1.7 wired into mods.txt.
- **Seccomp unconfined on live** via Coolify compose update (`security_opt: - seccomp=unconfined`) — survives Coolify container recreation. Old lib backed up as libUE4SS.so.pre-walkfix-7276cf93.
- Verified: all 5 mods loaded clean, zero crash dumps, walk-fix proof — live control census sees **94,357 live objects** (was ~3,900 on the broken walk; live's fresh world is smaller than test's 274k populated world).
- Note: PSO CPU re-measure on live was attempted but live is idle (0% CPU, empty world, no players) — perf captures there are meaningless; the populated test world is the measurement target.

### WorkProbe v1.8 series — camp association (per-tier effective-rate measurement)
Goal: bucket each UPalWorkProgress by its base camp + player distance → significance tier → measure effective work rate per tier (the kill-shot for the significance-tuning question).

Fork Lua-binding discoveries (all verified empirically, 22:22-22:50 UTC):
1. **Struct PROPERTY reads return opaque `TrivialObject` userdata** — `obj.BaseCampIdBelongTo`, `obj.Transform`, `obj.SignificanceInfo` are all unresolved on this fork (FGuid/FTransform/FPalBaseCampSignificanceInfo have no Lua pusher). Member access returns the same trivial object.
2. **UFUNCTION struct returns DO resolve** — `object:GetId()` returns a struct whose A/B/C/D members read as int32 via `:get()` (PSO's proven remote-value pattern). `object:GetTransform()` returns a struct whose Translation/Rotation/Scale3D members are nested Lua tables.
3. **Class-token matching is mandatory** — substring name matching catches path noise (the live work instances contain the manager's name in their path; 127 pseudo-camps were Blueprint/reflection noise). Match `name:match("^(%S+)")` exactly: `PalBaseCampModel`, `PalWorkProgress`, `PalWorkProgressMultiType`.
4. **Per-object pcall isolation** — a single throw in the ForEachUObject callback aborts the whole walk silently; wrap scan_one per object and capture errors.
5. **table.concat only handles arrays** — string-keyed tables (camp#1...) need a pairs-based serializer.

Current v1.8.6 state on test: camps=6 with real FGuid ints (camp#1 A=0,B=0,C=0,D=0 = the default/empty GUID — likely a template; #2-#6 are the real 5 camps, matching PalBaseCampModel=5 in the census), work objects with workid FGuid ints, GetTransform nested tables resolving. WorkCollection (object ref) read attempt in flight — WorkIds (TArray<FGuid>) would give the work→camp link directly.

Still open: nested table X/Y/Z extraction (Translation=table: 0x... needs one more level), WorkCollection array read, then the per-tier rate bucketing (needs a player in one base while others stay far).

### WorkProbe v1.8.9-v1.8.10 — per-tier bucketing SHIPPED (23:14 UTC)
- **v1.8.9**: work locations via `CachedOwnerMapObjectConcreteModel:GetActor():K2_GetActorLocation()` — object-ref property read (works) → actor UFUNCTION (works) → FVector return with X/Y/Z floats. PSO-proven pattern; no camp GUID matching needed.
- **v1.8.10**: distance-to-player + significance-tier bucket per work object (in-base 0.1s / 500m 1.5s / 2500m 2.5s / 4500m 5s / 6500m+ 10s; cm units). Verified on test: 118 work objects bucketed (13 far10 / 19 t2500 / 86 t4500 — playerless origin), probe cadence clean, zero dumps.
- **CRITICAL crash class caught**: v1.8.6's unbounded classify_struct recursion wedged the game thread (Lua stack overflow — TrivialObject member reads return THEMSELVES, so any recursion over struct members loops forever). Symptom: 0% CPU, single probe run then silence, REST dead, container still pgrep-healthy. Fix: recursion only into `type(v)=="table"` values, bounded one level.

### PSO CPU re-measure (populated world, walk-fixed + seccomp unconfined, 23:20 UTC)
perf on the real game process (PalServer-Linux, NOT the PalServerUE4SS wrapper — that one is 0% and produces 0.015MB garbage captures): 6478 samples. Game main-loop region 0x755f* ≈ 10.5%; kernel syscall storm ≈ 14.1% (pthread_sigmask _copy_to_user 5.16% + entry_SYSCALL 2.84% + do_syscall 1.82% + sigprocmask 1.08% — **seccomp gone, no __seccomp_filter symbols**); **fork (RC::Unreal) ≈ 4.3%**: FindAllOf lambda 2.04% + GetNamePrivate 1.00% + GetSuperStruct 0.74% + GetClassPrivate 0.54% (the 60s PSO/WorkProbe/SM census walks at 274k objects — the measured price of the walk fix); pthread_mutex_lock 1.60%; blake3 1.28% (save pipeline); _start 1.93%. Seccomp A/B validated on live: 0% seccomp cost vs 7.92% pre-fix.

## 11. Memory leak saga — ToString paths leak game-allocated buffers (2026-08-02→03)

### The leak
RSS climbs ~100-425MB/min native once ForEachUObject walkers call GetFullName/GetName per object
(objs flat, lua flat). ~300B/call. WorkProbe-only bisect: 425MB/min; PSO-only: flat.

### Root cause (proven)
Fork ToString paths (NameTypes.cpp) — Conv path ACTIVE (FName::ToString not found in stripped
binary; Conv_NameToString resolves) — let the GAME allocate the FString Data buffer (Binned2),
then the fork's ~TArray (Array.hpp:1054) NEVER frees (view wrapper). Silent never-free leak.

### Failed fixes
- v1 (e7bbb1cf): (*GMalloc)->Free after detach → SIGSEGV at init. GMalloc = BSS heuristic
  (Palworld doesn't export it; nm -D empty); fork's own comment warns of false positives.
- v2 (acee14b): added bVersionedContainerIsInitialized guard → still crashed: the required-
  objects walk runs AFTER the flag is set, so the guard passes and the free fires during init.

### Fix v3 — SHIPPED & VALIDATED (2026-08-03) — pre-reserve, not free

GMalloc RE (rev-1, live gdb) proved a GMalloc-based free is STRUCTURALLY IMPOSSIBLE:
real allocator @ 0xC0248A8 has NO vtable Free — slot +0x20 is an accessor, +0x38/+0x50
NULL; Free is TLS-inlined; no out-of-line FMemory::Free stub exists. The fork's
heuristic pick 0xBD453C8 was a false-positive stub allocator (the v1/v2 crash cause).

**The shipped fix** (7a3ac60 + 67654d7 + review fixes 42918cd; PR #12):
1. Pre-reserve the fork-owned FStringOut (`string.Reset(NAME_SIZE+16)`) BEFORE calling
the game's FName::ToString(FString&) @ 0x7945dd0 — RE-verified the game APPENDS into
existing capacity (`cmp needed, Max(+0xC); jge keep-buffer` at 0x77950a0), so it never
calls its allocator; the fork dtor SystemFrees its own buffer. Correct ownership.
2. The address ships via Lua scan override (UE4SS_Signatures/FName_ToString.lua,
`return 0x7945dd0`) — NOT UE4SS_Addresses.ini (Ini::Parser throws on missing keys →
SIGABRT through libsteam_api's broken __gxx_personality_v0; the Lua path never throws).
### Deployment state (2026-08-03)
LIVE: a00f8356 stack (leak fix + all mods: ARS, PSO v1.2.1, SM v1.7, WorkProbe,
UE4SSStatus), flat 1.22GB, joinable (149.118.136.203:8211 / GoonWatch101).
TEST: caa1a4f7 (review-fixed build), full 5-mod set on the populated 683-pal world,
flat 2.1-2.3GB, zero dumps. ALWAYS_UPDATE_ON_START=false on both (steamcmd
destroy-loop lesson: staged full game into steamapps/downloading, timeout aborted
mid-finalize → wiped binary+pak; restored from known-good volume, pak hardlinked
b252c78b). Both servers seccomp=unconfined (5.1). Daily 20:00 UTC restart live.

---

## 12. Work-catch-up ANSWERED — keep native significance tiers (2026-08-02)

### The experiment
Player joined the populated test world and stood in a base while WorkProbe sampled
UPalWorkProgress every 60s: tick (ProgressTimeSinceLastTick), rate
(AutoWorkSelfAmountBySec), remain (GetRemainWorkAmount), plus per-tier distance
bucketing (v1.8.x). 32 live work instances observed with real rates 2-120/s.

### The answer: work progresses in throttled batch cycles
obj=30 (declared rate 120/s): remain cycled 6396 → 4044 → 6304 → 533 → 2764 →
5018 → 7249 → 1478 across 8 samples — a -5770 consumption burst every ~3 samples
with +2230 re-assignment additions between: a production cycle completing in
DISCRETE batch consumption, not smooth drain. Declared rate ≠ effective rate
(120/s × 66s = 7,920 expected vs ~5,770 per ~200s ≈ 29-44/s effective) — the
significance gate demonstrably throttles work below theoretical rate.
rate=0 objects stay frozen (worker-driven work with no self-progress at far tiers,
consistent with the frozen-pawn live-binary proof).

### Decision: NO nerf-tier pak (2.1 retired)
Significance-tier tuning COSTS output (the gate throttles) but work still completes
— the native tiers already ARE the feature-preserving compromise. Tuning far tiers
further would trade player-visible production for CPU with zero feature preservation
gain. 2.1/6.1/6.2 CLOSED. The catch-up measurement (community-first) is documented
in the skill KB + memory #1166/#1169.

### Enabling prerequisite: the ForEachUObject walk fix (PR #10)
The earlier "no live work objects / all frozen" finding was a walk-coverage artifact:
UObjectGlobals.cpp chunked walk had (1) a 4-chunk SafeElementLimit hard cap (262,144
of 403,389 objects — the streamed world lives in chunks 4-6, never visited) and
(2) an EInternalObjectFlags==0 skip (zero is the steady state for live objects;
only root-set engine assets survived). Removed both: slots_visited 45k → 348k,
all_live_total 3.9k → 274k. PR #10. Side effect that mattered: PSO finally saw the
real world (ragdoll_components 11 → 129) — and the census workload exposed the
ToString leak (§11), which is why the leak fix had to land.
