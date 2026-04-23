#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
EVENT_LOG_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_events.log"
STATUS_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_status.json"
LIVE_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_live.txt"
LOG_FILE="${REPO_ROOT}/pilot_v1/state/worker_mtask_autopilot.log"

cd "${REPO_ROOT}"

echo "task=MTASK-0070"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

if ! grep -q 'WORKER_LOG_TZ="${WORKER_LOG_TZ:-America/New_York}"' "${AUTOPILOT_SCRIPT}"; then
  echo "error=timezone_patch_not_present"
  exit 1
fi
if ! grep -q '^now_local_ts() {' "${AUTOPILOT_SCRIPT}"; then
  echo "error=now_local_ts_missing"
  exit 1
fi

# Restart so the running process loads latest timestamp logic.
if systemctl --user status worker-mtask-autopilot.service >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart worker-mtask-autopilot.service
  SERVICE_STATE="$(systemctl --user is-active worker-mtask-autopilot.service || true)"
else
  pkill -f "worker_mtask_autopilot.sh --worker-id=${WORKER_ID}" || true
  nohup "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --poll-seconds=60 >> "${LOG_FILE}" 2>&1 &
  SERVICE_STATE="fallback-nohup"
fi

echo "service_state=${SERVICE_STATE}"

# Force one immediate write_status cycle with current runtime code.
POLL_SECONDS=60 PUSH_IDLE_HEARTBEAT=false WORKER_LOG_TZ=America/New_York \
  bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --once >/tmp/mtask0070-once.log 2>&1 || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2} \| mode=' "${EVENT_LOG_FILE}"; then
    break
  fi
  sleep 2
done

if ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2} \| mode=' "${EVENT_LOG_FILE}"; then
  echo "error=events_not_local_offset"
  exit 1
fi
if ! grep -q '"last_run_local": ' "${STATUS_FILE}"; then
  echo "error=status_last_run_local_missing"
  exit 1
fi
if ! grep -q '"log_timezone": "America/New_York"' "${STATUS_FILE}"; then
  echo "error=status_log_timezone_missing"
  exit 1
fi
if ! grep -q 'updated_local: ' "${LIVE_FILE}"; then
  echo "error=live_updated_local_missing"
  exit 1
fi
if ! grep -q 'log_timezone: America/New_York' "${LIVE_FILE}"; then
  echo "error=live_log_timezone_missing"
  exit 1
fi

echo "autopilot_runtime_restarted=passed"
echo "events_timezone_local_offset=passed"
echo "status_timezone_fields_present=passed"
echo "phase32_log_runtime_restart=passed"

git add \
  "pilot_v1/state/worker_autopilot_events.log" \
  "pilot_v1/state/worker_autopilot_status.json" \
  "pilot_v1/state/worker_autopilot_live.txt"

git commit -m "worker: restart autopilot runtime for eastern log timestamps (MTASK-0070)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
