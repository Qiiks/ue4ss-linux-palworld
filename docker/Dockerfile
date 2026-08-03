# Fixed-fork Palworld dedicated server image.
#
# Derived from obnyis/palworld-dedicated-server (keeps its proven plumbing:
# steamcmd install/update, REST API, config templating, player detection, webhooks)
# with the Qiiks fixed UE4SS fork stack layered on top:
#   - reviewed libUE4SS.so (leak fix + all upstream fixes, PRs #2-#13)
#   - FName_ToString.lua signature override (the leak fix activation)
#   - production mod set (ARS, PSO, ServerMaintenance, WorkProbe, UE4SSStatus)
#   - UE4SS-settings.ini with GUI console off (headless-server SIGSEGV fix)
#   - no forced game updates by default (ALWAYS_UPDATE_ON_START=false)
#     -> update game deliberately, then re-verify FName_ToString.lua still resolves
#        (AOBs shift on game updates; see docs/optimization-map.md §leak-fix)

FROM obnyis/palworld-dedicated-server:libx11-gdb

# ---- our UE4SS fork stack ----
# The game root (/palworld) is normally a volume, so we can't bake files there —
# instead we bake a payload under /opt/ue4ss-fork and a wrapper CMD that overlays
# it into the volume on every boot, BEFORE servermanager.sh decides whether to
# download stock UE4SS (it skips the download when ./PalServerUE4SS.sh exists).
COPY ue4ss/ /opt/ue4ss-fork/

# Wrapper CMD: overlay fixed UE4SS stack, then hand off to the stock servermanager.
# Entrypoint (PUID/PGID setup) runs first; CMD runs as the steam user.
COPY scripts/fork-overlay.sh /scripts/fork-overlay.sh
RUN chmod +x /scripts/fork-overlay.sh
CMD ["/scripts/fork-overlay.sh"]

# ---- safe defaults (overridable via env) ----
ENV ALWAYS_UPDATE_ON_START=false \
    UPDATE_ON_BOOT=false \
    ENABLE_UE4SS=true

EXPOSE 8211/udp 8212/tcp 27015/udp
