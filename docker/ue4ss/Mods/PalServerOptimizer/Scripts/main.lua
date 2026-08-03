-- PalServerOptimizer fork (v1.2.1) — see fork repo history for changes.
-- v1.2.1: proximity-wake sweep disabled + actor refs reverted to flags —
-- v1.2 crashed the game thread on real drop worlds (stale actor deref in
-- the 250ms sweep after a player picked up a woken drop).
local TAG = "[PalServerOptimizer]"

-- This mod is installed only on the dedicated server.  Keep the gameplay
-- ragdoll flag enabled and disable only skeletal physics on the server.
local TRACE_RAGDOLL_CALLS = false
local MAX_DETAIL_LOGS = 20

-- Palworld already owns Actor/AI/Movement tick budgeting through
-- EPalCharacterImportanceType. This module only adds a conservative mesh tick
-- layer for inactive, non-combat monsters. Gameplay ticks are never disabled.
local OPTIMIZE_DISTANT_MONSTER_MESH_TICK = true
local MONSTER_TICK_CHECK_INTERVAL_MS = 2000
local MONSTER_TICK_BUDGET_PER_PASS = 64
local MONSTER_TICK_HYSTERESIS_PASSES = 2
local MONSTER_MESH_INTERVAL_FAR_IN_SIGHT = 0.0667
local MONSTER_MESH_INTERVAL_MID_OUT_SIGHT = 0.1000
local MONSTER_MESH_INTERVAL_FAR_OUT_SIGHT = 0.2000

-- Never optimize gameplay-critical characters. Classification uses reflected
-- data fields and object names only; native classification UFunctions are not
-- called because they are unsafe during dedicated-server object startup.
local CRITICAL_MONSTER_NAME_MARKERS = {
    "/quest/", "_quest", "quest_",
    "/boss", "boss_", "bossbattle", "towerboss",
    "/raid", "raidboss", "raid_",
    "/arena/", "_arena", "arena_",
    "/dungeon/", "_dungeon", "dungeon_",
    "predatorboss", "worldtree", "unique_npc", "uniquenpc",
}

-- Dropped-item physics is allowed to settle naturally for a short time. Once
-- the authoritative server velocity is low enough, Palworld's own reliable
-- multicast stop path is used to freeze the item at the server transform.
-- Items which are still falling at the timeout are deliberately left alone.
local OPTIMIZE_DROP_ITEM_PHYSICS = true
local DROP_MIN_SETTLE_DELAY_MS = 750
local DROP_CHECK_INTERVAL_MS = 250
local DROP_MAX_TRACK_TIME_MS = 5000
local DROP_SETTLE_SPEED_CM_PER_SEC = 25.0
local DROP_LINEAR_DAMPING = 2.0
local DROP_CHECK_BUDGET_PER_PASS = 64
local DROP_ENABLE_DORMANCY_AFTER_SETTLE = true
local DROP_NEAR_PLAYER_DISTANCE_CM = 3000.0
-- v1.2.1: proximity-wake sweep is DISABLED by default. v1.2 stored live
-- actor refs in dormant_drop_keys and woke them when a player walked near;
-- on a world with real drops this crashed the game thread (SIGSEGV, exit
-- 139) ~20s after a player joined: the sweep wakes a drop → the player
-- picks it up → the actor is destroyed → the next 250ms sweep pass calls
-- K2_GetActorLocation on the freed actor. pcall cannot catch native faults,
-- and the fork's IsValid (object-map backed) cannot close the
-- check-then-use window. Movement-reactivation (the engine's own
-- OnProceedTimerMovementActive hook) still wakes drops when they actually
-- need to move, which covers the real requirement without the stale-ref
-- deref. Set to true only if the sweep is proven safe (e.g. with a
-- re-validated actor lookup each pass).
local DROP_ENABLE_PROXIMITY_WAKE = false
local DROP_NEAR_SETTLE_DELAY_MS = 1500
local DROP_FAR_SETTLE_DELAY_MS = 500
local DROP_SOFT_PHYSICS_POOL_MAX = 128
local PLAYER_LOCATION_REFRESH_MS = 1000
local DORM_AWAKE = 1
local DORM_DORMANT_ALL = 2
local SUMMARY_INTERVAL_MS = 60000
-- v1.2: budgeted proximity-wake sweep for dormant items (checked every
-- drop-queue pass; full rotation completes in N passes, 1s player-location
-- cache freshness bounds staleness).
local DORMANT_WAKE_BUDGET_PER_PASS = 32

-- v1.2: classification memoization TTL. classify_critical_monster() walks the
-- reflection chain (name + StaticCharacterParameterComponent + 8 reads +
-- CharacterParameterComponent + IndividualParameter + 8 reads) on every
-- monster every 2s pass. On the populated world the classification-unready
-- backlog alone was ~11001 re-walks per pass. Cache results per monster
-- address for TTL seconds (captures/base reassignment are re-caught within
-- the TTL window — bounded staleness, massive walk reduction).
local CLASSIFY_CACHE_TTL_SEC = 60
local CLASSIFY_CACHE_MAX_ENTRIES = 4096

-- v1.2: re-assert the dedicated-server physics disable on every mesh-tick
-- pass for non-critical monsters (the flag write at scan time was never
-- re-asserted — anything re-enabling it silently killed the optimization).
local RAGDOLL_REASSERT = true

