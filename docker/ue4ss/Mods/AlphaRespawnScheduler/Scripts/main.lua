-- Alpha Respawn Scheduler 1.0.0-beta.1
-- Original server-authoritative UE4SS Lua implementation for Palworld 1.0.

local Config = require("config")

local MOD_NAME = "AlphaRespawnScheduler"
local MOD_VERSION = "1.0.0-beta.1"
local RUNTIME_KEY = "__AlphaRespawnSchedulerRuntime"
local TEST_MODE = rawget(_G, "__PALMODS_TEST") == true

local PROCESS_BOSS_DEFEAT =
    "/Script/Pal.PalNPCSpawnerBase:ProcessBossDefeatInfo_ServerInternal"
local MONO_SPAWNER_CLASS =
    "/Game/Pal/Blueprint/Spawner/BP_MonoNPCSpawner.BP_MonoNPCSpawner_C"
local STANDARD_SPAWNER_CLASS =
    "/Game/Pal/Blueprint/Spawner/BP_PalSpawner_Standard.BP_PalSpawner_Standard_C"
local MONO_ON_DEAD = MONO_SPAWNER_CLASS .. ":On Dead"
local MONO_ON_CAPTURE = MONO_SPAWNER_CLASS .. ":On Capture"
local MOD_DISABLE_FLAG_NAME = "AlphaRespawnScheduler_Cooldown"
local MOD_DISABLE_FLAG = type(FName) == "function"
    and FName(MOD_DISABLE_FLAG_NAME) or MOD_DISABLE_FLAG_NAME

local MAX_COOLDOWN_SECONDS = 2592000 -- 30 days
local MAX_PENDING_PER_TICK = 25

