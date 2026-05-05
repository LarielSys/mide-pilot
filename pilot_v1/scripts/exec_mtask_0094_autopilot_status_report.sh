#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$(cd "${SCRIPT_DIR}/../state" && pwd)"
STATUS_FILE="${STATE_DIR}/worker_autopilot_status.json"
HEARTBEAT_FILE="${STATE_DIR}/worker_autopilot_heartbeat_epoch.txt"
LIVE_FILE="${STATE_DIR}/worker_autopilot_live.txt"

echo "task=MTASK-0094"
echo "objective=autopilot_status_report"

# Full status fields
if [[ -f "$STATUS_FILE" ]]; then
  echo "--- autopilot_status_file ---"
  cat "$STATUS_FILE"
  echo "--- end ---"
  MODE=$(python3 -c "import json,sys; d=json.load(open('$STATUS_FILE')); print(d.get('mode','unknown'))" 2>/dev/null || echo "parse_error")
  LAST_TASK=$(python3 -c "import json,sys; d=json.load(open('$STATUS_FILE')); print(d.get('last_task_processed','unknown'))" 2>/dev/null || echo "parse_error")
  STACK=$(python3 -c "import json,sys; d=json.load(open('$STATUS_FILE')); print(d.get('customide_stack_state','unknown'))" 2>/dev/null || echo "parse_error")
  echo "autopilot_mode=${MODE}"
  echo "last_task_processed=${LAST_TASK}"
  echo "customide_stack_state=${STACK}"
else
  echo "autopilot_status_file=NOT_FOUND"
fi

# Heartbeat
if [[ -f "$HEARTBEAT_FILE" ]]; then
  HB=$(cat "$HEARTBEAT_FILE")
  echo "last_heartbeat_epoch=${HB}"
  NOW=$(date -u +"%s")
  AGE=$((NOW - HB))
  echo "heartbeat_age_seconds=${AGE}"
  if (( AGE < 120 )); then
    echo "heartbeat_health=FRESH"
  elif (( AGE < 300 )); then
    echo "heartbeat_health=STALE"
  else
    echo "heartbeat_health=DEAD"
  fi
fi

# Last 5 lines of live status
if [[ -f "$LIVE_FILE" ]]; then
  echo "--- last_live_status_lines ---"
  tail -5 "$LIVE_FILE"
  echo "--- end ---"
fi

echo "report=complete"
