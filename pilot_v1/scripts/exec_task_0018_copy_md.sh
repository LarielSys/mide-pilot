#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_MD="${REPO_ROOT}/pilot_v1/README.md"
TARGET_MD="${REPO_ROOT}/pilot_v1/state/TASK-0018-copied.md"

cp "${SOURCE_MD}" "${TARGET_MD}"

echo "TASK-0018 copy complete"
echo "source=${SOURCE_MD}"
echo "target=${TARGET_MD}"
echo "worker_name=${WORKER_NAME:-unknown}"
echo "worker_id=${WORKER_ID:-unknown}"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
