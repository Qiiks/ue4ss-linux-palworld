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
