-- ServerMaintenance — diagnostics-first server telemetry mod (v1.6)
-- Purpose: measure the memory climb shape (four-signal discriminator):
--   RSS growth | Lua heap | swap | UObject census
-- Phase 1 is DIAGNOSTICS ONLY. No GC trigger, no entity cleanup.
--
-- v1.3 LESSON (crash evidence): calling GetObjectCount() from the LoopAsync
-- thread SIGSEGV'd the game (exit 139, sig=11, right at the first snapshot).
-- The fork's UObject-array API is NOT safe from the async thread — it races
-- the game thread's object-array mutations. v1.4:
--   * LoopAsync snapshots capture ONLY async-safe telemetry: /proc RSS/swap,
--     collectgarbage("count") (Lua heap), os.time. NO UE API calls.
--   * UObject census runs ONCE per world load from a game-thread hook
--     (RegisterInitGameStatePostHook — fires on the game thread, safe).
--   * TrimAllocator is manual-only (pso_trim console cmd, game thread).
--
-- v1.5: config file support (config.lua, see config.example.lua).
--
-- v1.6: PERIODIC game-thread census. The fork fix b23ad7c corrected the
-- UEngine::Tick vtable slot (0x308, was 0x2F0=PostExit), so
-- LoopInGameThreadWithDelay now dispatches on the game thread (proven by
-- TickProbe: 16 ticks @5s cadence, zero crashes). The census no longer
-- depends on RegisterInitGameStatePostHook (which never fires on a
-- playerless server): it now runs continuously on the game thread at
-- CFG.census_interval_sec, updating the objs value that every snapshot row
-- carries — completing the oracle four-signal (RSS + UObject count + swap +
-- Lua heap) at snapshot cadence. Falls back to the old one-shot hook census
-- if LoopInGameThreadWithDelay is unavailable.
--
-- v1.7: CONFIG-GATED automated game-thread Trim probe (default OFF). The
-- four-signal soak (objs FLAT while RSS climbs 3-6MB/hr) points at allocator
-- pools (FMallocBinned2), not object growth — Trim is the lever. The fork
-- API TrimAllocator() is NOT safe from LoopAsync (SIGSEGV, proven twice);
-- with EngineTick dispatch fixed, it can now run on the game thread via
-- LoopInGameThreadWithDelay. auto_trim=false by default: the 48h soak must
-- finish uncontaminated first (the climb is the measurement). Flip
-- auto_trim=true on test to A/B the trim effect after the baseline.
-- LoopInGameThreadWithDelay is AUTO-LOOPING — never re-arm it inside its
-- own callback (timer avalanche; see WorkProbe v1.2).
--
-- Thread-safety rule for this fork: if it touches UE objects, it must run on
-- the game thread. Pure stdlib (io, os) is safe from LoopAsync. The mod's Lua
-- state is serialized by the fork's thread-actions mutex, so reading the
-- latest_objs number from the LoopAsync thread is safe.

local TAG = "[ServerMaintenance]"

-- ---------------------------------------------------------------------------
-- Configuration (defaults; overridden by config.lua in the mod directory)
-- ---------------------------------------------------------------------------
local CFG = {
    snapshots             = true,
    snapshot_interval_sec = 300,
    tick_ms               = 30000,
    census                = true,
    census_interval_sec   = 300,
    console_commands      = true,
    trim                  = true,
    -- v1.7: automated game-thread trim probe (default OFF — the soak baseline
    -- must be measured uncontaminated first; flip to true for the A/B phase).
    auto_trim             = false,
    trim_interval_sec     = 3600,
}

-- Absolute-in-container path (game cwd is /palworld/Pal/Binaries/Linux).
local MOD_DIR_CANDIDATES = {
    "/palworld/Pal/Binaries/Linux/ue4ss/Mods/ServerMaintenance",
    "/tmp/ServerMaintenance",
}

local function load_config()
    for _, dir in ipairs(MOD_DIR_CANDIDATES) do
        local path = dir .. "/config.lua"
        local ok, err = pcall(dofile, path)
        if ok then
            if type(CFG) ~= "table" then
                print(TAG .. " WARNING: config.lua replaced CFG with a non-table; ignoring")
                return false
            end
            print(TAG .. " config loaded from " .. path)
            return true
        end
        -- dofile error for a missing file is fine; other errors are config bugs
        if err and not tostring(err):find("cannot open") then
            print(TAG .. " WARNING: config error in " .. path .. ": " .. tostring(err))
        end
    end
    print(TAG .. " no config.lua found; using defaults")
    return false
end

load_config()

