#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-0102"
echo "objective=disk_cleanup_safe"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Disk before
BEFORE=$(df -h / | tail -1 | awk '{print $5}')
echo "disk_before=${BEFORE}"

# Safe cleanup targets only - no data, no venv, no models
echo "=== apt cache ==="
sudo apt-get clean -y 2>&1 | tail -2 || echo "apt_clean=skipped"
sudo apt-get autoremove -y 2>&1 | tail -3 || echo "autoremove=skipped"

echo "=== pip cache ==="
pip3 cache purge 2>/dev/null || echo "pip_cache=none"

echo "=== journal logs (keep last 3 days) ==="
sudo journalctl --vacuum-time=3d 2>&1 | tail -2 || echo "journal=skipped"

echo "=== /tmp cleanup (files older than 2 days) ==="
find /tmp -maxdepth 1 -type f -mtime +2 -delete 2>/dev/null && echo "tmp_old_files=cleaned" || echo "tmp_old_files=none"

echo "=== snap cache ==="
sudo sh -c 'rm -rf /var/lib/snapd/cache/*' 2>/dev/null && echo "snap_cache=cleaned" || echo "snap_cache=none"

echo "=== old log files in /tmp (mide task logs >7 days) ==="
find /tmp -name "*.log" -mtime +7 -delete 2>/dev/null && echo "old_logs=cleaned" || echo "old_logs=none"

echo "=== docker (if any dangling images) ==="
docker image prune -f 2>/dev/null | tail -1 || echo "docker=not_installed_or_nothing"

# Disk after
AFTER=$(df -h / | tail -1 | awk '{print $5}')
AFTER_FULL=$(df -h / | tail -1)
echo "disk_after=${AFTER}"
echo "disk_detail=${AFTER_FULL}"

if [[ "${AFTER}" < "${BEFORE}" ]]; then
  echo "cleanup_status=IMPROVED"
else
  echo "cleanup_status=NO_CHANGE"
fi

echo "snapshot=complete"
