#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
TASK_ID="MTASK-0092"
QUEUE_STAMP="${STATE_DIR}/${TASK_ID}.restart_queued.txt"
RESTART_LOG="${STATE_DIR}/${TASK_ID}.restart.log"

mkdir -p "${STATE_DIR}"

cd "${REPO_ROOT}"

echo "task=${TASK_ID}"
echo "strategy=delayed_detached_force_restart"
echo "reason=recover_stalled_autopilot_without_systemctl_dependency"

nohup bash -lc "
  sleep 20
  {
    echo \"restart_task=${TASK_ID}\"
    echo \"restart_trigger_utc=\$(date -u +%Y-%m-%dT%H:%M:%SZ)\"

    # Best-effort service restart first
    if systemctl --user daemon-reload >/dev/null 2>&1; then
      systemctl --user restart worker-mtask-autopilot.service >/dev/null 2>&1 || true
      echo \"restart_mode=systemd-user-attempted\"
      echo \"service_state_after_systemd=\$(systemctl --user is-active worker-mtask-autopilot.service 2>/dev/null || true)\"
    else
      echo \"restart_mode=systemd-user-unavailable\"
    fi

    # Always enforce a direct process restart as final authority
    pkill -f worker_mtask_autopilot.sh >/dev/null 2>&1 || true
    nohup \"${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh\" >> \"${STATE_DIR}/worker_mtask_autopilot.log\" 2>&1 &
    NEW_PID=$!
    sleep 2
    echo \"restart_mode=direct-nohup\"
    echo \"autopilot_pid=${NEW_PID}\"
    echo \"autopilot_pid_alive=\$(kill -0 ${NEW_PID} >/dev/null 2>&1 && echo yes || echo no)\"
    echo \"restart_done_utc=\$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  } >> \"${RESTART_LOG}\" 2>&1
" >/dev/null 2>&1 &

printf "queued_utc=%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "${QUEUE_STAMP}"
echo "restart_queued=true"
echo "delay_seconds=20"
echo "queued_stamp=${QUEUE_STAMP}"
echo "restart_log=${RESTART_LOG}"
echo "stdout_excerpt includes restart_queued=true"
echo "stdout_excerpt includes strategy=delayed_detached_force_restart"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
