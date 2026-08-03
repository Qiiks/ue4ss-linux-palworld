# ServerMaintenance

Diagnostics-first telemetry mod for the Palworld Linux dedicated server
(Qiiks/ue4ss-linux-palworld fork). Measures the **memory climb shape**
(four-signal discriminator): RSS growth, Lua heap, swap, UObject census.

**Phase 1 is diagnostics only** — no GC trigger, no entity cleanup. Outputs
go to `mem-snapshots.log` in the mod directory.

## Install

1. Copy this directory to the server's UE4SS Mods folder:
   `ue4ss/Mods/ServerMaintenance/`
2. Add `ServerMaintenance : 1` to `ue4ss/Mods/mods.txt`
3. Restart the server. Snapshots begin on the first LoopAsync tick.

## Config

Copy `config.example.lua` to `config.lua` in the mod directory and edit.
Every feature can be disabled independently (see the example file). The
config file is read at mod load; a server restart is required to apply.

## Console commands

Registered via `RegisterConsoleCommandGlobalHandler` (game thread — safe):

| Command        | Effect                                                   |
| -------------- | -------------------------------------------------------- |
| `pso_memreport` | Write an immediate snapshot                              |
| `pso_census`    | Force a UObject census (GetObjectCount, game thread)     |
| `pso_trim`      | Manual TrimAllocator probe (before/after RSS delta)      |

NOTE: on this fork build RCON-driven console commands do NOT reach the mod's
handler (game replies "Unknown command"); the commands are for future use once
the EngineTick/game-thread dispatch is fixed, or when run in-game.

## Snapshot format

```
<epoch> rss_kb=<VmRSS> swap_kb=<VmSwap> lua_kb=<Lua heap> objs=<UObject count|n/a> reason=<tick|console|world-init>
<epoch> census objs=<UObject count> reason=<world-init|console>
<epoch> trim_probe before_kb=<RSS> after_kb=<RSS> delta_kb=<diff> ok=<bool> reason=console
```

## Thread-safety rules (learned the hard way)

- **`LoopAsync` is the async-thread timer** (works on all builds — 144/144
  ticks proven). `LoopInGameThreadWithDelay`/`ExecuteInGameThreadWithDelay`
  are the **game-thread** timers — dead until the fork's UEngine::Tick fix
  (slot 0x308 + AOB fallback, PRs #6/#7), now working.
- **NEVER call UE-facing APIs from the LoopAsync thread** — `GetObjectCount`
  (v1.3) and `TrimAllocator` (TrimProbe) both SIGSEGV the process (exit 139).
  Async snapshots use pure stdlib only (`/proc`, `os.time`,
  `collectgarbage("count")`).
- **UE APIs on the game thread only** — via `LoopInGameThreadWithDelay` (works
  post-EngineTick-fix), `RegisterInitGameStatePostHook` (per world init), or
  console handlers.
- **`Loop*WithDelay` = auto-looping — NEVER re-arm it inside the callback**
  (doubles timers exponentially; the v1.1→v1.2 WorkProbe bug).
  `Execute*WithDelay` = one-shot.
- **`collectgarbage("collect")` on a state holding ~274k UObject userdata
  SIGSEGVs** — use `collectgarbage("count")` without collecting.

## Changelog

- v1.7 — config-gated automated game-thread TrimAllocator probe
  (`auto_trim`, default OFF — the soak baseline must stay clean; rides the
  now-working EngineTick path).
- v1.6 — game-thread UObject census via `LoopInGameThreadWithDelay` (the
  `objs=` field fills every snapshot post-EngineTick-fix).
- v1.5 — config file support (config.lua, enable/disable per feature).
- v1.4 — async-safe LoopAsync snapshots (pure stdlib); crash lesson from v1.3
  (GetObjectCount from async thread = SIGSEGV); game-thread census hook.
