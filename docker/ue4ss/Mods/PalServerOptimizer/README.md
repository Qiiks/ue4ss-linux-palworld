# PalServerOptimizer (fork, v1.1)

Workshop item 3767052724 ("Love Deadlock Players" v1.0.0) — server-side
UE4SS Lua mod: ragdoll optimization, importance-aware mesh tick, budgeted
dropped-item physics.

## v1.1 change (self-arm fix)

The as-shipped v1.0 armed all schedulers (initial scan, player-location
refresh, drop queue, monster mesh-tick queue, 60s summary) from
`RegisterInitGameStatePostHook` — which **never fires on the obnyis image**:
the world (and InitGameState) loads during boot, BEFORE UE4SS mods load
(30s init sleep), so the hook arms too late and misses it. Net effect:
PSO loaded but its loops never ran (initial scan, drop checks, mesh tick
throttling, summaries all absent from logs).

v1.1 self-arms from mod load via `ExecuteInGameThreadWithDelay(2000, ...)`
(the game-thread timer, which works on the fork fix b23ad7c — UEngine::Tick
vtable slot 0x308, was 0x2F0=PostExit). The InitGameStatePostHook block is
kept as a belt-and-braces re-arm for a possible world reload.

## Install
Drop into `ue4ss/Mods/PalServerOptimizer/` (Scripts/main.lua), enable in
mods.txt (`PalServerOptimizer : 1`), restart. Load line:
`[PalServerOptimizer] loaded; ragdoll, importance-aware mesh tick, and
budgeted dropped-item optimization are active`.

## Verify it's actually running
`[PalServerOptimizer] initial scan complete: ...` then a `summary:` line
every 60s with moving stats (mesh_tracked / drop_checks / drops_stopped).
