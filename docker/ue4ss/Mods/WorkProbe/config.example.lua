-- WorkProbe configuration (optional; delete or rename this file to use defaults).
-- Place as config.lua next to the mod (ue4ss/Mods/WorkProbe/config.lua).

-- Enable/disable the probe entirely
enabled = true

-- Probe interval in seconds (game-thread timer; EngineTick-riding)
interval_sec = 60

-- Cap the number of UPalWorkProgress objects sampled per run
max_objects = 32

-- Absolute in-container log path (game cwd is /palworld/Pal/Binaries/Linux)
log_path = "/palworld/Pal/Binaries/Linux/ue4ss/Mods/WorkProbe/workprobe.log"

-- Call GetRemainWorkAmount() (BlueprintPure UFunction) per sample; false skips
-- the reflection call (slightly cheaper, remain column becomes n/a)
read_remain = true