local monster_class = nil
local detail_log_count = 0
local drop_detail_log_count = 0
local initial_scan_done = false
local classification_cache = {} -- monster address -> {result, expires_at} (v1.2)
local classification_cache_order = {} -- address queue for LRU eviction (v1.2)
local drop_item_class = nil
local tracked_drop_items = {}
local tracked_drop_count = 0
local drop_queue = {}
local drop_queue_head = 1
local drop_queue_tail = 0
local drop_scheduler_started = false
local dormant_drop_keys = {}
local dormant_sweep_cursor = nil -- v1.2 rotation cursor for proximity sweep
local cached_player_locations = {}
local player_location_scheduler_started = false
local tracked_monster_components = {}
local monster_tick_queue = {}
local monster_tick_queue_head = 1
local monster_tick_queue_tail = 0
local monster_tick_scheduler_started = false
local summary_scheduler_started = false

local stats = {
    component_visits = 0,
    optimized = 0,
    already_disabled = 0,
    ignored_non_monster = 0,
    failures = 0,
    ragdoll_calls = 0,
    drop_items_seen = 0,
    drop_items_stopped = 0,
    drop_items_already_stopped = 0,
    drop_items_timed_out = 0,
    drop_item_failures = 0,
    drop_checks = 0,
    drop_dormancy_applied = 0,
    drop_dormancy_woken = 0,
    drop_near_player_checks = 0,
    drop_far_or_over_budget_checks = 0,
    monster_tick_tracked = 0,
    monster_tick_throttled = 0,
    monster_tick_restored = 0,
    monster_tick_skipped_active = 0,
    monster_tick_skipped_battle = 0,
    monster_tick_skipped_critical = 0,
    monster_tick_classification_unready = 0,
    ragdoll_skipped_critical = 0,
    ragdoll_classification_unready = 0,
    monster_tick_failures = 0,
    classify_cache_hits = 0,
    classify_cache_misses = 0,
    classify_cache_evictions = 0,
    ragdoll_reasserts = 0,
    drop_dormancy_proximity_woken = 0,
}

local function log(message)
    print(string.format("%s %s\n", TAG, message))
end

local function is_valid(object)
    return object ~= nil and object:IsValid()
end

local function get_remote_value(value)
    if value == nil then
        return nil
    end
    local ok, resolved = pcall(function() return value:get() end)
    if ok then
        return resolved
    end
    return value
end

local function reflected_bool(value)
    local resolved = get_remote_value(value)
    if resolved == true then
        return true
    elseif resolved == false then
        return false
    end
    local numeric = tonumber(resolved)
    if numeric ~= nil then
        return numeric ~= 0
    end
    return nil
end

