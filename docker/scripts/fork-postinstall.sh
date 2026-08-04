#!/bin/bash
# fork-postinstall.sh — re-copy the fixed mod set into the game root AFTER the
# servermanager has run fresh_install/update (steamcmd wipes Mods/ on install).
# Wired in via CUSTOM_SCRIPT_ENABLED=true + CUSTOM_SCRIPT_PATH (Dockerfile env).
#
# Runs as the steam user, from $GAME_ROOT, after setup_configs/setup_ue4ss.

set -e

source /includes/colors.sh

FORK_ROOT=/opt/ue4ss-fork
UE4SS_DEST="${GAME_ROOT}/Pal/Binaries/Linux/ue4ss"

if [ ! -d "${FORK_ROOT}/Mods" ]; then
    exit 0
fi

ei ">>> fork-postinstall: (re)installing mod set"
mkdir -p "${UE4SS_DEST}/Mods"

# mods.txt enablement file (root of ue4ss dir, next to the .so)
[ -f "${FORK_ROOT}/mods.txt" ] && cp -f "${FORK_ROOT}/mods.txt" "${UE4SS_DEST}/mods.txt"

for moddir in "${FORK_ROOT}"/Mods/*/; do
    [ -d "$moddir" ] || continue
    modname="$(basename "$moddir")"
    mkdir -p "${UE4SS_DEST}/Mods/${modname}"
    for f in "${moddir}"*; do
        [ -e "$f" ] || continue
        fname="$(basename "$f")"
        if [ -d "$f" ]; then
            cp -rf "$f" "${UE4SS_DEST}/Mods/${modname}/"
        elif [ "${fname}" = "config.lua" ] && [ -f "${UE4SS_DEST}/Mods/${modname}/config.lua" ]; then
            ew "> fork-postinstall: keeping existing config.lua for ${modname}"
            continue
        else
            cp -f "$f" "${UE4SS_DEST}/Mods/${modname}/"
        fi
    done
done

es ">>> fork-postinstall: mod set in place"
