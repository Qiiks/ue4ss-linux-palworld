-- WorkProbe — work-progress catch-up semantics probe (v1.8)
-- v1.8: camp association. Class dumps (localcc/PalworldModdingKit) show
-- UPalWorkBase.BaseCampIdBelongTo (FGuid, Replicated) links each work
-- object to a camp, and UPalBaseCampModel has ID + Transform +
-- SignificanceInfo. Goal: bucket work objects by camp, compute
-- camp→player distance → significance tier, then measure effective rate
-- per tier (the kill-shot for the tuning question). FGuid/FTransform
-- struct exposure on this fork's Lua binding is unknown — probe
-- defensively (pcall + tostring + nested member tries) and log what
-- actually reads.
-- v1.7: chunk-index bucketing. The walk fix restored SOME world visibility
-- (fish shadows, drops, controllers) but still zero pals/base camps with a
-- player in a working base. The Lua callback receives (object, chunk_index,
-- object_index) — bucket live objects by chunk to find where the walk
-- stops or what the later chunks contain.
-- v1.6: control census — bucket EVERY live (non-reflection) object by class
-- name and log the top classes. Settles whether the ForEachUObject walk sees
-- world actors at all (SM census shows objs=403389 with a player in-world;
-- Work-family live=0 needs a control before being trusted).
-- v1.5: the v1.4 live bucket was polluted by reflection objects
-- (Function/DelegateFunction/ScriptStruct/Enum entries created at engine
-- init occupy the first GUObjectArray positions, so the 60-sample cap
-- always cut off before world instances). v1.5 excludes reflection
-- prefixes entirely, logs instance-like entries only (cap 200), and
-- parses the class from the first full-name token.
-- v1.3.1: census now categorizes entries (Class CDO / Default__ CDO / live
-- instance) and logs EVERY live instance name — the v1.3 run found the 3
-- "work objects" are class default templates, not live state; whether ANY
-- live UPalWorkProgress instance exists in a working base is the open
-- question.
-- v1.3: identity via GetFullName() (the binding PSO proves works —
-- GetClass():GetName()/GetOuter():GetName() return nil on this fork).
-- Adds a NAME CENSUS: every object whose full name contains "Work" is
-- grouped by class name and counted, because the observed world has
-- visible working pals but ZERO live UPalWorkProgress state (2723 probes,
-- all slots idle) — the work objects must carry a different class in
-- this build (class dumps were 1.0.1-era kit; server is 1.0.2.101103).
-- v1.1: log object identity (address + class + outer) so idle singletons are
-- distinguishable from rotating work assignments (playerless worlds appear to
-- freeze work simulation entirely — all observed slots stay at zero).
-- v1.2 FIX: LoopInGameThreadWithDelay is AUTO-LOOPING on this fork
-- (LuaMod.cpp is_looping=true; the process path re-arms execute_at and keeps
-- the action Active). v1.1 re-armed from inside its own callback, doubling
-- timers exponentially (observed: 6 runs in 8s at run ~105). Single
-- registration, no re-arm.
-- Purpose: answer the community's open question (no public data exists):
--   does a significance-scaled base-camp tick CREDIT full elapsed Δt to a
--   UPalWorkProgress (rate preserved → significance tuning is free), or DROP
--   the unticked time (rate lost → far-tier tuning costs output)?
--
-- Method: sample UPalWorkProgress objects on the game thread every
-- CFG.interval_sec (proven timer: LoopInGameThreadWithDelay rides the
-- EngineTick hook, fixed on this fork by the vtable-slot/AOB work; PSO's
-- 60s loops are the live proof).
--
-- Per object we log:
--   ProgressTimeSinceLastTick — Transient float; accumulates between
--     serviced ticks. If it climbs toward ~the gate interval (e.g. 10s)
--     between services, the gate credits elapsed time.
--   AutoWorkSelfAmountBySec — the declared per-second work rate.
--   TickProcessMinInterval — the work's own minimum service cadence.
--   GetRemainWorkAmount()  — BlueprintPure accessor; pcall'd UFunction
--     invocation (proven safe on the game thread; never on LoopAsync).
--
-- Analysis (offline): slope of remain-work vs wall-clock vs the declared
-- rate decides catch-up semantics; ProgressTimeSinceLastTick's reset
-- pattern corroborates. A/B: patch the far significance tier (pak) and
-- compare per-wall-hour output.
--
-- Thread-safety: UE objects and UFunction calls ONLY on the game thread
-- (async-thread UE API use SIGSEGVs on this fork — proven twice).