local function has_critical_name_marker(object)
    local ok, full_name = pcall(function() return string.lower(object:GetFullName()) end)
    if not ok or full_name == nil then
        return nil
    end
    for _, marker in ipairs(CRITICAL_MONSTER_NAME_MARKERS) do
        if string.find(full_name, marker, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function has_nonzero_guid(guid_value)
    local guid = get_remote_value(guid_value)
    if guid == nil then
        return nil
    end
    local ok, a, b, c, d = pcall(function()
        return tonumber(get_remote_value(guid.A)),
            tonumber(get_remote_value(guid.B)),
            tonumber(get_remote_value(guid.C)),
            tonumber(get_remote_value(guid.D))
    end)
    if not ok or a == nil or b == nil or c == nil or d == nil then
        return nil
    end
    return a ~= 0 or b ~= 0 or c ~= 0 or d ~= 0
end

local classify_critical_monster_impl = nil -- forward decl (v1.2 memoized wrapper calls this)

local function classify_critical_monster(monster)
    -- v1.2 memoization: the reflection walk below is the mod's dominant cost on
    -- a populated world (the unready backlog re-walks every 2s pass). Cache the
    -- verdict per monster address; captures/reassignment are re-caught within
    -- CLASSIFY_CACHE_TTL_SEC. All callers run on the game thread, so the cache
    -- needs no locking.
    local addr = nil
    local ok_addr, addr_v = pcall(function() return monster:GetAddress() end)
    if ok_addr and addr_v then addr = addr_v end
    if addr ~= nil then
        local entry = classification_cache[addr]
        if entry ~= nil then
            if entry.expires_at > os.clock() then
                stats.classify_cache_hits = stats.classify_cache_hits + 1
                return entry.result, entry.reason
            end
            classification_cache[addr] = nil
        end
    end

    local result, reason = classify_critical_monster_impl(monster)
    stats.classify_cache_misses = stats.classify_cache_misses + 1
    if addr ~= nil then
        classification_cache[addr] = { result = result, reason = reason, expires_at = os.clock() + CLASSIFY_CACHE_TTL_SEC }
        table.insert(classification_cache_order, addr)
        if #classification_cache_order > CLASSIFY_CACHE_MAX_ENTRIES then
            local evicted = table.remove(classification_cache_order, 1)
            if evicted ~= nil then
                classification_cache[evicted] = nil
                stats.classify_cache_evictions = stats.classify_cache_evictions + 1
            end
        end
    end
    return result, reason
end

classify_critical_monster_impl = function(monster)
    local name_match = has_critical_name_marker(monster)
    if name_match == nil then
        return nil, "name-unavailable"
    elseif name_match then
        return true, "critical-name"
    end

    local static_parameter = nil
    local ok_static = pcall(function()
        static_parameter = get_remote_value(monster.StaticCharacterParameterComponent)
    end)
    if not ok_static or not is_valid(static_parameter) then
        return nil, "static-parameter-unavailable"
    end

    local static_ok, spawned_type, is_boss, is_tower, is_raid, is_predator,
        is_legend, is_raid_bp, is_uncapturable = pcall(function()
        return tonumber(get_remote_value(static_parameter.SpawnedCharacterType)),
            reflected_bool(static_parameter.IsBoss_Database),
            reflected_bool(static_parameter.IsTowerBoss_Database),
            reflected_bool(static_parameter.IsRaidBoss_Database),
            reflected_bool(static_parameter.IsPredatorBoss_Database),
            reflected_bool(static_parameter.IsLegend_Database),
            reflected_bool(static_parameter.IsRaidBoss_BP),
            reflected_bool(static_parameter.IsUncapturable)
    end)
    if not static_ok or spawned_type == nil or is_boss == nil or is_tower == nil
        or is_raid == nil or is_predator == nil or is_legend == nil
        or is_raid_bp == nil or is_uncapturable == nil then
        return nil, "static-classification-unavailable"
    elseif spawned_type >= 2 or is_boss or is_tower or is_raid or is_predator
        or is_legend or is_raid_bp or is_uncapturable then
        return true, "boss-or-special"
    end

    local parameter_component = nil
    local parameter_ok = pcall(function()
        parameter_component = get_remote_value(monster.CharacterParameterComponent)
    end)
    if not parameter_ok or not is_valid(parameter_component) then
        return nil, "character-parameter-unavailable"
    end

    local individual = nil
    local dynamic_ok, trainer, individual_value = pcall(function()
        return get_remote_value(parameter_component.Trainer),
            get_remote_value(parameter_component.IndividualParameter)
    end)
    if not dynamic_ok then
        return nil, "dynamic-classification-unavailable"
    end
    individual = individual_value
    if is_valid(trainer) then
        return true, "trained-character"
    elseif not is_valid(individual) then
        return nil, "individual-parameter-unavailable"
    end

    local individual_ok, in_raid, world_tree, uncapturable, base_camp, ai_name, action_name = pcall(function()
        return reflected_bool(individual.bIsInRaidArea),
            reflected_bool(individual.bIsWorldTreeAuraPal),
            reflected_bool(individual.bIsUncapturable),
            has_nonzero_guid(individual.BaseCampId),
            string.lower(tostring(get_remote_value(individual.Debug_CurrentAIActionName) or "")),
            string.lower(tostring(get_remote_value(individual.Debug_CurrentActionName) or ""))
    end)
    if not individual_ok or in_raid == nil or world_tree == nil or uncapturable == nil or base_camp == nil then
        return nil, "individual-classification-unavailable"
    end
    if in_raid or world_tree or uncapturable or base_camp then
        return true, "raid-quest-or-base-camp"
    end
    for _, marker in ipairs(CRITICAL_MONSTER_NAME_MARKERS) do
        if string.find(ai_name, marker, 1, true) ~= nil
            or string.find(action_name, marker, 1, true) ~= nil then
            return true, "critical-action"
        end
    end

    return false, "ordinary-wild"
end

local function get_monster_class()
    if is_valid(monster_class) then
        return monster_class
    end

    monster_class = StaticFindObject("/Script/Pal.PalMonsterCharacter")
    return monster_class
end

local function get_drop_item_class()
    if is_valid(drop_item_class) then
        return drop_item_class
    end

    drop_item_class = StaticFindObject("/Script/Pal.PalMapObjectDropItem")
    return drop_item_class
end

local function get_drop_item_key(actor)
    local ok, full_name = pcall(function()
        return actor:GetFullName()
    end)

    if ok then
        return full_name
    end

    return tostring(actor)
end

local function clear_tracked_drop_item(key)
    if tracked_drop_items[key] ~= nil then
        tracked_drop_items[key] = nil
        tracked_drop_count = math.max(0, tracked_drop_count - 1)
    end
end

local function enqueue_drop_item(key)
    drop_queue_tail = drop_queue_tail + 1
    drop_queue[drop_queue_tail] = key
end

local function refresh_player_locations()
    local locations = {}
    local controllers = FindAllOf("PalPlayerController") or {}
    for _, controller in ipairs(controllers) do
        if is_valid(controller) then
            local pawn = nil
            pcall(function() pawn = controller:K2_GetPawn() end)
            if is_valid(pawn) then
                local ok, location = pcall(function() return pawn:K2_GetActorLocation() end)
                if ok and location ~= nil then
                    table.insert(locations, location)
                end
            end
        end
    end
    cached_player_locations = locations
end

local function schedule_player_location_refresh()
    if player_location_scheduler_started then
        return
    end
    player_location_scheduler_started = true

    local function schedule_next()
        ExecuteInGameThreadWithDelay(PLAYER_LOCATION_REFRESH_MS, function()
            local ok, error_message = pcall(refresh_player_locations)
            if not ok then
                log(string.format("player location refresh failed: %s", tostring(error_message)))
            end
            schedule_next()
        end)
    end
    refresh_player_locations()
    schedule_next()
end

local function is_drop_near_player(actor)
    if #cached_player_locations == 0 then
        return false
    end

    local location = actor:K2_GetActorLocation()
    local maximum_distance_squared = DROP_NEAR_PLAYER_DISTANCE_CM * DROP_NEAR_PLAYER_DISTANCE_CM
    for _, player_location in ipairs(cached_player_locations) do
        local dx = (tonumber(get_remote_value(location.X)) or 0.0)
            - (tonumber(get_remote_value(player_location.X)) or 0.0)
        local dy = (tonumber(get_remote_value(location.Y)) or 0.0)
            - (tonumber(get_remote_value(player_location.Y)) or 0.0)
        local dz = (tonumber(get_remote_value(location.Z)) or 0.0)
            - (tonumber(get_remote_value(player_location.Z)) or 0.0)
        if ((dx * dx) + (dy * dy) + (dz * dz)) <= maximum_distance_squared then
            return true
        end
    end
    return false
end

local function wake_drop_item_dormancy(actor, key, reason)
    if not dormant_drop_keys[key] or not is_valid(actor) then
        return false
    end

    actor:FlushNetDormancy()
    actor:SetNetDormancy(DORM_AWAKE)
    actor:ForceNetUpdate()
    dormant_drop_keys[key] = nil
    stats.drop_dormancy_woken = stats.drop_dormancy_woken + 1
    if drop_detail_log_count < MAX_DETAIL_LOGS then
        drop_detail_log_count = drop_detail_log_count + 1
        log(string.format("woke dropped-item dormancy (%s): %s", reason, actor:GetFullName()))
    end
    return true
end

local function get_drop_speed(actor)
    local velocity = actor:GetVelocity()
    local x = tonumber(get_remote_value(velocity.X)) or 0.0
    local y = tonumber(get_remote_value(velocity.Y)) or 0.0
    local z = tonumber(get_remote_value(velocity.Z)) or 0.0
    return math.sqrt((x * x) + (y * y) + (z * z))
end

local function stop_drop_item_at_server_transform(actor, key, source)
    local ok, error_message = pcall(function()
        if not is_valid(actor) then
            clear_tracked_drop_item(key)
            return
        end

        if not actor:HasAuthority() then
            clear_tracked_drop_item(key)
            return
        end

        if actor.bMovementActive == false then
            stats.drop_items_already_stopped = stats.drop_items_already_stopped + 1
            clear_tracked_drop_item(key)
            return
        end

        local location = actor:K2_GetActorLocation()
        local rotation = actor:K2_GetActorRotation()

        -- Preserve Palworld's replicated state and reliable final-transform RPC
        -- instead of disabling replication or running client-authoritative motion.
        if DROP_ENABLE_DORMANCY_AFTER_SETTLE then
            pcall(function() actor:FlushNetDormancy() end)
        end

        actor.bMovementActive = false
        actor:StopMovement_Multicast(location, rotation)
        pcall(function() actor:ForceNetUpdate() end)

        if DROP_ENABLE_DORMANCY_AFTER_SETTLE then
            local dormancy_ok = pcall(function() actor:SetNetDormancy(DORM_DORMANT_ALL) end)
            if dormancy_ok then
                -- v1.2 stored the ACTOR here so the proximity sweep could wake
                -- it — that caused a UAF crash (see DROP_ENABLE_PROXIMITY_WAKE).
                -- v1.2.1: store a flag only; the engine's movement-reactivation
                -- hook is the only waker, and it resolves the actor fresh from
                -- the hook payload each time.
                dormant_drop_keys[key] = true
                stats.drop_dormancy_applied = stats.drop_dormancy_applied + 1
            end
        end

        stats.drop_items_stopped = stats.drop_items_stopped + 1
        clear_tracked_drop_item(key)

        if drop_detail_log_count < MAX_DETAIL_LOGS then
            drop_detail_log_count = drop_detail_log_count + 1
            log(string.format(
                "stopped settled drop physics (%s): %s",
                source,
                actor:GetFullName()
            ))
        end
    end)

    if not ok then
        stats.drop_item_failures = stats.drop_item_failures + 1
        clear_tracked_drop_item(key)
        log(string.format("drop-item stop failed (%s): %s", source, tostring(error_message)))
    end
end

local function process_drop_item(key)
    local state = tracked_drop_items[key]
    if state == nil then
        return
    end

    local actor = state.actor
    local continue_tracking = false
    local ok, error_message = pcall(function()
        if not is_valid(actor) or not actor:HasAuthority() then
            clear_tracked_drop_item(key)
            return
        end

        stats.drop_checks = stats.drop_checks + 1
        -- v1.2: real-clock delta. The previous code assumed perfect
        -- DROP_CHECK_INTERVAL_MS scheduling; autosave hitches made elapsed
        -- undercount, so items were tracked past their settle time.
        local now_clock = os.clock()
        local since_last = now_clock - (state.last_clock or now_clock)
        state.last_clock = now_clock
        state.elapsed_ms = state.elapsed_ms + (since_last * 1000)

        local near_player = is_drop_near_player(actor)
        local settle_delay_ms = DROP_MIN_SETTLE_DELAY_MS
        if near_player and tracked_drop_count <= DROP_SOFT_PHYSICS_POOL_MAX then
            settle_delay_ms = DROP_NEAR_SETTLE_DELAY_MS
            stats.drop_near_player_checks = stats.drop_near_player_checks + 1
        else
            settle_delay_ms = DROP_FAR_SETTLE_DELAY_MS
            stats.drop_far_or_over_budget_checks = stats.drop_far_or_over_budget_checks + 1
        end

        if actor.bMovementActive == false then
            -- NotifyOnNewObject can run before Palworld activates movement.
            if state.elapsed_ms < settle_delay_ms then
                continue_tracking = true
                return
            end

            stats.drop_items_already_stopped = stats.drop_items_already_stopped + 1
            clear_tracked_drop_item(key)
            return
        end

        local speed = get_drop_speed(actor)
        if state.elapsed_ms >= settle_delay_ms
            and speed <= DROP_SETTLE_SPEED_CM_PER_SEC then
            stop_drop_item_at_server_transform(actor, key, state.source)
            return
        end

        if state.elapsed_ms >= DROP_MAX_TRACK_TIME_MS then
            -- Moving/falling items stay on Palworld's original physics path.
            stats.drop_items_timed_out = stats.drop_items_timed_out + 1
            clear_tracked_drop_item(key)
            return
        end

        continue_tracking = true
    end)

    if not ok then
        stats.drop_item_failures = stats.drop_item_failures + 1
        clear_tracked_drop_item(key)
        log(string.format("drop-item check failed (%s): %s", state.source, tostring(error_message)))
        return
    end

    if continue_tracking and tracked_drop_items[key] ~= nil then
        enqueue_drop_item(key)
    end
end

local function sweep_dormant_proximity()
    -- v1.2.1: DISABLED by default — see DROP_ENABLE_PROXIMITY_WAKE. The sweep
    -- stored live actor refs and deref'd them every pass; on a world with
    -- real drops this crashed the game thread after a player picked up a
    -- woken drop (stale ref → K2_GetActorLocation on freed actor → SIGSEGV).
    -- The engine's movement-reactivation hook covers drop waking safely.
    if not DROP_ENABLE_PROXIMITY_WAKE then return end
    if not DROP_ENABLE_DORMANCY_AFTER_SETTLE or #cached_player_locations == 0 then
        return
    end

    local checked = 0
    local cursor = dormant_sweep_cursor
    local key = next(dormant_drop_keys, cursor)
    while key ~= nil and checked < DORMANT_WAKE_BUDGET_PER_PASS do
        local actor = dormant_drop_keys[key]
        if not is_valid(actor) then
            dormant_drop_keys[key] = nil
        else
            local ok_near, near = pcall(function() return is_drop_near_player(actor) end)
            if ok_near and near then
                wake_drop_item_dormancy(actor, key, "player proximity")
                stats.drop_dormancy_proximity_woken = stats.drop_dormancy_proximity_woken + 1
            end
        end
        checked = checked + 1
        cursor = key
        key = next(dormant_drop_keys, cursor)
    end
    dormant_sweep_cursor = cursor
end

local function process_drop_queue()
    local processed = 0
    local pass_tail = drop_queue_tail
    while processed < DROP_CHECK_BUDGET_PER_PASS and drop_queue_head <= pass_tail do
        local key = drop_queue[drop_queue_head]
        drop_queue[drop_queue_head] = nil
        drop_queue_head = drop_queue_head + 1
        processed = processed + 1
        if key ~= nil then
            process_drop_item(key)
        end
    end

    if drop_queue_head > drop_queue_tail then
        drop_queue = {}
        drop_queue_head = 1
        drop_queue_tail = 0
    elseif drop_queue_head > 4096 then
        local compacted = {}
        local compacted_tail = 0
        for index = drop_queue_head, drop_queue_tail do
            if drop_queue[index] ~= nil then
                compacted_tail = compacted_tail + 1
                compacted[compacted_tail] = drop_queue[index]
            end
        end
        drop_queue = compacted
        drop_queue_head = 1
        drop_queue_tail = compacted_tail
    end
end

local function schedule_drop_queue()
    if drop_scheduler_started or not OPTIMIZE_DROP_ITEM_PHYSICS then
        return
    end
    drop_scheduler_started = true

    local function schedule_next()
        ExecuteInGameThreadWithDelay(DROP_CHECK_INTERVAL_MS, function()
            process_drop_queue()
            sweep_dormant_proximity()
            schedule_next()
        end)
    end
    schedule_next()
end

local function track_drop_item(actor, source)
    if not OPTIMIZE_DROP_ITEM_PHYSICS or not is_valid(actor) then
        return
    end

    local key = get_drop_item_key(actor)
    if tracked_drop_items[key] then
        return
    end

    tracked_drop_items[key] = {
        actor = actor,
        elapsed_ms = 0,
        last_clock = os.clock(),
        source = source,
    }
    tracked_drop_count = tracked_drop_count + 1
    stats.drop_items_seen = stats.drop_items_seen + 1

    local ok, error_message = pcall(function()
        local current_damping = tonumber(get_remote_value(actor.CurrentLinearDamping))
        if current_damping ~= nil and current_damping < DROP_LINEAR_DAMPING then
            actor.CurrentLinearDamping = DROP_LINEAR_DAMPING
        end
    end)

    if not ok then
        -- Damping is an optional optimization. Failure must not prevent the
        -- authoritative settle check from running.
        log(string.format("drop-item damping update skipped (%s): %s", source, tostring(error_message)))
    end

    enqueue_drop_item(key)
end

local function scan_existing_drop_items()
    if not OPTIMIZE_DROP_ITEM_PHYSICS then
        return
    end

    local class = get_drop_item_class()
    if not is_valid(class) then
        stats.drop_item_failures = stats.drop_item_failures + 1
        log("drop-item scan aborted: PalMapObjectDropItem class was not found")
        return
    end

    ForEachUObject(function(object)
        if is_valid(object) and object:IsA(class) then
            track_drop_item(object, "initial scan")
        end
    end)
end

local function find_monster_outer(component)
    local class = get_monster_class()
    if not is_valid(class) then
        return nil
    end

    local outer = component:GetOuter()
    for _ = 1, 8 do
        if not is_valid(outer) then
            break
        end

        if outer:IsA(class) then
            return outer
        end

        outer = outer:GetOuter()
    end

    return nil
end

local function same_uobject(left, right)
    if not is_valid(left) or not is_valid(right) then
        return false
    end
    local ok, same = pcall(function()
        return left:GetAddress() == right:GetAddress()
    end)
    return ok and same
end

local function get_monster_importance(monster)
    local importance = 0
    pcall(function() importance = tonumber(get_remote_value(monster.ImportanceType)) or 0 end)
    return importance
end

local function enqueue_monster_tick(key)
    monster_tick_queue_tail = monster_tick_queue_tail + 1
    monster_tick_queue[monster_tick_queue_tail] = key
end

local function track_monster_mesh_tick(component, monster)
    if not OPTIMIZE_DISTANT_MONSTER_MESH_TICK then
        return
    end

    local key = get_drop_item_key(component)
    if tracked_monster_components[key] ~= nil then
        return
    end

    tracked_monster_components[key] = {
        component = component,
        monster = monster,
        confirmed_main_mesh = false,
        applied_interval = nil,
        pending_interval = nil,
        pending_passes = 0,
    }
    enqueue_monster_tick(key)
end

local function restore_monster_native_tick(state)
    state.pending_interval = nil
    state.pending_passes = 0
    if state.applied_interval == nil then
        return
    end
    state.monster:ResetTickInterval()
    state.applied_interval = nil
    stats.monster_tick_restored = stats.monster_tick_restored + 1
end


local function process_monster_tick(key)
    local state = tracked_monster_components[key]
    if state == nil then
        return
    end

    local component = state.component
    local monster = state.monster
    local keep_tracking = false
    local ok, error_message = pcall(function()
        if not is_valid(component) or not is_valid(monster) then
            tracked_monster_components[key] = nil
            return
        end
        keep_tracking = true

        if not state.confirmed_main_mesh then
            local main_mesh = monster:GetMainMesh()
            if not same_uobject(component, main_mesh) then
                tracked_monster_components[key] = nil
                keep_tracking = false
                return
            end
            state.confirmed_main_mesh = true
            stats.monster_tick_tracked = stats.monster_tick_tracked + 1
        end

        local is_critical = classify_critical_monster(monster)
        if is_critical == nil then
            stats.monster_tick_classification_unready = stats.monster_tick_classification_unready + 1
            restore_monster_native_tick(state)
            return
        elseif is_critical then
            stats.monster_tick_skipped_critical = stats.monster_tick_skipped_critical + 1
            restore_monster_native_tick(state)
            tracked_monster_components[key] = nil
            keep_tracking = false
            return
        end

        -- v1.2: re-assert the dedicated-server physics disable on every pass.
        -- The scan-time flag write was never re-asserted; if anything re-enables
        -- it (spawn resets, game logic), the optimization silently dies.
        if RAGDOLL_REASSERT then
            local ok_re, err_re = pcall(function()
                if component.bEnablePhysicsOnDedicatedServer ~= false then
                    component.bEnablePhysicsOnDedicatedServer = false
                    stats.ragdoll_reasserts = stats.ragdoll_reasserts + 1
                end
            end)
            if not ok_re then
                stats.failures = stats.failures + 1
            end
        end

        local is_battle = monster:GetBattleMode()
        if is_battle then
            stats.monster_tick_skipped_battle = stats.monster_tick_skipped_battle + 1
            restore_monster_native_tick(state)
            return
        end

        local is_lifted = false
        pcall(function() is_lifted = monster:IsLiftupObject() end)
        if is_lifted then
            restore_monster_native_tick(state)
            return
        end

        local importance = get_monster_importance(monster)
        local target_interval = nil
        if importance == 5 then
            target_interval = MONSTER_MESH_INTERVAL_FAR_IN_SIGHT
        elseif importance == 6 then
            target_interval = MONSTER_MESH_INTERVAL_MID_OUT_SIGHT
        elseif importance >= 7 then
            target_interval = MONSTER_MESH_INTERVAL_FAR_OUT_SIGHT
        end

        if target_interval == nil then
            stats.monster_tick_skipped_active = stats.monster_tick_skipped_active + 1
            restore_monster_native_tick(state)
            return
        end

        if state.applied_interval == target_interval then
            state.pending_interval = nil
            state.pending_passes = 0
            return
        end

        if state.pending_interval == target_interval then
            state.pending_passes = state.pending_passes + 1
        else
            state.pending_interval = target_interval
            state.pending_passes = 1
        end

        if state.pending_passes >= MONSTER_TICK_HYSTERESIS_PASSES then
            component:SetComponentTickIntervalAndCooldown(target_interval)
            state.applied_interval = target_interval
            state.pending_interval = nil
            state.pending_passes = 0
            stats.monster_tick_throttled = stats.monster_tick_throttled + 1
        end
    end)

    if not ok then
        stats.monster_tick_failures = stats.monster_tick_failures + 1
        tracked_monster_components[key] = nil
        log(string.format("monster mesh tick optimization failed: %s", tostring(error_message)))
        return
    end

    if keep_tracking and tracked_monster_components[key] ~= nil then
        enqueue_monster_tick(key)
    end
end

local function process_monster_tick_queue()
    local processed = 0
    local pass_tail = monster_tick_queue_tail
    while processed < MONSTER_TICK_BUDGET_PER_PASS and monster_tick_queue_head <= pass_tail do
        local key = monster_tick_queue[monster_tick_queue_head]
        monster_tick_queue[monster_tick_queue_head] = nil
        monster_tick_queue_head = monster_tick_queue_head + 1
        processed = processed + 1
        if key ~= nil then
            process_monster_tick(key)
        end
    end

    if monster_tick_queue_head > monster_tick_queue_tail then
        monster_tick_queue = {}
        monster_tick_queue_head = 1
        monster_tick_queue_tail = 0
    elseif monster_tick_queue_head > 4096 then
        local compacted = {}
        local compacted_tail = 0
        for index = monster_tick_queue_head, monster_tick_queue_tail do
            if monster_tick_queue[index] ~= nil then
                compacted_tail = compacted_tail + 1
                compacted[compacted_tail] = monster_tick_queue[index]
            end
        end
        monster_tick_queue = compacted
        monster_tick_queue_head = 1
        monster_tick_queue_tail = compacted_tail
    end
end

local function schedule_monster_tick_queue()
    if monster_tick_scheduler_started or not OPTIMIZE_DISTANT_MONSTER_MESH_TICK then
        return
    end
    monster_tick_scheduler_started = true

    local function schedule_next()
        ExecuteInGameThreadWithDelay(MONSTER_TICK_CHECK_INTERVAL_MS, function()
            process_monster_tick_queue()
            schedule_next()
        end)
    end
    schedule_next()
end

local function optimize_component(component, source)
    stats.component_visits = stats.component_visits + 1

    local ok, error_message = pcall(function()
        if not is_valid(component) then
            error("invalid skeletal mesh component")
        end

        local monster = find_monster_outer(component)
        if not is_valid(monster) then
            stats.ignored_non_monster = stats.ignored_non_monster + 1
            return
        end

        track_monster_mesh_tick(component, monster)

        local is_critical = classify_critical_monster(monster)
        if is_critical == nil then
            stats.ragdoll_classification_unready = stats.ragdoll_classification_unready + 1
            return
        elseif is_critical then
            stats.ragdoll_skipped_critical = stats.ragdoll_skipped_critical + 1
            return
        end

        local was_enabled = component.bEnablePhysicsOnDedicatedServer
        component.bEnablePhysicsOnDedicatedServer = false
        local is_enabled = component.bEnablePhysicsOnDedicatedServer

        if is_enabled ~= false then
            error("bEnablePhysicsOnDedicatedServer remained enabled")
        end

        if was_enabled == false then
            stats.already_disabled = stats.already_disabled + 1
            return
        end

        stats.optimized = stats.optimized + 1
        if detail_log_count < MAX_DETAIL_LOGS then
            detail_log_count = detail_log_count + 1
            log(string.format(
                "disabled dedicated-server skeletal physics (%s): %s | owner=%s",
                source,
                component:GetFullName(),
                monster:GetFullName()
            ))
        end
    end)

    if not ok then
        stats.failures = stats.failures + 1
        log(string.format("component optimization failed (%s): %s", source, tostring(error_message)))
    end
end

local function scan_existing_components()
    if initial_scan_done then
        return
    end

    initial_scan_done = true
    local component_class = StaticFindObject("/Script/Pal.PalSkeletalMeshComponent")
    if not is_valid(component_class) then
        stats.failures = stats.failures + 1
        log("initial scan aborted: PalSkeletalMeshComponent class was not found")
        return
    end

    ForEachUObject(function(object)
        if is_valid(object) and object:IsA(component_class) then
            optimize_component(object, "initial scan")
        end
    end)

    log(string.format(
        "initial scan complete: visits=%d, changed=%d, already_disabled=%d, ignored=%d, failures=%d",
        stats.component_visits,
        stats.optimized,
        stats.already_disabled,
        stats.ignored_non_monster,
        stats.failures
    ))

    scan_existing_drop_items()
    log(string.format(
        "drop-item scan complete: seen=%d, stopped=%d, already_stopped=%d, timed_out=%d, failures=%d",
        stats.drop_items_seen,
        stats.drop_items_stopped,
        stats.drop_items_already_stopped,
        stats.drop_items_timed_out,
        stats.drop_item_failures
    ))
end

local function table_entry_count(values)
    local count = 0
    for _ in pairs(values) do
        count = count + 1
    end
    return count
end

local function schedule_summary_log()
    if summary_scheduler_started then
        return
    end
    summary_scheduler_started = true

    local function schedule_next()
        ExecuteInGameThreadWithDelay(SUMMARY_INTERVAL_MS, function()
            log(string.format(
                "summary: ragdoll_components=%d ragdoll_changed=%d ragdoll_calls=%d " ..
                "ragdoll_critical_skips=%d ragdoll_classify_unready=%d ragdoll_reasserts=%d " ..
                "mesh_tracked=%d mesh_active=%d mesh_changes=%d mesh_restores=%d " ..
                "mesh_critical_skips=%d mesh_classify_unready=%d mesh_failures=%d " ..
                "drops_tracked=%d drops_seen=%d drops_stopped=%d drops_timeout=%d drop_checks=%d " ..
                "drop_near_checks=%d drop_far_checks=%d dormancy=%d dormancy_woken=%d dormancy_prox=%d drop_failures=%d " ..
                "classify_cache_hits=%d classify_cache_misses=%d classify_evict=%d",
                stats.component_visits,
                stats.optimized,
                stats.ragdoll_calls,
                stats.ragdoll_skipped_critical,
                stats.ragdoll_classification_unready,
                stats.ragdoll_reasserts,
                stats.monster_tick_tracked,
                table_entry_count(tracked_monster_components),
                stats.monster_tick_throttled,
                stats.monster_tick_restored,
                stats.monster_tick_skipped_critical,
                stats.monster_tick_classification_unready,
                stats.monster_tick_failures,
                tracked_drop_count,
                stats.drop_items_seen,
                stats.drop_items_stopped,
                stats.drop_items_timed_out,
                stats.drop_checks,
                stats.drop_near_player_checks,
                stats.drop_far_or_over_budget_checks,
                stats.drop_dormancy_applied,
                stats.drop_dormancy_woken,
                stats.drop_dormancy_proximity_woken,
                stats.drop_item_failures,
                stats.classify_cache_hits,
                stats.classify_cache_misses,
                stats.classify_cache_evictions
            ))
            schedule_next()
        end)
    end
    schedule_next()
end

NotifyOnNewObject("/Script/Pal.PalSkeletalMeshComponent", function(component)
    optimize_component(component, "new object")
end)

if OPTIMIZE_DROP_ITEM_PHYSICS then
    NotifyOnNewObject("/Script/Pal.PalMapObjectDropItem", function(actor)
        track_drop_item(actor, "new object")
    end)

    RegisterHook("/Script/Pal.PalMapObjectDropItem:OnProceedTimerMovementActive", function() end, function(actor_param)
        local actor = get_remote_value(actor_param)
        ExecuteInGameThreadWithDelay(1, function()
            local ok, error_message = pcall(function()
                if not is_valid(actor) or not actor:HasAuthority() then
                    return
                end
                if actor.bMovementActive == false then
                    return
                end

                local key = get_drop_item_key(actor)
                wake_drop_item_dormancy(actor, key, "movement reactivated")
                track_drop_item(actor, "movement reactivated")
            end)
            if not ok then
                stats.drop_item_failures = stats.drop_item_failures + 1
                log(string.format("drop-item reactivation failed: %s", tostring(error_message)))
            end
        end)
    end)
end

RegisterInitGameStatePostHook(function(_context)
    -- NOTE: this hook NEVER fires on this image — the world (and
    -- InitGameState) loads during boot, BEFORE UE4SS mods load (30s init
    -- sleep), so the hook arms too late and misses it. All schedulers are
    -- therefore armed from mod load instead (self-arm via the game-thread
    -- timer, which works on the fixed EngineTick build). This block is kept
    -- as a belt-and-braces re-arm in case a world reload ever fires it.
    scan_existing_components()
    schedule_player_location_refresh()
    schedule_drop_queue()
    schedule_monster_tick_queue()
    schedule_summary_log()
end)

-- SELF-ARM (critical fix, v1.1): InitGameStatePostHook never fires on this
-- image (world loads before mods), so PSO's loops never started. Arm from mod
-- load via the game-thread timer — EngineTick dispatch works on the fork fix
-- b23ad7c (UEngine::Tick slot 0x308). The initial scan is deferred ~2s so the
-- world and classes are definitely loaded.
ExecuteInGameThreadWithDelay(2000, function()
    local ok, err = pcall(function()
        scan_existing_components()
        schedule_player_location_refresh()
        schedule_drop_queue()
        schedule_monster_tick_queue()
        schedule_summary_log()
    end)
    if not ok then
        log("self-arm failed: " .. tostring(err))
    end
end)

if TRACE_RAGDOLL_CALLS then
    local ragdoll_functions = {
        "/Script/Pal.PalUtility:SetCharacterRagdoll",
        "/Script/Pal.PalUtility:SetCharacterRagdollForLiftup",
        "/Script/Pal.PalUtility:SetCharacterRagdollForNooseTrap",
        "/Script/Pal.PalUtility:SetCharacterRagdollForRevive",
    }

    for _, function_name in ipairs(ragdoll_functions) do
        local hook_name = function_name
        RegisterHook(hook_name, function(_self, character_param)
            local ok, character = pcall(function()
                return character_param:get()
            end)

            if ok and is_valid(character) then
                local class = get_monster_class()
                if is_valid(class) and character:IsA(class) then
                    stats.ragdoll_calls = stats.ragdoll_calls + 1
                    if stats.ragdoll_calls <= MAX_DETAIL_LOGS then
                        log(string.format(
                            "ragdoll call #%d: %s | target=%s",
                            stats.ragdoll_calls,
                            hook_name,
                            character:GetFullName()
                        ))
                    end
                end
            end
        end)
    end
end

log("loaded; ragdoll, importance-aware mesh tick, and budgeted dropped-item optimization are active")
