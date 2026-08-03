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

- **`LoopAsync` is the only working periodic timer** on the fork build
  (EngineTick AOB scan fails; `LoopInGameThreadWithDelay` never fires).
- **NEVER call UE-facing APIs from the LoopAsync thread** — `GetObjectCount`
  (v1.3) and `TrimAllocator` (TrimProbe) both SIGSEGV the process (exit 139).
  Async snapshots use pure stdlib only (`/proc`, `os.time`,
  `collectgarbage("count")`).
- **UE APIs only on the game thread** — via `RegisterInitGameStatePostHook`
  (fires per world init) or console handlers.

## Changelog

- v1.4 — async-safe LoopAsync snapshots (pure stdlib); crash lesson from v1.3
  (GetObjectCount from async thread = SIGSEGV); game-thread census hook.
- v1.5 — config file support (config.lua, enable/disable per feature).
