#!/bin/bash
# soak-trend.sh — hourly four-signal trend analysis for the Palworld soak.
# Reads: SM snapshot logs (in-game /proc self-status + census) and the host
# sampler log. Appends a compact trend line per container to soak-trend.log.
# Run via root cron:  0 * * * * /bin/bash /home/ubuntu/soak-trend.sh
#
# The four signals (oracle's discriminator):
#   rss        - game process RSS (host sampler, correct PID since v1.1)
#   objs       - UObject census (SM GetObjectCount, game thread)
#   lua        - Lua heap KB (SM collectgarbage count, async-safe)
#   cpu        - docker-level CPU (host sampler)
# Slopes: delta between consecutive hourly samples; the soak restarts break
# the series (boot resets), so each line carries the boot uptime.
#
# v1.1 FIX: SM v1.7 snapshot lines no longer carry a "snapshot:" prefix —
# they start with the epoch directly ("1785836387 rss_kb=..."), so the
# snapshot extraction greps for the epoch+rss_kb pattern instead.

TVOL=/var/lib/docker/volumes/palworld-test-data/_data
LVOL=/var/lib/docker/volumes/wyxxyjqraays3f2dihlc7gb4_palworld-data/_data
OUT=/home/ubuntu/soak-trend.log
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

snap() {
  # $1 = volume root. Latest SM snapshot line with objs= and rss_kb= and lua_kb=
  # (fields appear in order rss_kb, swap_kb, lua_kb, objs — extract each separately)
  local VOL="$1"
  local LINE=$(sudo grep -aE "[0-9]{10} rss_kb=" "$VOL/Pal/Binaries/Linux/ue4ss/Mods/ServerMaintenance/mem-snapshots.log" 2>/dev/null | tail -1)
  local R=$(echo "$LINE" | grep -oE 'rss_kb=[0-9]+' | head -1)
  local L=$(echo "$LINE" | grep -oE 'lua_kb=[0-9]+' | head -1)
  local O=$(echo "$LINE" | grep -oE 'objs=[0-9]+' | head -1)
  echo "$O $R $L"
}

host_rss() {
  # $1 = container name. Latest game RSS from the host sampler.
  sudo grep -a "game_pid=" /home/ubuntu/soak-sampler.log 2>/dev/null | grep "$1" | tail -1 | grep -oE "rss_kb=[0-9]+" | head -1
}

host_cpu() {
  sudo grep -a "$1 cpu=" /home/ubuntu/soak-sampler.log 2>/dev/null | tail -1 | grep -oE "cpu=[0-9.]+%?" | head -1
}

TEST_SNAP=$(snap "$TVOL")
LIVE_SNAP=$(snap "$LVOL")

echo "$TS test[rss_kb=$(host_rss palworld-test) cpu=$(host_cpu palworld-test)] snap[$TEST_SNAP] live[rss_kb=$(host_rss palworld-wyxxyjqraays3f2dihlc7gb4) cpu=$(host_cpu palworld-wyxxyjqraays3f2dihlc7gb4)] snap[$LIVE_SNAP]" | sudo tee -a "$OUT" > /dev/null

# uptime of the game process per container (boot-reset marker for slope math)
for C in palworld-test palworld-wyxxyjqraays3f2dihlc7gb4; do
  UP=$(sudo docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null)
  echo "$TS $C uptime=$UP" | sudo tee -a "$OUT" > /dev/null
done
