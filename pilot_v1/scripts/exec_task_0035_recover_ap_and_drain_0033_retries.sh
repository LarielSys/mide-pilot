#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
SERVICE_NAME="worker-mtask-autopilot.service"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
POLL_SECONDS="${POLL_SECONDS:-60}"
FORCE_ONCE_TIMEOUT_SECONDS="${FORCE_ONCE_TIMEOUT_SECONDS:-900}"

TASKS=("MTASK-0033-RETRY2" "MTASK-0033-RETRY3")

echo "task=TASK-0035"
echo "worker_id=${WORKER_ID}"
echo "force_once_timeout_seconds=${FORCE_ONCE_TIMEOUT_SECONDS}"

autopilot_start() {
  if systemctl --user list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}"; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user start "${SERVICE_NAME}" || true
    echo "autopilot_start_mode=systemd-user"
  else
    nohup bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --poll-seconds="${POLL_SECONDS}" >/dev/null 2>&1 &
    echo "autopilot_start_mode=nohup"
  fi
}

autopilot_stop() {
  if systemctl --user list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}"; then
    systemctl --user stop "${SERVICE_NAME}" || true
    echo "autopilot_stop_mode=systemd-user"
  else
    pkill -f "worker_mtask_autopilot.sh" || true
    echo "autopilot_stop_mode=pkill"
  fi
}

run_forced_once() {
  local tid="$1"
  local run_log
  run_log="$(mktemp)"

  echo "forced_once_start=${tid}"
  if timeout "${FORCE_ONCE_TIMEOUT_SECONDS}" \
    bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --poll-seconds="${POLL_SECONDS}" --force-task="${tid}" --once \
    > >(tee "${run_log}") 2>&1; then
    echo "forced_once_done=${tid}"
  else
    rc=$?
    echo "forced_once_failed=${tid}"
    echo "forced_once_exit_code_${tid}=${rc}"
    echo "forced_once_log_tail_${tid}=$(tail -n 60 "${run_log}" | tr '\n' ';')"
    return 1
  fi
}

cd "${REPO_ROOT}"
git fetch origin
git pull --ff-only origin main

autopilot_stop
sleep 2

for tid in "${TASKS[@]}"; do
  result_file="${REPO_ROOT}/pilot_v1/results/${tid}.result.json"
  if [[ -f "${result_file}" ]]; then
    echo "skip_already_has_result=${tid}"
    continue
  fi

  task_file="${REPO_ROOT}/pilot_v1/tasks/${tid}.json"
  if [[ ! -f "${task_file}" ]]; then
    echo "skip_task_missing=${tid}"
    continue
  fi

  run_forced_once "${tid}"
done

autopilot_start

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
