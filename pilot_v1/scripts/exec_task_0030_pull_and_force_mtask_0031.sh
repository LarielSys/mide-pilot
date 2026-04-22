#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
SERVICE_NAME="worker-mtask-autopilot.service"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
POLL_SECONDS="${POLL_SECONDS:-180}"
RESTART_MODE=""

echo "task=TASK-0030"
echo "worker_id=${WORKER_ID}"
echo "repo_root=${REPO_ROOT}"

autopilot_restart() {
  if systemctl --user list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}"; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user start "${SERVICE_NAME}"
    RESTART_MODE="systemd-user"
  else
    nohup bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --poll-seconds="${POLL_SECONDS}" >/dev/null 2>&1 &
    RESTART_MODE="nohup"
  fi
}

cleanup() {
  autopilot_restart || true
}
trap cleanup EXIT

cd "${REPO_ROOT}"
git fetch origin
git pull --ff-only origin main

if ! grep -q 'MTASK-\*\.json' "${AUTOPILOT_SCRIPT}"; then
  echo "error=autopilot_mtask_support_missing"
  echo "expected=pattern MTASK-*.json in ${AUTOPILOT_SCRIPT}"
  exit 1
fi

echo "autopilot_mtask_support=ok"

if systemctl --user list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}"; then
  systemctl --user stop "${SERVICE_NAME}" || true
else
  pkill -f "worker_mtask_autopilot.sh" || true
fi
sleep 2

bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --poll-seconds="${POLL_SECONDS}" --force-task=MTASK-0031 --once

echo "forced_task=MTASK-0031"

autopilot_restart
trap - EXIT

echo "autopilot_restart_mode=${RESTART_MODE}"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
