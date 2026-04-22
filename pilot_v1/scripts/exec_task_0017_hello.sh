#!/usr/bin/env bash
set -euo pipefail

echo "Hello World from TASK-0017"
echo "worker_name=${WORKER_NAME:-ubuntu-atlas-01}"
echo "worker_id=${WORKER_ID:-ubuntu-worker-01}"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
