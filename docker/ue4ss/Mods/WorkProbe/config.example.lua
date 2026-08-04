-- WorkProbe configuration (optional; delete or rename this file to use defaults).
-- Place as config.lua next to the mod (ue4ss/Mods/WorkProbe/config.lua).
--
-- IMPORTANT: the loader dofile()s this file in the GLOBAL environment, then
-- merges _G.CFG into the mod's defaults (missing keys keep defaults). It MUST
-- set a CFG table — bare globals (enabled = true) are never read.

CFG = {
    -- Enable/disable the probe entirely
    enabled = true,

    -- Probe interval in seconds (game-thread timer; EngineTick-riding).
    -- 300s default in production: the catch-up experiment is answered, and the
    -- 60s full-census walk showed up as the alternate-sample CPU spike.
    interval_sec = 300,

    -- Cap the number of UPalWorkProgress objects sampled per run
    max_objects = 32,

    -- Absolute log path (game cwd is /palworld/Pal/Binaries/Linux)
    log_path = "/palworld/Pal/Binaries/Linux/ue4ss/Mods/WorkProbe/workprobe.log",

    -- Read remain-work amounts via GetRemainWorkAmount() reflection call
    read_remain = true,
}
