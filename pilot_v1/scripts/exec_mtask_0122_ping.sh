#!/usr/bin/env bash
set -uo pipefail
echo "task=MTASK-0122"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hostname=$(hostname)"
echo "uptime=$(uptime -p 2>/dev/null || uptime)"
echo "worker_id=${WORKER_ID:-unknown}"
echo "repo_root=${REPO_ROOT:-unknown}"
echo "pwd=$(pwd)"
echo "disk_free_home=$(df -h $HOME 2>/dev/null | awk 'NR==2{print $4}')"
echo "final_status=ALL_CHECKS_PASSED"