local function log(message, verbose_only)
    if verbose_only and not Config.verbose_logging then return end
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function finite_number(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

local function rounded(value)
    return math.floor(value + 0.5)
end

local function clamped_integer(value, minimum, maximum, fallback)
    local number = finite_number(value, fallback)
    number = math.max(minimum, math.min(maximum, number))
    return rounded(number)
end

local function build_settings(source)
    source = type(source) == "table" and source or {}
    local mode = string.lower(tostring(source.clock_mode or "active"))
    if mode ~= "active" and mode ~= "wall" then mode = "active" end

    local overrides = {}
    if type(source.boss_overrides) == "table" then
        for raw_key, raw_value in pairs(source.boss_overrides) do
            local key = type(raw_key) == "string" and raw_key or nil
            if key and key ~= "" and not key:find("[\r\n\t]") then
                overrides[key] = clamped_integer(
                    raw_value, 1, MAX_COOLDOWN_SECONDS, 1800)
            end
        end
    end

    return {
        default_cooldown_seconds = clamped_integer(
            source.default_cooldown_seconds, 1, MAX_COOLDOWN_SECONDS, 1800),
        clock_mode = mode,
        checkpoint_seconds = clamped_integer(
            source.checkpoint_seconds, 5, 300, 15),
        expired_scan_seconds = clamped_integer(
            source.expired_scan_seconds, 1, 60, 5),
        boss_overrides = overrides,
        verbose_logging = source.verbose_logging == true,
    }
end

local Settings = build_settings(Config)
Config.verbose_logging = Settings.verbose_logging

local previous = rawget(_G, RUNTIME_KEY)
if type(previous) == "table" and type(previous.Cleanup) == "function" then
    pcall(previous.Cleanup, "hot reload")
end

local Runtime = {
    enabled = true,
    authority_active = false,
    authority_context = nil,
    state_loaded = false,
    state_dirty = false,
    state_path = nil,
    world_key = nil,
    world_key_attempts = 0,
    entries = {},
    tracked_spawners = setmetatable({}, { __mode = "k" }),
    mod_disable_states = setmetatable({}, { __mode = "k" }),
    pending_spawners = {},
    pending_set = setmetatable({}, { __mode = "k" }),
    hooks = {},
    last_tick = nil,
    last_checkpoint = nil,
    last_expired_scan = 0,
    last_hook_retry = 0,
}
rawset(_G, RUNTIME_KEY, Runtime)

local function is_current()
    return Runtime.enabled and rawget(_G, RUNTIME_KEY) == Runtime
end

local function unwrap(value)
    if value == nil then return nil end
    local value_type = type(value)
    if value_type ~= "table" and value_type ~= "userdata" then return value end
    local ok, result = pcall(function()
        if value.get then return value:get() end
        return value
    end)
    return ok and result or nil
end

local function is_valid(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function unreal_string(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok, result = pcall(function() return value:ToString() end)
    if ok and type(result) == "string" then return result end
    local fallback = tostring(value)
    if fallback:match("^%a+:%s*%x+$") then return nil end
    return fallback
end

local function context_has_authority(context)
    -- ponytail: dedicated servers are always authoritative; the native
    -- HasAuthority() probe aborts (SIGABRT) on the Linux UE4SS port.
    return true
end

local function cooldown_for_key(settings, key)
    return settings.boss_overrides[key]
        or settings.default_cooldown_seconds
end

local function count_entries(entries)
    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    return count
end

local function advance_entries(entries, elapsed)
    elapsed = math.max(0, rounded(finite_number(elapsed, 0)))
    if elapsed == 0 then return false, 0 end

    local changed = false
    local due = 0
    for _, entry in pairs(entries) do
        local previous_remaining = math.max(0, tonumber(entry.remaining) or 0)
        if previous_remaining > 0 then
            entry.remaining = math.max(0, previous_remaining - elapsed)
            changed = true
        end
        if entry.remaining <= 0 then due = due + 1 end
    end
    return changed, due
end

local function serialize_state(entries, saved_at, mode)
    local keys = {}
    for key in pairs(entries) do keys[#keys + 1] = key end
    table.sort(keys)

    local lines = {
        "# alpha-respawn-scheduler-v1",
        "saved_at=" .. tostring(math.max(0, rounded(saved_at or os.time()))),
        "clock_mode=" .. tostring(mode or "active"),
    }
    for _, key in ipairs(keys) do
        local safe_key = tostring(key):gsub("[\r\n\t]", "_")
        local remaining = math.max(0, rounded(entries[key].remaining or 0))
        lines[#lines + 1] = string.format("%d\t%s", remaining, safe_key)
    end
    return table.concat(lines, "\n") .. "\n"
end

local function parse_state(text, settings, now)
    local entries = {}
    local saved_at = nil
    local file_mode = "active"
    if type(text) ~= "string" then return entries, saved_at, file_mode end

    for line in text:gmatch("[^\r\n]+") do
        local timestamp = line:match("^saved_at=(%d+)$")
        local mode = line:match("^clock_mode=(%a+)$")
        local remaining_text, key = line:match("^(%d+)\t(.+)$")
        if timestamp then
            saved_at = tonumber(timestamp)
        elseif mode == "active" or mode == "wall" then
            file_mode = mode
        elseif remaining_text and key and key ~= "" then
            entries[key] = {
                remaining = math.max(0, math.min(
                    MAX_COOLDOWN_SECONDS, tonumber(remaining_text) or 0)),
            }
        end
    end

    if settings.clock_mode == "wall" and saved_at then
        advance_entries(entries, math.max(0, (now or os.time()) - saved_at))
    end
    return entries, saved_at, file_mode
end

local function script_directory()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or nil
    if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return "." end
    return source:sub(2):match("^(.*)[/\\]") or "."
end

local STATE_DIRECTORY = script_directory()

local function safe_world_key(value)
    value = tostring(value or ""):gsub('[<>:"/\\|?*%c]', "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return "ActiveWorld" end
    return value
end

local function state_path_for_world(world_key)
    return STATE_DIRECTORY .. "/alpha_respawn_" .. safe_world_key(world_key) .. ".state"
end

local function read_all(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function write_atomic(path, content)
    local temporary = path .. ".tmp"
    local backup = path .. ".bak"
    local file, open_error = io.open(temporary, "w")
    if not file then return false, open_error end
    local write_ok, write_error = file:write(content)
    file:close()
    if not write_ok then
        os.remove(temporary)
        return false, write_error
    end

    os.remove(backup)
    local existing = io.open(path, "r")
    local had_existing = existing ~= nil
    if existing then existing:close() end
    if had_existing then
        local backup_ok, backup_error = os.rename(path, backup)
        if not backup_ok then
            os.remove(temporary)
            return false, backup_error
        end
    end

    local promote_ok, promote_error = os.rename(temporary, path)
    if not promote_ok then
        if had_existing then os.rename(backup, path) end
        os.remove(temporary)
        return false, promote_error
    end
    os.remove(backup)
    return true
end

local function save_state(force)
    if not Runtime.state_loaded then return false end
    if not force and not Runtime.state_dirty then return true end

    if TEST_MODE then
        Runtime.state_dirty = false
        Runtime.last_checkpoint = os.time()
        return true
    end
    if not Runtime.state_path then return false end

    local ok, save_error = write_atomic(Runtime.state_path,
        serialize_state(Runtime.entries, os.time(), Settings.clock_mode))
    if not ok then
        log("Could not save cooldown state: " .. tostring(save_error), false)
        return false
    end
    Runtime.state_dirty = false
    Runtime.last_checkpoint = os.time()
    log(string.format("Checkpoint saved: %d active cooldown(s)",
        count_entries(Runtime.entries)), true)
    return true
end

local function selected_world_key()
    if TEST_MODE then return "TestWorld" end
    -- ponytail: single-world dedicated server; the FindFirstOf + IsValid +
    -- GetSelectedWorldSaveDirectoryName probe aborts (SIGABRT) on the Linux
    -- UE4SS port at world activation.
    return "ActiveWorld"
end

local function load_state_for_world(world_key)
    if Runtime.state_loaded and Runtime.world_key == world_key then return true end
    if Runtime.state_loaded then save_state(true) end

    Runtime.world_key = world_key
    Runtime.state_path = state_path_for_world(world_key)
    Runtime.entries = {}
    Runtime.tracked_spawners = setmetatable({}, { __mode = "k" })
    Runtime.mod_disable_states = setmetatable({}, { __mode = "k" })
    Runtime.pending_spawners = {}
    Runtime.pending_set = setmetatable({}, { __mode = "k" })
    Runtime.state_dirty = false

    if not TEST_MODE then
        local content = read_all(Runtime.state_path)
        if content then
            Runtime.entries = parse_state(content, Settings, os.time())
        end
    end
    Runtime.state_loaded = true
    Runtime.last_tick = os.time()
    Runtime.last_checkpoint = os.time()
    log(string.format("World state ready: %s | %d cooldown(s)",
        world_key, count_entries(Runtime.entries)), false)
    return true
end

local function ensure_world_state()
    if Runtime.state_loaded then return true end
    Runtime.world_key_attempts = Runtime.world_key_attempts + 1
    local key = selected_world_key()
    if not key and Runtime.world_key_attempts >= 5 then
        key = "ActiveWorld"
        log("World save identifier was unavailable; using the isolated ActiveWorld state file", false)
    end
    if not key then return false end
    return load_state_for_world(safe_world_key(key))
end

local function is_field_boss_spawner(spawner)
    if not is_valid(spawner) then return false end
    local ok, value = pcall(function() return spawner.IsBossSpawner end)
    if ok and value == true then return true end

    local type_ok, spawner_type = pcall(function()
        return unwrap(spawner:GetSpawnerType())
    end)
    if not type_ok or spawner_type == nil then return false end
    local numeric = tonumber(spawner_type) or tonumber(tostring(spawner_type))
    if numeric == 2 then return true end
    local text = unreal_string(spawner_type) or tostring(spawner_type)
    return text:find("FieldBoss", 1, true) ~= nil
end

local function spawner_key(spawner)
    if not is_valid(spawner) then return nil end
    local value = nil
    pcall(function() value = spawner.SaveKeyName end)
    local key = unreal_string(value)
    if key and key ~= "" and key ~= "None" then return key end

    pcall(function() value = spawner:GetSpawnerName() end)
    key = unreal_string(value)
    if key and key ~= "" and key ~= "None" then return key end
    return nil
end

local function set_mod_disabled(spawner, disabled)
    if not is_valid(spawner) then return false end
    if Runtime.mod_disable_states[spawner] == disabled then return true end
    local ok, result = pcall(function()
        return spawner:SetSpawnDisableFlag(MOD_DISABLE_FLAG, disabled)
    end)
    if not ok then
        log("Could not update the temporary spawn block: " .. tostring(result), false)
        return false
    end
    Runtime.mod_disable_states[spawner] = disabled
    return true
end

local function apply_configured_time(spawner, key)
    local desired = cooldown_for_key(Settings, key)
    local ok = pcall(function() spawner.RespawnTime = desired end)
    return ok, desired
end

local function update_flag_map(flag_map, key, disabled)
    if flag_map == nil then return false, "flag map unavailable" end
    local ok, result = pcall(function()
        if disabled then
            flag_map:Add(FName(key), true)
        else
            flag_map:Remove(FName(key))
        end
    end)
    return ok, result
end

local function update_persistent_disable_flag(key, disabled)
    local successes = 0
    local errors = {}

    local runtime_ok, runtime_error = pcall(function()
        local manager = FindFirstOf("PalNPCManager")
        if not is_valid(manager) then error("PalNPCManager unavailable") end
        local ok, result = update_flag_map(manager.RespawnDisableFlag, key, disabled)
        if not ok then error(result) end
    end)
    if runtime_ok then successes = successes + 1
    else errors[#errors + 1] = "runtime=" .. tostring(runtime_error) end

    local save_ok, save_error = pcall(function()
        local instance = FindFirstOf("PalGameInstance")
        if not is_valid(instance) then error("PalGameInstance unavailable") end
        local save_manager = unwrap(instance.SaveGameManager)
        if not is_valid(save_manager) then error("PalSaveGameManager unavailable") end
        local save_game = unwrap(save_manager:GetLoadedWorldSaveData())
        if not is_valid(save_game) then error("loaded world save unavailable") end
        local boss_data = save_game.worldSaveData.BossSpawnerSaveData
        local ok, result = update_flag_map(boss_data.RespawnDisableFlag, key, disabled)
        if not ok then error(result) end
    end)
    if save_ok then successes = successes + 1
    else errors[#errors + 1] = "save=" .. tostring(save_error) end

    if successes > 0 and #errors > 0 then
        log("Persistent flag was updated through one authoritative copy: " ..
            table.concat(errors, " | "), true)
    end
    return successes > 0, table.concat(errors, " | ")
end

local function request_respawn(spawner)
    pcall(function() spawner.RespawnTimer = 0.0 end)
    local ok, result = pcall(function() return spawner:RespawnByOutside() end)
    if ok then return true end
    ok, result = pcall(function() return spawner:SpawnRequest_ByOutside(false) end)
    return ok, result
end

local finish_cooldown

local function start_cooldown(raw_spawner, source, raw_key)
    if not is_current() or not Runtime.authority_active then return false end
    if not ensure_world_state() then return false end

    local spawner = unwrap(raw_spawner)
    if not is_field_boss_spawner(spawner) then return false end
    local key = unreal_string(raw_key) or spawner_key(spawner)
    if not key then
        log("Ignored a field boss without a stable spawner name", false)
        return false
    end

    local _, cooldown = apply_configured_time(spawner, key)
    if not set_mod_disabled(spawner, true) then
        log("Cooldown was not started because the spawn block failed for " .. key,
            false)
        return false
    end
    Runtime.tracked_spawners[spawner] = key

    if Runtime.entries[key] then
        log("Duplicate completion ignored for " .. key, true)
        return true
    end

    Runtime.entries[key] = { remaining = cooldown }
    Runtime.state_dirty = true
    save_state(true)
    log(string.format("Cooldown started: %s | %d second(s) | source=%s",
        key, cooldown, tostring(source or "unknown")), false)
    return true
end

finish_cooldown = function(spawner, key)
    local entry = Runtime.entries[key]
    if not entry or entry.remaining > 0 or not is_valid(spawner) then return false end

    local cleared, clear_error = update_persistent_disable_flag(key, false)
    if not cleared then
        log("Persistent boss flag could not be cleared for " .. key .. ": " ..
            tostring(clear_error), false)
        return false
    end

    if not set_mod_disabled(spawner, false) then
        update_persistent_disable_flag(key, true)
        return false
    end

    local spawned, spawn_error = request_respawn(spawner)
    if not spawned then
        set_mod_disabled(spawner, true)
        update_persistent_disable_flag(key, true)
        log("Respawn request failed for " .. key .. ": " .. tostring(spawn_error), false)
        return false
    end

    Runtime.entries[key] = nil
    Runtime.state_dirty = true
    save_state(true)
    log("Cooldown complete; field Alpha enabled: " .. key, false)
    return true
end

local function queue_spawner(raw_spawner)
    if not Runtime.authority_active or next(Runtime.entries) == nil then return end
    local spawner = unwrap(raw_spawner)
    if not is_valid(spawner) or Runtime.pending_set[spawner] then return end
    Runtime.pending_set[spawner] = true
    Runtime.pending_spawners[#Runtime.pending_spawners + 1] = spawner
end

local function process_spawner(raw_spawner)
    local spawner = unwrap(raw_spawner)
    if not is_field_boss_spawner(spawner) then return false end
    local key = spawner_key(spawner)
    if not key then return false end

    Runtime.tracked_spawners[spawner] = key
    local entry = Runtime.entries[key]
    if not entry then return true end
    apply_configured_time(spawner, key)
    if entry.remaining > 0 then
        set_mod_disabled(spawner, true)
    else
        finish_cooldown(spawner, key)
    end
    return true
end

local function queue_expired_spawners(now)
    if now < Runtime.last_expired_scan + Settings.expired_scan_seconds then return end
    local has_due = false
    for _, entry in pairs(Runtime.entries) do
        if entry.remaining <= 0 then has_due = true break end
    end
    if not has_due then return end
    Runtime.last_expired_scan = now

    if type(FindAllOf) ~= "function" then return end
    for _, class_name in ipairs({ "BP_MonoNPCSpawner_C", "BP_PalSpawner_Standard_C" }) do
        local ok, spawners = pcall(FindAllOf, class_name)
        if ok and spawners then
            for _, spawner in ipairs(spawners) do
                local key = spawner_key(spawner)
                if key and Runtime.entries[key]
                    and Runtime.entries[key].remaining <= 0 then
                    queue_spawner(spawner)
                end
            end
        end
    end
end

local function drain_pending()
    local processed = 0
    while #Runtime.pending_spawners > 0 and processed < MAX_PENDING_PER_TICK do
        local spawner = table.remove(Runtime.pending_spawners, 1)
        Runtime.pending_set[spawner] = nil
        process_spawner(spawner)
        processed = processed + 1
    end
end

local function tick_game_thread()
    if not is_current() or not Runtime.authority_active then return end
    if not ensure_world_state() then return end

    local now = os.time()
    local elapsed = math.max(0, now - (Runtime.last_tick or now))
    Runtime.last_tick = now
    local changed = advance_entries(Runtime.entries, elapsed)
    if changed then Runtime.state_dirty = true end

    drain_pending()
    for spawner, key in pairs(Runtime.tracked_spawners) do
        if not is_valid(spawner) then
            Runtime.tracked_spawners[spawner] = nil
        else
            local entry = Runtime.entries[key]
            if entry then
                if entry.remaining > 0 then set_mod_disabled(spawner, true)
                else finish_cooldown(spawner, key) end
            end
        end
    end
    queue_expired_spawners(now)

    if Runtime.state_dirty
        and now >= (Runtime.last_checkpoint or now) + Settings.checkpoint_seconds then
        save_state(false)
    end
end

local function on_game_thread(callback)
    if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(callback)
    else callback() end
end

local function later(milliseconds, callback)
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(milliseconds, function()
            if is_current() then on_game_thread(callback) end
        end)
    else
        on_game_thread(callback)
    end
end

local function store_hook(path, first, second)
    Runtime.hooks[path] = { first = first, second = second }
end

local function register_native_hook()
    if Runtime.hooks[PROCESS_BOSS_DEFEAT] or type(RegisterHook) ~= "function" then return end
    local ok, first, second = pcall(RegisterHook, PROCESS_BOSS_DEFEAT,
        function(spawner, boss_actor, spawner_name)
            start_cooldown(spawner, "server completion", spawner_name)
        end)
    if ok then
        store_hook(PROCESS_BOSS_DEFEAT, first, second)
        log("Authoritative boss-completion hook installed", true)
    else
        log("Authoritative hook pending: " .. tostring(first), true)
    end
end

local function register_blueprint_hook(path, source)
    if Runtime.hooks[path] or type(RegisterHook) ~= "function" then return end
    -- UE4SS runs the single callback after Blueprint UFunctions whose path does
    -- not begin with /Script/. This is a fallback for Mono spawners.
    local ok, first, second = pcall(RegisterHook, path, function(spawner)
        start_cooldown(spawner, source)
    end)
    if ok then store_hook(path, first, second)
    else log("Blueprint hook pending for " .. path .. ": " .. tostring(first), true) end
end

local function try_register_hooks()
    local now = os.time()
    if now < Runtime.last_hook_retry + 5 then return end
    Runtime.last_hook_retry = now
    register_native_hook()
    -- ponytail: blueprint-path hooks (/Game/...) abort on the Linux UE4SS
    -- port at world activation; the native /Script/ hook covers the same events.
    -- register_blueprint_hook(MONO_ON_DEAD, "defeat fallback")
    -- register_blueprint_hook(MONO_ON_CAPTURE, "capture fallback")
end

local function deactivate(reason)
    if not Runtime.authority_active then return end
    save_state(true)
    for spawner in pairs(Runtime.mod_disable_states) do
        if is_valid(spawner) then set_mod_disabled(spawner, false) end
    end
    Runtime.authority_active = false
    Runtime.authority_context = nil
    Runtime.state_loaded = false
    Runtime.state_path = nil
    Runtime.world_key = nil
    Runtime.entries = {}
    Runtime.pending_spawners = {}
    log("Authoritative world deactivated (" .. tostring(reason or "transition") .. ")", true)
end

local function activate_authority(context, reason)
    if not is_current() or not context_has_authority(context) then return false end
    if Runtime.authority_active then
        ensure_world_state()
        return true
    end

    Runtime.authority_active = true
    -- ponytail: don't touch the hook context (unwrap -> context:get() is a
    -- native call that aborts on Linux UE4SS); the server is authoritative by
    -- construction.
    Runtime.authority_context = nil
    Runtime.state_loaded = false
    Runtime.world_key_attempts = 0
    Runtime.last_tick = os.time()
    Runtime.last_checkpoint = os.time()
    Runtime.last_expired_scan = 0
    Runtime.last_hook_retry = 0
    ensure_world_state()
    try_register_hooks()
    log(string.format(
        "Authoritative world activated (%s); default=%ds clock=%s checkpoint=%ds",
        tostring(reason or "world"), Settings.default_cooldown_seconds,
        Settings.clock_mode, Settings.checkpoint_seconds), false)
    return true
end

Runtime.Cleanup = function(reason)
    deactivate(reason or "cleanup")
    Runtime.enabled = false
    if type(UnregisterHook) == "function" then
        for path, ids in pairs(Runtime.hooks) do
            pcall(UnregisterHook, path, ids.first, ids.second)
        end
    end
end

if TEST_MODE then
    _G.__ALPHA_RESPAWN_SCHEDULER_TEST_API = {
        settings = Settings,
        build_settings = build_settings,
        cooldown_for_key = cooldown_for_key,
        advance_entries = advance_entries,
        serialize_state = serialize_state,
        parse_state = parse_state,
        safe_world_key = safe_world_key,
        context_has_authority = context_has_authority,
        is_field_boss_spawner = is_field_boss_spawner,
        spawner_key = spawner_key,
        start_cooldown = start_cooldown,
        finish_cooldown = finish_cooldown,
        activate_authority = activate_authority,
        deactivate = deactivate,
        runtime = Runtime,
    }
    return
end

-- ponytail: NotifyOnNewObject disabled — its callback calls IsValid() on every
-- newly-constructed spawner (native call that aborts on Linux UE4SS during
-- world load). The native ProcessBossDefeatInfo hook covers boss defeats.
-- if type(NotifyOnNewObject) == "function" then
--     for _, class_path in ipairs({ MONO_SPAWNER_CLASS, STANDARD_SPAWNER_CLASS }) do
--         pcall(NotifyOnNewObject, class_path, function(spawner)
--             if not is_current() then return true end
--             queue_spawner(spawner)
--             return false
--         end)
--     end
-- end

if type(RegisterInitGameStatePostHook) == "function" then
    pcall(RegisterInitGameStatePostHook, function(context)
        activate_authority(context, "InitGameState")
    end)
end

if type(RegisterHook) == "function" then
    local path = "/Script/Engine.GameModeBase:StartPlay"
    local ok, first, second = pcall(RegisterHook, path, function(context)
        activate_authority(context, "GameMode StartPlay")
    end)
    if ok then store_hook(path, first, second) end
end

-- ponytail: RegisterLoadMapPreHook disabled — its dispatch aborts (SIGABRT)
-- on the Linux UE4SS port; the dedicated server never changes maps, so the
-- map-boundary cleanup it drives is unnecessary.
-- if type(RegisterLoadMapPreHook) == "function" then
--     pcall(RegisterLoadMapPreHook, function()
--         if is_current() then deactivate("map-load boundary") end
--     end)
-- end

register_native_hook()

if type(LoopAsync) == "function" then
    LoopAsync(1000, function()
        if not is_current() then return true end
        if Runtime.authority_active then
            on_game_thread(function()
                try_register_hooks()
                tick_game_thread()
            end)
        end
        return false
    end)
end

-- Covers late mod loads and UE4SS restarts after InitGameState already fired.
-- ponytail: probe disabled — FindFirstOf("GameStateBase") aborts on the Linux
-- UE4SS port; StartPlay/InitGameState hooks already drive activation.
-- later(1000, function()
--     if Runtime.authority_active or type(FindFirstOf) ~= "function" then return end
--     local ok, context = pcall(FindFirstOf, "GameStateBase")
--     if ok and context then activate_authority(context, "late world probe") end
-- end)

log(string.format(
    "Loaded v%s; waiting for an authoritative world. Remote clients remain inert.",
    MOD_VERSION), false)
