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
