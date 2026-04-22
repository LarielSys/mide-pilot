#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
TIMESTAMP_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "hello, i am alive"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "timestamp_utc=${TIMESTAMP_UTC}"
