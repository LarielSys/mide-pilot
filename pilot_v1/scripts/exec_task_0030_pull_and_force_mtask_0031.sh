#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
SERVICE_NAME="worker-mtask-autopilot.service"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
POLL_SECONDS="${POLL_SECONDS:-180}"
RESTART_MODE=""
FORCE_ONCE_TIMEOUT_SECONDS="${FORCE_ONCE_TIMEOUT_SECONDS:-900}"

echo "task=TASK-0030"
echo "worker_id=${WORKER_ID}"
echo "repo_root=${REPO_ROOT}"
echo "force_once_timeout_seconds=${FORCE_ONCE_TIMEOUT_SECONDS}"

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

run_forced_autopilot_once() {
  local run_log
  run_log="$(mktemp)"

  echo "autopilot_forced_once=start"
  echo "autopilot_forced_once_task=MTASK-0031"

  if timeout "${FORCE_ONCE_TIMEOUT_SECONDS}" \
    bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --poll-seconds="${POLL_SECONDS}" --force-task=MTASK-0031 --once \
    > >(tee "${run_log}") 2>&1; then
    echo "autopilot_forced_once=done"
  else
    rc=$?
    echo "error=autopilot_forced_once_failed"
    echo "autopilot_forced_once_exit_code=${rc}"
    echo "autopilot_forced_once_log_tail=$(tail -n 60 "${run_log}" | tr '\n' ';')"
    return 1
  fi
}

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

run_forced_autopilot_once

echo "forced_task=MTASK-0031"

autopilot_restart
trap - EXIT

echo "autopilot_restart_mode=${RESTART_MODE}"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
