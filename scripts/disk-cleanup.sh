#!/bin/bash
# disk-cleanup.sh — weekly safe cleanup of regenerable build artifacts on the
# VPS. Everything removed here is either on GitHub or regenerable:
#   - /tmp/ue4ss-fork*  (git clones — always pushed to Qiiks fork)
#   - /tmp/build* / /tmp/release*  (cmake build dirs)
#   - /tmp/*.log  (transient logs)
#   - docker build cache (prune)
# NEVER touches: volumes (game saves), running containers, docker images,
# /home/ubuntu/soak* (sampler data), stall-recovery staging.
# Installed as: 0 4 * * 1 /bin/bash /home/ubuntu/disk-cleanup.sh
# (weekly Monday 04:00 UTC — quietest window, journald evidence 08-03 showed
# disk-full is the world-drop precursor; keep >=15% headroom at all times).

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" | sudo tee -a /home/ubuntu/disk-cleanup.log > /dev/null; }

USED_BEFORE=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
log "cleanup start used=${USED_BEFORE}%"

# 1. stale git clones + build dirs (all pushed/regenerable)
sudo rm -rf /tmp/ue4ss-fork* /tmp/build* /tmp/release* /tmp/forkimg* 2>/dev/null

# 2. transient logs older than 2 days
sudo find /tmp -maxdepth 1 -name '*.log' -mtime +2 -delete 2>/dev/null

# 3. docker build cache (safe — only speeds up rebuilds)
sudo docker builder prune -f > /dev/null 2>&1

# 4. truncated container logs older than 3 days
sudo find /var/lib/docker/containers -name '*-json.log' -mtime +3 -exec truncate -s 0 {} \; 2>/dev/null

USED_AFTER=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
log "cleanup end used=${USED_AFTER}% (was ${USED_BEFORE}%)"

# 5. warn if still tight
if [ "$USED_AFTER" -ge 90 ]; then
  log "WARN: still >=90% used — investigate images/volumes manually"
fi
