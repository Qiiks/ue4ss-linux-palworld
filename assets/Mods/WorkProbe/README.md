# WorkProbe — work-progress catch-up semantics probe

Measures whether a significance-scaled base-camp tick **credits** full elapsed
Δt to a `UPalWorkProgress` (rate preserved → significance tuning is free) or
**drops** the unticked time (rate lost → far-tier tuning costs output).

This was a community-first measurement: no public data existed on the catch-up
semantics. **ANSWERED (2026-08-02) — see Analysis below: work progresses in
throttled batch cycles; declared rate ≠ effective rate; keep native tiers.**

## Install

Copy `WorkProbe/` into `Pal/Binaries/Linux/ue4ss/Mods/` and add to
`mods.txt`:

```
WorkProbe : 1
```

Optional: copy `config.example.lua` to `config.lua` and edit.

## What it logs

Every `interval_sec` (default 60s) on the game thread, for up to
`max_objects` `UPalWorkProgress` instances:

| Field | Meaning |
|---|---|
| `tick` | `ProgressTimeSinceLastTick` — accumulates between serviced ticks; if it climbs toward the gate interval (~10s) between services, the gate credits elapsed time |
| `rate` | `AutoWorkSelfAmountBySec` — declared per-second work rate |
| `minint` | `TickProcessMinInterval` — the work's own minimum service cadence |
| `remain` | `GetRemainWorkAmount()` — BlueprintPure accessor (pcall'd) |

Log: `ue4ss/Mods/WorkProbe/workprobe.log` (absolute path; the game cwd is
`/palworld/Pal/Binaries/Linux`).

## Analysis

**Answer: work progresses in throttled batch cycles.** With a player in a base
on the populated world, 32 live `UPalWorkProgress` instances (rates 2-120/s)
were observed; obj=30 (declared 120/s) cycled remain 6396 → 4044 → 6304 → 533
→ 2764 → 5018 → 7249 → 1478 — a -5770 consumption burst every ~3 samples
with +2230 re-assignment additions between: discrete batch consumption, not
smooth drain. Declared ≠ effective (120/s × 66s = 7,920 expected vs ~5,770
per ~200s ≈ 29-44/s effective): the significance gate throttles work below
theoretical rate. rate=0 objects stay frozen (worker-driven work, no
self-progress, consistent with frozen-pawn proof).

**Decision: significance-tier tuning costs output but work completes — the
native tiers already are the feature-preserving compromise. No nerf-tier pak.**

Note: the earlier "no live work objects" finding was the fork's
ForEachUObject_Chunked walk bug (4-chunk 262k cap + EInternalObjectFlags==0
skip), fixed upstream as PR #10 — the probe is only meaningful on a
walk-fixed build.

Offline: slope of `remain` vs wall-clock vs the declared `rate` decides
catch-up semantics; `tick`'s reset pattern corroborates. A/B: patch the far
significance tier (pak) and compare per-wall-hour output.

## Thread-safety

UE objects and UFunction calls run **only** on the game thread (the
`LoopInGameThreadWithDelay` timer rides the EngineTick hook). Calling UE APIs
from the async thread SIGSEGVs on this fork (proven twice) — never do that.
