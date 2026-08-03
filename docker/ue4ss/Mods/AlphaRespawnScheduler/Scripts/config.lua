-- Alpha Respawn Scheduler configuration
-- Stop Palworld or PalServer before editing, then restart it.

return {
    -- Default field Alpha cooldown in real-time seconds.
    -- 1800 seconds = 30 minutes.
    default_cooldown_seconds = 1800,

    -- "active" pauses cooldowns while the game/server is closed.
    -- "wall" includes time spent offline.
    clock_mode = "active",

    -- Save remaining cooldowns at this interval while a timer is active.
    -- Starts and completions are always saved immediately.
    checkpoint_seconds = 15,

    -- How often an expired timer searches for a world-partitioned spawner that
    -- is not currently tracked. This scan runs only while a timer is due.
    expired_scan_seconds = 5,

    -- Optional exact spawner-name overrides. The log prints the stable name
    -- when a cooldown begins, making it safe to copy here.
    boss_overrides = {
        -- ["PAL_BOSS_SpawnerName"] = 900,
    },

    -- Additional lifecycle, checkpoint, and discovery messages in UE4SS.log.
    verbose_logging = false,
}
