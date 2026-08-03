# WorkProbe — work-progress catch-up semantics probe

Measures whether a significance-scaled base-camp tick **credits** full elapsed
Δt to a `UPalWorkProgress` (rate preserved → significance tuning is free) or
**drops** the unticked time (rate lost → far-tier tuning costs output).

This is a community-first measurement: no public data exists on the catch-up
semantics (the decisive question for base-camp significance tuning).

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

Offline: slope of `remain` vs wall-clock vs the declared `rate` decides
catch-up semantics; `tick`'s reset pattern corroborates. A/B: patch the far
significance tier (pak) and compare per-wall-hour output.

## Thread-safety

UE objects and UFunction calls run **only** on the game thread (the
`LoopInGameThreadWithDelay` timer rides the EngineTick hook). Calling UE APIs
from the async thread SIGSEGVs on this fork (proven twice) — never do that.
