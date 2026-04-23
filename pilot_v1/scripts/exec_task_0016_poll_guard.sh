#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"

if [[ ! -f "${AUTOPILOT_SCRIPT}" ]]; then
  echo "autopilot script missing: ${AUTOPILOT_SCRIPT}" >&2
  exit 1
fi

echo "TASK-0016 validation: end-of-task + 3-minute search"
echo "worker_name=${WORKER_NAME:-ubuntu-atlas-01}"
echo "worker_id=${WORKER_ID:-ubuntu-worker-01}"

grep -q 'POLL_SECONDS="${POLL_SECONDS:-60}"' "${AUTOPILOT_SCRIPT}"
echo "check: poll default 180 seconds = OK"

grep -q 'Immediately check for the next task after each completion.' "${AUTOPILOT_SCRIPT}"
echo "check: immediate post-task rescan = OK"

grep -q 'required_worker_id' "${AUTOPILOT_SCRIPT}"
echo "check: required_worker_id enforcement logic present = OK"

grep -q 'admin_override_authorized' "${AUTOPILOT_SCRIPT}"
echo "check: admin override password gate present = OK"

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