-- ---------------------------------------------------------------------------
-- Derived settings
-- ---------------------------------------------------------------------------
local TICK_MS = CFG.tick_ms
local SNAPSHOT_INTERVAL_SEC = CFG.snapshot_interval_sec
local CENSUS_INTERVAL_SEC = CFG.census_interval_sec or 300
local CENSUS_MS = CENSUS_INTERVAL_SEC * 1000
local TRIM_INTERVAL_SEC = CFG.trim_interval_sec or 3600
local TRIM_MS = TRIM_INTERVAL_SEC * 1000

local SNAPSHOT_PATH_CANDIDATES = {}
for _, dir in ipairs(MOD_DIR_CANDIDATES) do
    table.insert(SNAPSHOT_PATH_CANDIDATES, dir .. "/mem-snapshots.log")
end
table.insert(SNAPSHOT_PATH_CANDIDATES, "/tmp/mem-snapshots.log")

local SNAPSHOT_PATH = nil

local last_snapshot = 0 -- 0 => force a startup snapshot on first tick
local latest_objs = "n/a" -- written on game thread, read by snapshots

-- ---------------------------------------------------------------------------
-- Feature detection
-- ---------------------------------------------------------------------------
local function detect_features()
    local features = {}
    features.timer_loopasync = type(LoopAsync) == "function"
    features.timer_gamethread = type(LoopInGameThreadWithDelay) == "function"
    features.obj_count = type(GetObjectCount) == "function"
    features.trim = type(TrimAllocator) == "function"
    features.init_state_hook = type(RegisterInitGameStatePostHook) == "function"
    features.console_handler = type(RegisterConsoleCommandGlobalHandler) == "function"
    print(TAG .. " features: LoopAsync=" .. tostring(features.timer_loopasync)
        .. " LoopInGameThreadWithDelay=" .. tostring(features.timer_gamethread)
        .. " GetObjectCount=" .. tostring(features.obj_count)
        .. " TrimAllocator=" .. tostring(features.trim)
        .. " InitGameStatePostHook=" .. tostring(features.init_state_hook)
        .. " ConsoleHandler=" .. tostring(features.console_handler))
    print(TAG .. " config: snapshots=" .. tostring(CFG.snapshots)
        .. " interval=" .. SNAPSHOT_INTERVAL_SEC
        .. " census=" .. tostring(CFG.census)
        .. " census_interval_sec=" .. CENSUS_INTERVAL_SEC
        .. " console_commands=" .. tostring(CFG.console_commands)
        .. " trim=" .. tostring(CFG.trim)
        .. " auto_trim=" .. tostring(CFG.auto_trim)
        .. " trim_interval_sec=" .. TRIM_INTERVAL_SEC)
    return features
end