local TAG = "[WorkProbe]"

local CFG = {
    enabled         = true,
    interval_sec    = 60,
    max_objects     = 32,
    log_path        = "/palworld/Pal/Binaries/Linux/ue4ss/Mods/WorkProbe/workprobe.log",
    read_remain     = true,
}

local MOD_DIR_CANDIDATES = {
    "/palworld/Pal/Binaries/Linux/ue4ss/Mods/WorkProbe",
    "/tmp/WorkProbe",
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
        if err and not tostring(err):find("cannot open") then
            print(TAG .. " WARNING: config error in " .. path .. ": " .. tostring(err))
        end
    end
    print(TAG .. " no config.lua found; using defaults")
    return false
end

load_config()

-- ---------------------------------------------------------------------------
-- Logging (absolute path; game cwd is /palworld/Pal/Binaries/Linux)
-- ---------------------------------------------------------------------------
local LOG_PATH = nil
local LOG_PATH_CANDIDATES = { CFG.log_path, "/tmp/workprobe.log" }

local function is_valid(object)
    if not object then return false end
    local ok, valid = pcall(function()
        local addr = object:GetAddress()
        return addr ~= nil and addr ~= 0
    end)
    return ok and valid
end

local function read_any(obj, name)
    local ok, val = pcall(function() return obj[name] end)
    if not ok then return nil end
    return val
end

local function tostr_safe(v)
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "<tostring-failed>"
end

-- v1.8: camp association + tier instrumentation (all defensive)
local camp_models = {}
local camp_locations = {}
local work_camps = {}
local camp_significance = {}

local function classify_struct(value, label)
    -- try nested member access for structs (FGuid/FTransform/FPalBaseCampSignificanceInfo)
    -- NOTE: direct member reads return TrivialObject userdata; the proven
    -- pattern (PSO get_remote_value) is member:get() to resolve remote values.
    -- v1.8.6: struct members that are themselves structs come back as Lua
    -- TABLES (Translation=table:...) — recurse one level for X/Y/Z.
    -- v1.8.7 FIX: NEVER recurse into non-table values — TrivialObject member
    -- reads return THEMSELVES (same address), so unbounded recursion on a
    -- TrivialObject loops forever → Lua stack overflow → game thread wedge.
    -- Recursion is bounded: tables only, one level, X/Y/Z/W members only.
    if value == nil then return label .. "=nil" end
    if type(value) == "table" then
        local parts = {}
        -- FGuid tables carry A/B/C/D; FTransform tables carry X/Y/Z/W — probe
        -- BOTH sets (absent members just fail the pcall and are skipped).
        for _, member in ipairs({"A", "B", "C", "D", "X", "Y", "Z", "W"}) do
            local ok, v = pcall(function() return value[member] end)
            if ok and v ~= nil then
                local resolved = v
                local ok2, got = pcall(function() return v:get() end)
                if ok2 and got ~= nil then resolved = got end
                parts[#parts + 1] = member .. "=" .. tostr_safe(resolved)
            end
        end
        if #parts > 0 then
            return label .. "{" .. table.concat(parts, ",") .. "}"
        end
        return label .. "=<table>"
    end
    local summary = {}
    for _, member in ipairs({"A", "B", "C", "D", "X", "Y", "Z", "W", "Translation", "Rotation", "Scale3D", "Tier", "Interval", "Type", "ID"}) do
        local ok, v = pcall(function() return value[member] end)
        if ok and v ~= nil then
            local resolved = v
            local ok2, got = pcall(function() return v:get() end)
            if ok2 and got ~= nil then resolved = got end
            -- only recurse into TABLES (bounded, one level); anything else
            -- is a scalar → tostring it (TrivialObjects would self-loop)
            if type(resolved) == "table" then
                summary[#summary + 1] = member .. "=" .. classify_struct(resolved, "")
            else
                summary[#summary + 1] = member .. "=" .. tostr_safe(resolved)
            end
        end
    end
    if #summary > 0 then
        return label .. "{" .. table.concat(summary, ",") .. "}"
    end
    return label .. "=" .. tostr_safe(value)
end

local REFLECTION_PREFIXES = {
    "Class ", "Function ", "DelegateFunction ", "ScriptStruct ", "Enum ",
    "Package ", "Interface ", "Field ", "Property ", "Const ",
}

local function is_reflection(name)
    for _, p in ipairs(REFLECTION_PREFIXES) do
        if name:sub(1, #p) == p then return true end
    end
    return false
end

local scan_errors = {}
local player_locations = {}

local function class_token(name)
    return name:match("^(%S+)") or "?"
end

local function table_concat_kv(t, sep)
    local parts = {}
    if type(t) == "table" then
        for k, v in pairs(t) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
        table.sort(parts)
    end
    return table.concat(parts, sep or " | ")
end

local function scan_one(object, name)
    local token = class_token(name)
    -- v1.8.4: match the CLASS TOKEN exactly (like the control census) —
    -- substring matching caught path noise (the live work instances contain
    -- the manager's name in their path; 127 pseudo-camps were Blueprint/reflection
    -- noise). Live camp instances are "PalBaseCampModel ..."; live work
    -- instances are "PalWorkProgress ..." / "PalWorkProgressMultiType ...".
    if token == "PalBaseCampModel" then
        -- v1.8.3: struct PROPERTY reads return opaque TrivialObject on this
        -- fork (FGuid/FTransform/SignificanceInfo all unresolved). PSO proves
        -- UFUNCTION struct returns DO resolve (velocity.X from GetVelocity),
        -- so use the BlueprintPure accessors: GetTransform() and GetId().
        local id = "?"
        local okid, idv = pcall(function() return object:GetId() end)
        if okid and idv ~= nil then id = classify_struct(idv, "id") end
        local tf = "?"
        local oktf, tfv = pcall(function() return object:GetTransform() end)
        if oktf and tfv ~= nil then tf = classify_struct(tfv, "tf") end
        -- v1.8.6: WorkCollection is an object REF (readable property, unlike
        -- structs) → try its WorkIds (TArray<FGuid>) for the work→camp link.
        local wc = "?"
        local okwc, wcv = pcall(function() return object:GetWorkCollection() end)
        if okwc and wcv ~= nil then
            -- WorkIds is a TArray<FGuid> property; the array pusher builds a
            -- Lua table IF the inner has a registered handler (FGuid may not).
            -- Try property read, then :get() on the array wrapper.
            local wids = nil
            local okwids = pcall(function() wids = wcv["WorkIds"] end)
            if not okwids or wids == nil then
                pcall(function() wids = wcv.WorkIds end)
            end
            if wids ~= nil then
                local resolved = wids
                local ok2, got = pcall(function() return wids:get() end)
                if ok2 and got ~= nil then resolved = got end
                wc = classify_struct(resolved, "wc")
            end
        end
        local entry = "camp#" .. tostring(#camp_models + 1)
        camp_models[#camp_models + 1] = entry
        camp_locations[entry] = tf
        camp_significance[entry] = id .. " wc=" .. wc
    elseif token == "PalWorkProgress" or token == "PalWorkProgressMultiType" then
        -- work→camp: BaseCampIdBelongTo is a struct property (TrivialObject).
        -- Try the BlueprintPure GetId() for the work identity; the camp
        -- association itself stays unresolved on this fork unless GetId()
        -- FGuid members resolve (classify_struct tries A/B/C/D).
        local camp = "?"
        local okc, campv = pcall(function() return object:GetId() end)
        if okc and campv ~= nil then camp = classify_struct(campv, "workid") end
        local loc = "?"
        local locx, locy, locz = nil, nil, nil
        local okm, model = pcall(function() return object["CachedOwnerMapObjectConcreteModel"] end)
        if okm and model ~= nil then
            local oka, actor = pcall(function() return model:GetActor() end)
            if oka and actor ~= nil then
                local okl, pos = pcall(function() return actor:K2_GetActorLocation() end)
                if okl and pos ~= nil then
                    loc = classify_struct(pos, "loc")
                    -- pull X/Y/Z out of the loc string for distance math
                    locx, locy, locz = loc:match("X=(-?%d+%.?%d*),Y=(-?%d+%.?%d*),Z=(-?%d+%.?%d*)")
                    if locx then locx, locy, locz = tonumber(locx), tonumber(locy), tonumber(locz) end
                end
            end
        end
        -- v1.8.10: distance to the first player + significance tier bucket
        -- (tier thresholds from the native BaseCampSignificanceInfoList:
        -- in-base 0.1s / 500m=50000cm 1.5s / 2500m 2.5s / 4500m 5s /
        -- 6500m+ 10s; no player = all far). Units are cm.
        local tier = "far10"
        if locx and #player_locations > 0 then
            local ploc = player_locations[1]
            local px, py = ploc:match("X=(-?%d+%.?%d*),Y=(-?%d+%.?%d*)")
            if px then
                px, py = tonumber(px), tonumber(py)
                local d = math.sqrt((locx - px) ^ 2 + (locy - py) ^ 2)
                if d < 35000 then tier = "inbase01"
                elseif d < 50000 then tier = "t500_15"
                elseif d < 250000 then tier = "t2500_25"
                elseif d < 450000 then tier = "t4500_5"
                end
            end
        end
        work_camps[name] = camp .. " " .. loc .. " tier=" .. tier
        -- v1.8.9: work location via CachedOwnerMapObjectConcreteModel:GetActor()
        -- -> K2_GetActorLocation() (PSO-proven member-read pattern); player
        -- distance then gives the significance tier directly (in-base 0.1s /
        -- 500m 1.5s / 2500m 2.5s / 4500m 5s / 6500m+ 10s).
        -- distance then gives the significance tier directly (in-base 0.1s /
        -- 500m 1.5s / 2500m 2.5s / 4500m 5s / 6500m+ 10s).
    elseif token == "BP_PlayerCharacter_C" or token == "PalPlayerCharacter" then
        local okp, loc = pcall(function() return object:K2_GetActorLocation() end)
        if okp and loc ~= nil then
            player_locations[#player_locations + 1] = classify_struct(loc, "player")
        end
    end
end

local function scan_camps_and_work()
    camp_models = {}
    camp_locations = {}
    work_camps = {}
    camp_significance = {}
    player_locations = {}
    scan_errors = {}
    ForEachUObject(function(object)
        if not is_valid(object) then return end
        local ok, full = pcall(function() return object:GetFullName() end)
        if not ok or not full then return end
        local name = tostring(full)
        local ok2, err = pcall(scan_one, object, name)
        if not ok2 then
            if #scan_errors < 5 then scan_errors[#scan_errors + 1] = tostring(err) end
        end
    end)
end

local function append_line(text) 
    if not LOG_PATH then
        for _, cand in ipairs(LOG_PATH_CANDIDATES) do
            local ok, f = pcall(io.open, cand, "a")
            if ok and f then
                f:close()
                LOG_PATH = cand
                print(TAG .. " log path: " .. cand)
                break
            end
        end
    end
    if not LOG_PATH then
        print(TAG .. " ERROR: no writable log path")
        return false
    end
    local ok, f = pcall(io.open, LOG_PATH, "a")
    if not ok or not f then return false end
    f:write(text .. "\n")
    f:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Feature detection
-- ---------------------------------------------------------------------------
print(TAG .. " features: gamethread_timer=" .. tostring(type(LoopInGameThreadWithDelay) == "function")
    .. " foreach=" .. tostring(type(ForEachUObject) == "function")
    .. " interval_sec=" .. tostring(CFG.interval_sec)
    .. " read_remain=" .. tostring(CFG.read_remain))

-- ---------------------------------------------------------------------------
-- Probe — GAME THREAD ONLY
-- ---------------------------------------------------------------------------
local progress_class = nil
local multi_class = nil
local probe_runs = 0
local sample_count = 0

local function get_progress_class()
    if progress_class then return progress_class end
    local ok, cls = pcall(StaticFindObject, "/Script/Pal.PalWorkProgress")
    if ok and cls then
        progress_class = cls
        print(TAG .. " UPalWorkProgress class resolved")
    else
        print(TAG .. " WARNING: UPalWorkProgress class NOT found (game version changed?)")
    end
    return progress_class
end

local function get_multi_class()
    if multi_class then return multi_class end
    local ok, cls = pcall(StaticFindObject, "/Script/Pal.PalWorkProgressMultiType")
    if ok and cls then
        multi_class = cls
        print(TAG .. " UPalWorkProgressMultiType class resolved")
    end
    return multi_class
end

-- Read a float property defensively (pusher machinery; safe on game thread)
local function read_float(obj, name)
    local ok, val = pcall(function() return tonumber(obj[name]) end)
    if not ok then return nil end
    return val
end

local function census_match(name)
    return name:find("Work", 1, true)
        or name:find("BaseCamp", 1, true)
        or name:find("MonsterAIController", 1, true)
        or name:find("PalAIAction", 1, true)
end

local function probe_tick()
    local class = get_progress_class()
    if not class then
        -- retry next tick; the class may not be loadable until the world exists
        print(TAG .. " class missing; skipping")
        return
    end

    probe_runs = probe_runs + 1
    local now = os.time()
    local rows = {}
    local seen = 0

    -- NAME CENSUS: group every object whose full name mentions Work by class
    -- name. This reveals what the work objects are actually called in THIS
    -- build (the class dumps were 1.0.1-era kit; the live server is
    -- 1.0.2.101103).
    -- Categorize: Class CDO ("Class /Script/..."), Default__ CDO
    -- ("Default__..."), or live instance (anything else). v1.3.1 logs ALL
    -- live instances — the v1.3 run's 3 matches were all Default__ CDOs.
    -- v1.7: per-chunk live bucketing
    local live_by_chunk = {}
    local live_by_chunk_max = 0
    local slots_visited = 0
    local slots_max = 0
    ForEachUObject(function(object, chunk_index, object_index)
        slots_visited = slots_visited + 1
        if object_index and object_index > slots_max then slots_max = object_index end
        if chunk_index and chunk_index > live_by_chunk_max then live_by_chunk_max = chunk_index end
        if not is_valid(object) then return end
        local ok, full = pcall(function() return object:GetFullName() end)
        if not ok or not full then return end
        local name = tostring(full)
        if not name:find("Default__", 1, true) and not is_reflection(name) then
            local ck = tostring(chunk_index or "?")
            live_by_chunk[ck] = (live_by_chunk[ck] or 0) + 1
        end
    end)
    local chunk_lines = {}
    for k, v in pairs(live_by_chunk) do
        chunk_lines[#chunk_lines + 1] = string.format("chunk%s=%d", k, v)
    end
    table.sort(chunk_lines)
    append_line(string.format("%d chunks live=%s max_chunk=%d max_objindex=%d slots_visited=%d",
        now, table.concat(chunk_lines, " "), live_by_chunk_max, slots_max, slots_visited))

    local by_class = {}
    local census_total = 0
    local census_class = 0
    local census_default = 0
    local census_live = 0
    local census_reflection = 0
    local live_samples = {}
    local class_samples = {}
    -- v1.6 control: bucket ALL live objects by class name (first token)
    local all_live = {}
    local all_live_count = 0
    ForEachUObject(function(object)
        if not is_valid(object) then return end
        local ok, full = pcall(function() return object:GetFullName() end)
        if not ok or not full then return end
        local name = tostring(full)
        if census_match(name) then
            census_total = census_total + 1
            if name:sub(1, 6) == "Class " then
                census_class = census_class + 1
                if #class_samples < 5 then class_samples[#class_samples + 1] = name end
            elseif name:find("Default__", 1, true) then
                census_default = census_default + 1
            elseif is_reflection(name) then
                census_reflection = census_reflection + 1
            else
                census_live = census_live + 1
                if #live_samples < 200 then live_samples[#live_samples + 1] = name end
                local cls_name = name:match("^(%S+)") or "?"
                by_class[cls_name] = (by_class[cls_name] or 0) + 1
            end
        end
        -- v1.6 control: every live object, bucketed by class
        if not name:find("Default__", 1, true) and not is_reflection(name) then
            local cls_name = name:match("^(%S+)") or "?"
            all_live[cls_name] = (all_live[cls_name] or 0) + 1
            all_live_count = all_live_count + 1
        end
    end)

    local all_live_lines = {}
    for k, v in pairs(all_live) do
        all_live_lines[#all_live_lines + 1] = string.format("%s=%d", k, v)
    end
    table.sort(all_live_lines)
    -- keep the top 20 by value (sort desc by parsing counts) — simple approach:
    -- log all; the analysis reads the tail anyway
    append_line(string.format("%d control all_live_total=%d by_class=%s",
        now, all_live_count, table.concat(all_live_lines, " ")))

    local census_lines = {}
    for k, v in pairs(by_class) do
        census_lines[#census_lines + 1] = string.format("%s=%d", k, v)
    end
    table.sort(census_lines)
    append_line(string.format("%d census total=%d class=%d default=%d reflection=%d live=%d by_class=%s",
        now, census_total, census_class, census_default, census_reflection, census_live, table.concat(census_lines, " ")))
    for _, s in ipairs(class_samples) do
        append_line("  class: " .. s)
    end
    for _, s in ipairs(live_samples) do
        append_line("  live: " .. s)
    end

    ForEachUObject(function(object)
        if seen >= CFG.max_objects then return end
        if not is_valid(object) then return end
        local ok, is_progress = pcall(function()
            local c = get_multi_class()
            return object:IsA(class) or (c and object:IsA(c)) or false
        end)
        if not ok or not is_progress then return end

        seen = seen + 1
        local tick_since = read_float(object, "ProgressTimeSinceLastTick")
        local rate = read_float(object, "AutoWorkSelfAmountBySec")
        local min_interval = read_float(object, "TickProcessMinInterval")

        local remain = "n/a"
        if CFG.read_remain then
            local okc, rem = pcall(function() return object:GetRemainWorkAmount() end)
            if okc and rem then remain = string.format("%.1f", tonumber(rem) or -1) end
        end

        local addr = "?"
        local okc2, addr_v = pcall(function() return object:GetAddress() end)
        if okc2 and addr_v then addr = string.format("%x", addr_v) end
        local full = "?"
        local okc3, full_v = pcall(function() return object:GetFullName() end)
        if okc3 and full_v then full = tostring(full_v) end

        local row = string.format("%d obj=%-2d addr=%s name=%s tick=%.2f rate=%.3f minint=%.2f remain=%s",
            now, seen, addr, full, tick_since or -1, rate or -1, min_interval or -1, remain)
        rows[#rows + 1] = row
        sample_count = sample_count + 1
    end)

    local summary = string.format("%s probe: %d run(s) samples=%d seen_this_run=%d census_total=%d",
        TAG, probe_runs, sample_count, seen, census_total)
    print(summary)
    append_line(summary)
    for _, row in ipairs(rows) do
        append_line("  " .. row)
    end

    -- v1.8: camp association + tier (one pass, defensive reads)
    local scan_ok = pcall(scan_camps_and_work)
    local camp_line = string.format("%d camps=%d sigs=%s locs=%s",
        now, #camp_models, table_concat_kv(camp_significance, " "), table_concat_kv(camp_locations, " "))
    append_line(camp_line)
    append_line(string.format("%d players=%s", now, table.concat(player_locations, " | ")))
    if #scan_errors > 0 then
        append_line(string.format("%d scan_errors: %s", now, table.concat(scan_errors, " ; ")))
    end
    local work_camp_lines = {}
    for name, camp in pairs(work_camps) do
        work_camp_lines[#work_camp_lines + 1] = name .. "->" .. camp
    end
    table.sort(work_camp_lines)
    append_line(string.format("%d work_camps=%s", now, table.concat(work_camp_lines, " | ")))
end

-- Schedule on the game thread (EngineTick). LoopInGameThreadWithDelay is
-- AUTO-LOOPING on this fork (action.is_looping=true) — it must NOT be
-- re-armed from inside its own callback (that doubles timers exponentially;
-- observed avalanche: 6 runs in 8s at run ~105). A single registration is
-- the whole schedule.
local function schedule()
    if type(LoopInGameThreadWithDelay) ~= "function" then
        print(TAG .. " ERROR: LoopInGameThreadWithDelay unavailable; probe disabled")
        return
    end
    print(TAG .. " scheduling game-thread probe every " .. CFG.interval_sec .. "s (auto-looping, no re-arm)")
    LoopInGameThreadWithDelay(CFG.interval_sec * 1000, probe_tick)
end

-- Defer the first probe ~10s so the world (and work objects) exist; the
-- looping schedule then takes over on its own cadence.
local function start()
    print(TAG .. " started")
    ExecuteInGameThreadWithDelay(10000, probe_tick)
    schedule()
end

start()
