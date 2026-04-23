#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
TASK_ID="MTASK-0072"
QUEUE_STAMP="${STATE_DIR}/${TASK_ID}.restart_queued.txt"
RESTART_LOG="${STATE_DIR}/${TASK_ID}.restart.log"

mkdir -p "${STATE_DIR}"

echo "task=${TASK_ID}"
echo "strategy=delayed_detached_restart"
echo "reason=allow_autopilot_result_commit_before_restart"

# Run restart outside autopilot process and after delay so result commit/push can finish first.
nohup bash -lc "
  sleep 25
  {
    echo \"restart_task=${TASK_ID}\"
    echo \"restart_trigger_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    if systemctl --user daemon-reload >/dev/null 2>&1; then
      systemctl --user restart worker-mtask-autopilot.service
      echo \"restart_mode=systemd-user\"
      echo \"service_state=$(systemctl --user is-active worker-mtask-autopilot.service || true)\"
    else
      pkill -f worker_mtask_autopilot.sh >/dev/null 2>&1 || true
      nohup \"${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh\" >> \"${STATE_DIR}/worker_mtask_autopilot.log\" 2>&1 &
      echo \"restart_mode=fallback-nohup\"
      echo \"service_state=started-nohup\"
    fi
    echo \"restart_done_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  } >> \"${RESTART_LOG}\" 2>&1
" >/dev/null 2>&1 &

printf "queued_utc=%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "${QUEUE_STAMP}"
echo "restart_queued=true"
echo "delay_seconds=25"
echo "queued_stamp=${QUEUE_STAMP}"
echo "restart_log=${RESTART_LOG}"
echo "stdout_excerpt includes restart_queued=true"
echo "stdout_excerpt includes strategy=delayed_detached_restart"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
