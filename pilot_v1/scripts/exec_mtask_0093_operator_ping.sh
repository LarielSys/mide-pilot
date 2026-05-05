#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-0093"
echo "objective=operator_reconnect_ping"
echo "hostname=$(hostname)"
echo "date_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "epoch_utc=$(date -u +"%s")"
echo "worker_id=${WORKER_ID:-ubuntu-worker-01}"
echo "worker_name=${WORKER_NAME:-ubuntu-atlas-01}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$(cd "${SCRIPT_DIR}/../state" && pwd)"

HEARTBEAT_FILE="${STATE_DIR}/worker_autopilot_heartbeat_epoch.txt"
STATUS_FILE="${STATE_DIR}/worker_autopilot_status.json"

if [[ -f "$HEARTBEAT_FILE" ]]; then
  LAST_HEARTBEAT=$(cat "$HEARTBEAT_FILE")
  echo "last_heartbeat_epoch=${LAST_HEARTBEAT}"
  echo "last_heartbeat_utc=$(date -u -d @${LAST_HEARTBEAT} +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r ${LAST_HEARTBEAT} +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo unknown)"
else
  echo "last_heartbeat_epoch=not_found"
fi

if [[ -f "$STATUS_FILE" ]]; then
  echo "autopilot_status=$(cat "$STATUS_FILE" | grep -o '"status"[^,}]*' | head -1)"
else
  echo "autopilot_status=status_file_not_found"
fi

echo "ping=ok"
echo "issued_by=vs-copilot-main-operator"
