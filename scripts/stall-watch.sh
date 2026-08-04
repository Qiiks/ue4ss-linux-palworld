#!/bin/bash
# stall-watch.sh — autosave-stall watchdog for Palworld containers.
# Detects the silent-stall pattern (game thread alive but world sim + autosave
# stopped) within STALE_MIN of the last Level.sav write, and stages recovery
# assets BEFORE any restart is attempted (a stalled boot's shutdown save can
# corrupt — 2026-08-04 incident). Run via cron: */5 * * * * /bin/bash /home/ubuntu/stall-watch.sh
#
# Design: detection-only + recovery staging. It does NOT auto-restart:
# a restart on a stalled boot writes a corrupt shutdown save; recovery must
# be a deliberate human/agent action using the staged snapshot.
#
# v1.1 (2026-08-04): root-cause evidence — the 08-03/04 world-drop was a
# disk-full event: journald "No space left on device" at 13:30, corrupt
# autosave at 14:43, world unload (camps 6->1, live 274k->19k), 19h zombie.
# Added disk-pressure check: >=90% used = world-drop risk warning.

STALE_MIN=15
RECOVERY=/home/ubuntu/stall-recovery
LOG=/home/ubuntu/stall-watch.log

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" | sudo tee -a $LOG > /dev/null; }

check_container() {
  local NAME="$1" VOL="$2"
  local SAV=$(sudo find "$VOL/Pal/Saved/SaveGames" -name Level.sav -not -path '*backup*' -not -path '*world_save_bak*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)
  [ -z "$SAV" ] && return
  local MTIME=$(echo "$SAV" | awk '{print $1}')
  local SAV_PATH=$(echo "$SAV" | cut -d' ' -f2-)
  local NOW=$(date +%s)
  local AGE=$((NOW - $(echo $MTIME | cut -d. -f1)))
  local ALIVE=$(sudo docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)
  if [ "$ALIVE" = "true" ] && [ $AGE -gt $((STALE_MIN*60)) ]; then
    # game alive but save stale -> silent stall (crash would show as not running)
    local STAMP=$(date -u +%Y%m%d-%H%M%S)
    mkdir -p $RECOVERY/$STAMP-$NAME
    # stage the current (possibly bad) Level.sav + the last good autosave snapshots
    sudo cp -a "$SAV_PATH" $RECOVERY/$STAMP-$NAME/Level.sav.current 2>/dev/null
    sudo find "$VOL/Pal/Saved/SaveGames" -path '*backup/world*' -name Level.sav -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -3 | while read -r T P; do
      sudo cp -a "$P" "$RECOVERY/$STAMP-$NAME/backup-$(basename $(dirname $P)).sav" 2>/dev/null
    done
    log "STALL name=$NAME age=${AGE}s save=$SAV_PATH staged=$RECOVERY/$STAMP-$NAME"
  fi
}

# down-detection: containers not running (crash vs stall discrimination)
for C in palworld-test palworld-wyxxyjqraays3f2dihlc7gb4; do
  R=$(sudo docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)
  [ "$R" = "true" ] || log "DOWN name=$C (container not running)"
done

check_container palworld-test /var/lib/docker/volumes/palworld-test-data/_data
check_container palworld-wyxxyjqraays3f2dihlc7gb4 /var/lib/docker/volumes/wyxxyjqraays3f2dihlc7gb4_palworld-data/_data

# disk-pressure check: journald reports "No space left on device" before world-drop
# (2026-08-03 13:30 journal evidence + 14:43 corrupt autosave -> world unload)
DISK_USED=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$DISK_USED" -ge 90 ]; then
  log "DISK name=host used=${DISK_USED}% (>=90%) - world-drop risk, free space now"
fi