-- ---------------------------------------------------------------------------
-- Telemetry primitives (ALL async-thread safe: pure stdlib only)
-- ---------------------------------------------------------------------------
local function read_proc_stat(field)
    local ok, f = pcall(io.open, "/proc/self/status", "r")
    if not ok or not f then return -1 end
    local val = -1
    for line in f:lines() do
        if line:sub(1, #field) == field then
            local num = line:match("(%d+)")
            if num then val = tonumber(num) end
            break
        end
    end
    f:close()
    return val
end

local function append_line(text)
    if not SNAPSHOT_PATH then
        for _, cand in ipairs(SNAPSHOT_PATH_CANDIDATES) do
            local ok, f = pcall(io.open, cand, "a")
            if ok and f then
                f:close()
                SNAPSHOT_PATH = cand
                print(TAG .. " snapshot path: " .. cand)
                break
            end
        end
    end
    if not SNAPSHOT_PATH then
        print(TAG .. " ERROR: no writable snapshot path found")
        return false
    end
    local ok, f = pcall(io.open, SNAPSHOT_PATH, "a")
    if not ok or not f then return false end
    f:write(text .. "\n")
    f:close()
    return true
end

local function take_snapshot(reason)
    local rss = read_proc_stat("VmRSS:")
    local swap = read_proc_stat("VmSwap:")
    local lua_kb = collectgarbage("count")
    local line = string.format("%d rss_kb=%d swap_kb=%d lua_kb=%.0f objs=%s reason=%s",
        os.time(), rss, swap, lua_kb, tostring(latest_objs), reason)
    print(TAG .. " snapshot: " .. line)
    append_line(line)
end

-- ---------------------------------------------------------------------------
-- UObject census — GAME THREAD ONLY (fork API; SIGSEGV from LoopAsync, proven)
-- ---------------------------------------------------------------------------
local function take_census(reason)
    local objs = "n/a"
    if type(GetObjectCount) == "function" then
        local ok, n = pcall(GetObjectCount)
        if ok then objs = tonumber(n) end
    end
    latest_objs = objs
    print(TAG .. " census: " .. os.time() .. " objs=" .. tostring(objs) .. " reason=" .. reason)
end

-- ---------------------------------------------------------------------------
-- Scheduler — LoopAsync (PROVEN working on this fork build)
-- ---------------------------------------------------------------------------
local features = detect_features()

local function maintenance_tick()
    local now = os.time()
    if now - last_snapshot >= SNAPSHOT_INTERVAL_SEC then
        last_snapshot = now
        take_snapshot("tick")
    end
end

local function schedule_tick()
    if CFG.snapshots and features.timer_loopasync then
        LoopAsync(TICK_MS, function()
            maintenance_tick()
            return false
        end)
        print(TAG .. " using LoopAsync(" .. TICK_MS .. "ms) [proven dispatch path]")
    elseif not CFG.snapshots then
        print(TAG .. " snapshots disabled in config")
    else
        print(TAG .. " ERROR: no LoopAsync; telemetry disabled")
    end
end

-- Periodic game-thread census (v1.6 — works thanks to fork fix b23ad7c:
-- UEngine::Tick slot 0x308; LoopInGameThreadWithDelay now dispatches).
local function schedule_census()
    if not CFG.census then
        print(TAG .. " census disabled in config")
        return
    end
    if features.timer_gamethread then
        LoopInGameThreadWithDelay(CENSUS_MS, function()
            take_census("periodic")
        end)
        print(TAG .. " periodic game-thread census every " .. CENSUS_INTERVAL_SEC .. "s via LoopInGameThreadWithDelay")
    elseif features.init_state_hook then
        -- Fallback: one-shot census at world init (fires on the game thread)
        RegisterInitGameStatePostHook(function()
            take_census("world-init")
        end)
        print(TAG .. " armed InitGameStatePostHook census (fallback path)")
    else
        print(TAG .. " WARNING: no game-thread timer or init hook; census unavailable")
    end
end

-- ---------------------------------------------------------------------------
-- RCON console commands (game thread — safe)
-- ---------------------------------------------------------------------------
local function console_memreport()
    print(TAG .. " manual memreport requested")
    take_snapshot("console")
end

local function console_census()
    print(TAG .. " manual census requested")
    take_census("console")
end

local function console_trim()
    print(TAG .. " manual trim requested (NOT auto — game thread via RCON)")
    local before = read_proc_stat("VmRSS:")
    local ok = false
    if type(TrimAllocator) == "function" then
        ok = pcall(TrimAllocator)
    end
    local after = read_proc_stat("VmRSS:")
    local line = string.format("%d trim_probe before_kb=%d after_kb=%d delta_kb=%d ok=%s reason=%s",
        os.time(), before, after, (before - after), tostring(ok), "console")
    print(TAG .. " " .. line)
    append_line(line)
end

-- v1.7: automated game-thread trim probe. Same measurement as pso_trim but
-- scheduled on the game thread (TrimAllocator SIGSEGVs from LoopAsync).
-- Auto-looping LoopInGameThreadWithDelay — single registration, no re-arm.
local function schedule_auto_trim()
    if not CFG.auto_trim then
        print(TAG .. " auto-trim disabled in config (default; soak baseline untouched)")
        return
    end
    if not features.timer_gamethread then
        print(TAG .. " WARNING: no game-thread timer; auto-trim unavailable")
        return
    end
    if not features.trim then
        print(TAG .. " WARNING: TrimAllocator unavailable in this fork build; auto-trim disabled")
        return
    end
    LoopInGameThreadWithDelay(TRIM_MS, function()
        local before = read_proc_stat("VmRSS:")
        local ok = pcall(TrimAllocator)
        local after = read_proc_stat("VmRSS:")
        local line = string.format("%d trim_probe before_kb=%d after_kb=%d delta_kb=%d ok=%s reason=auto",
            os.time(), before, after, (before - after), tostring(ok))
        print(TAG .. " " .. line)
        append_line(line)
    end)
    print(TAG .. " auto-trim scheduled every " .. TRIM_INTERVAL_SEC .. "s on the game thread (auto-looping)")
end

if CFG.console_commands and features.console_handler then
    RegisterConsoleCommandGlobalHandler("pso_memreport", function()
        console_memreport()
    end)
    RegisterConsoleCommandGlobalHandler("pso_census", function()
        console_census()
    end)
    if CFG.trim then
        RegisterConsoleCommandGlobalHandler("pso_trim", function()
            console_trim()
        end)
    end
    print(TAG .. " registered console commands: pso_memreport, pso_census"
        .. (CFG.trim and ", pso_trim" or ""))
end

schedule_census()
schedule_auto_trim()
schedule_tick()
print(TAG .. " loaded v1.7.0; diagnostics-first phase. Snapshots -> " .. SNAPSHOT_PATH_CANDIDATES[1])
