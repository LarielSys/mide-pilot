#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
LOG_FILE="${STATE_DIR}/worker_mtask_autopilot.log"

WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_LOG_TZ="${WORKER_LOG_TZ:-America/New_York}"
POLL_SECONDS="${POLL_SECONDS:-60}"

mkdir -p "${STATE_DIR}" "$HOME/.config/systemd/user" "$HOME/.config/mide"
chmod +x "${AUTOPILOT_SCRIPT}"

cat > "$HOME/.config/mide/worker.env" <<ENV
WORKER_ID=${WORKER_ID}
WORKER_NAME=${WORKER_NAME}
WORKER_LOG_TZ=${WORKER_LOG_TZ}
PUSH_IDLE_HEARTBEAT=true
POLL_SECONDS=${POLL_SECONDS}
ENV

SERVICE_FILE="$HOME/.config/systemd/user/worker-mtask-autopilot.service"
cat > "${SERVICE_FILE}" <<UNIT
[Unit]
Description=MIDE Worker MTask Autopilot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
EnvironmentFile=%h/.config/mide/worker.env
ExecStart=/usr/bin/bash ${AUTOPILOT_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
UNIT

if systemctl --user daemon-reload >/dev/null 2>&1; then
  systemctl --user enable --now worker-mtask-autopilot.service
  echo "startup_mode=systemd-user"
  echo "service_state=$(systemctl --user is-active worker-mtask-autopilot.service || true)"
else
  echo "startup_mode=fallback-no-systemd-user"
  (crontab -l 2>/dev/null | grep -v 'worker_mtask_autopilot.sh' || true; \
    echo "@reboot cd ${REPO_ROOT} && WORKER_ID=${WORKER_ID} WORKER_NAME=${WORKER_NAME} WORKER_LOG_TZ=${WORKER_LOG_TZ} PUSH_IDLE_HEARTBEAT=true POLL_SECONDS=${POLL_SECONDS} nohup ${AUTOPILOT_SCRIPT} >> ${LOG_FILE} 2>&1 &") | crontab -
  nohup "${AUTOPILOT_SCRIPT}" >> "${LOG_FILE}" 2>&1 &
  echo "service_state=started-nohup"
fi

echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "worker_log_tz=${WORKER_LOG_TZ}"
echo "poll_seconds=${POLL_SECONDS}"
echo "status_file=${STATE_DIR}/worker_autopilot_status.json"
echo "heartbeat_file=${STATE_DIR}/worker_autopilot_heartbeat_epoch.txt"
echo "log_file=${LOG_FILE}"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
