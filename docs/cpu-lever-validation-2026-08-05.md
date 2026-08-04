# CPU Lever Validation — Oracle + Research Verdicts (2026-08-05)

Working record for the overnight CPU-optimization A/B (results land in
optimization-map.md §15 once measured). Two independent advisory lanes were
consulted before touching config, per the project's evidence-first discipline.

## Oracle verdict (session ses_031756614ffe2o4MY0Ye6HkUzY)

| Lever | Verdict |
|---|---|
| NetServerMaxTickRate 120→60 | CONDITIONAL — approve the A/B, not unconditional promotion; player-present tests needed before calling it feature-neutral |
| AutoSaveSpan 30→300 | CONDITIONAL; reject under strict durability constraint (crash-loss window 30s→5min) |
| Task-graph spin tuning | CONDITIONAL only for spin budget; REJECT thread-count reduction |
| Main-loop dispatch | CONDITIONAL as consequence of tick-rate lever; no independent patch |

Methodology corrections from oracle (adopted):
- `ps pcpu` is a lifetime average — useless for A/B. Use per-interval CPU
  deltas from /proc/<pid>/stat (implemented: scripts/cpu-interval.sh).
- 15 min is a screening run; 45-60 min for promotion evidence. Repeat arms.
- Keep AutoSaveSpan identical during tick-rate A/B (save bursts alias CPU).
- Keep diagnostic Lua work identical across arms (WorkProbe 60s, SM 300s).
- Confounders to record: world-load transients, VPS noise, process PID,
  binary hash, mod set, player count, object counts.
- Never reduce TaskGraph worker count under the feature-preservation rule.
- Re-profile same binary+mods+workload before assigning savings; do not
  combine pre/post-seccomp profile percentages.

## Research verdict (lib-1, full report at C:\Users\Sanveed\palworld-cpu-levers-report.md)

| Lever | Expected CPU impact | Verdict |
|---|---|---|
| NetServerMaxTickRate=60 | ~half of the ~12% limiter storm (~-6%) | SAFE (community + own profile) |
| bUseFixedFrameRate=True + FixedFrameRate=60 | Bounds main-loop dispatch (~20%) | SAFE with UE-100223 consistency caveat (must match tick cap) |
| AutoSaveSpan 30→300 | blake3 1.2% → ~0.2%; ~10x fewer save bursts | TRADE (5-min crash window) |
| Task-graph worker count | — | UNPROVEN/NO LEVER — UE5 workers park; spin = tasks fed every tick (workload, not misconfig); TaskGraph.NumThreads is a dead UE4-era key |
| blake3 | — | Save pipeline, NOT networking (GNS = AES-GCM+Curve25519, no blake3, no DTLS) |
| -nothreading / -corelimit | eliminates ~16% spin | TRADE/UNPROVEN — heavy hammer, only if spin survives everything else |
| bEnableInvaderEnemy=False | RAM strong, CPU softer | TRADE (loses raids) |
| BaseCampWorkerMaxNum 15→12 | biggest sim lever | TRADE (feature cut — user veto class) |
| Render [SystemSettings] keys | ~0 on headless DS | SKIP |

Launch args verified present on test: -useperfthreads -NoAsyncLoadingThread
-UseMultithreadForDS (the community-standard set).

## RE verification (rev-1, full report at C:\Users\Sanveed\palworld-idle-cpu-report.md)

- The ~16% 'busy-spin' cluster (0x7760f40) is FTaskThreadAnyThread::ProcessTasks
  (TaskGraph.cpp): TSC-budgeted spin (dynamic budget ~700-990 ticks/round via
  worker argument, hard cap 52 rounds) with pthread_cond_wait fallback. It is
  bounded and task-feed-driven (real workload, not misconfig). NO INI knob
  exists — TaskGraph.NumThreads/TargetHeartbeat/NumWorkerThreads are all absent
  from the binary's rodata (dead UE4-era keys confirmed).
- The pthread_sigmask storm is SDL SIGPIPE-protected file I/O (signal-13 block
  around write() at 0xba44064, caller loops over chunks at 0xba44470), NOT UE
  sleep/tick logic. NetServerMaxTickRate is NOT read by the sleep/event
  implementations (0x77b5d70 nanosleep / 0x77b6160 pthread_cond_wait neither
  call sigmask). The earlier 'sigmask scales with tick rate' framing is
  RETRACTED; sigmask correlates with SDL write activity instead.
- Consequence: the tick-rate A/B now measures the main-loop dispatch slice
  only. Expected win reduced vs the original estimate; the A/B result is the
  truth regardless.

## A/B design (one variable per arm, 15-min settled intervals, cpu-interval.sh)

- Arm 1: tick 120 (current test state) — baseline
- Arm 2: tick 60 (env NETSERVERMAXTICKRATE=60, recreate — config.sh sed-patches
  Engine.ini from env at boot, so the env is the source of truth)
- Arm 3: tick 60 + [Engine.Engine] fixed-frame block appended to Engine.ini
  (config.sh only manages the IpNetDriver section; other sections survive)
- Arm 4 (test-only, NOT promoted): AutoSaveSpan 300 — durability trade,
  promotion requires explicit user acceptance

Live already runs tick 60 (original Coolify compose set it) — the user has
played on it at 60 without complaint, which is the strongest feature-neutrality
evidence available for the tick lever.

## ARM 1 vs ARM 2 — MEASURED (2026-08-05, populated 683-pal world, same 5-mod stack)

cpu-interval.sh (per-30s /proc/<pid>/stat deltas, game-thread process):

| Metric | Arm 1 (tick 120) | Arm 2 (tick 60) | Delta |
|---|---|---|---|
| samples | 13 | 26 | — |
| mean | 55.23% | 42.19% | -13.0 pts |
| median | 53% | 40% | -13 pts |
| base avg (non-spike) | 49.9% | 35.5% | -14.4 pts |
| spike avg (60s census) | 61.5% | 50.0% | -11.5 pts |

Verdict: NetServerMaxTickRate 120→60 saves ~13% CPU on the populated world —
larger than the conservative estimate (the frame-limiter sleep path and main-loop
dispatch both drop with the tick cap; the sigmask attribution retraction does not
change the measured outcome). Live already runs 60 — this confirms production
config and aligns test. Feature impact: none observed in simulation (same work
output; worker-AI significance-gated per earlier proof); player-present
validation still pending per oracle gate.

## Deployment trap discovered during arm 3 (2026-08-05)

Engine.ini on these containers is WRITE-BACK protected: UE5.1 marks the config
hierarchy dirty when the file is corrupt/unparseable, and the NEXT restart's
shutdown write-back regenerates the game's 69-line default, clobbering any
clean copy deployed in between (observed: nested-heredoc append corrupted the
file → game regenerated → docker cp'd fixed-frame block vanished on restart).
Safe sequence: docker stop → docker cp full ini (chown steam:steam) → docker
start. Manual sed edits of an intact file survive restarts (only dirty when
corrupted/missing sections). Never append via nested heredocs through
docker exec/ssh quoting layers — build the full file on the host with docker cp.

## ARM 3 — fixed-frame-rate block on top of tick 60: NO GAIN (measured)

30 samples, same world/mod stack: mean 40.83% vs arm-2's 42.19% (-1.36 pts),
base avg 36.6% vs 35.5% (+0.4 pts) — statistically noise. The tick cap already
frame-limits the server loop; bUseFixedFrameRate adds nothing measurable.
VERDICT: revert the block (test returns to tick-60-only == live config). No
inconsistency risk remains since the frame limiter follows the tick cap.

## ARM 4 — AutoSaveSpan 30→300 on top of tick 60 (TEST-ONLY): -1.8 pts

30 samples, same world/mod stack: mean 40.37% vs arm-2's 42.19% (-1.82 pts),
base avg 33.7% vs 35.5% (-1.8 pts) — small but consistent with the T4 profile
(~1.2% save pipeline: blake3 on IOThreadPool + PalSave pools). The blake3
checksum runs 10x less often; save micro-spikes disappear.

DURABILITY TRADE (not promoted, user's call): AutoSaveSpan=300 means a crash
loses up to 5 min of world progress vs 30s at the default. stall-watch.sh
bounds the damage (stages recovery assets within 15 min of a stall), and
bIsUseBackupSaveData=true keeps hourly snapshots. Test-only until the user
accepts the trade.

## FINAL A/B TABLE (all arms: populated 683-pal world, identical 5-mod stack)

| Arm | Config | n | mean | median | base avg | vs arm 1 |
|---|---|---|---|---|---|---|
| 1 | tick 120, autosave 30 | 13 | 55.23% | 53% | 49.9% | — |
| 2 | tick 60, autosave 30 | 26 | 42.19% | 40% | 35.5% | -13.0 pts |
| 3 | tick 60 + fixed-frame | 30 | 40.83% | 39% | 36.6% | no gain vs 2 |
| 4 | tick 60, autosave 300 | 30 | 40.37% | 39% | 33.7% | -1.8 pts vs 2 (test-only) |

LIVE ALREADY RUNS ARM 2 (tick 60, autosave 30) — verified on the live volume.
The A/B validates production's existing choice; test now matches it.

## BONUS FIND — config.lua was INERT in ServerMaintenance + WorkProbe

The loaders did `pcall(dofile, path)` then read the module-local CFG table.
dofile executes config.lua in the GLOBAL environment (`_G.CFG = {...}`), so the
values never reached the local table — "config loaded" printed but nothing
applied. ServerMaintenance's "working" config was a coincidence (config values
== defaults); WorkProbe's interval_sec was always 60 regardless of config.lua
(observed 60→60 across formats). The planned SM auto_trim A/B flip would have
silently done nothing. Fix (fac6b73): after dofile, merge _G.CFG into the local
CFG (missing keys keep defaults). VERIFIED: WorkProbe now loads interval_sec=300
from config.lua and schedules at 300s. PSO unaffected (hardcoded constants).
