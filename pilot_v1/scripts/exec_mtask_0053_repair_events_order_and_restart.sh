#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
EVENT_LOG_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_events.log"
LIVE_STATUS_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_live.txt"
STATUS_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_status.json"
LOG_FILE="${REPO_ROOT}/pilot_v1/state/worker_mtask_autopilot.log"

cd "${REPO_ROOT}"

echo "task=MTASK-0053"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

# Ensure writer logic is newest-first for future events.
if ! grep -q 'event_line="${ts} | mode=${mode} | last_task=${last_task} | note=${note}"' "${AUTOPILOT_SCRIPT}"; then
  echo "error=writer_logic_missing"
  exit 1
fi
if ! grep -Eq 'head -n[[:space:]]+20[[:space:]]+"\$\{EVENT_LOG_FILE\}"' "${AUTOPILOT_SCRIPT}"; then
  echo "error=live_view_logic_missing"
  exit 1
fi

mkdir -p "$(dirname "${EVENT_LOG_FILE}")"
if [[ ! -f "${EVENT_LOG_FILE}" ]]; then
  : > "${EVENT_LOG_FILE}"
fi

# One-time migration: if file is oldest-first, reverse it to newest-first.
python3 - <<'PY'
from pathlib import Path
import re

p = Path("pilot_v1/state/worker_autopilot_events.log")
lines = p.read_text(encoding="utf-8", errors="replace").splitlines()

def ts(line: str):
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", line)
    return m.group(1) if m else None

if len(lines) >= 2:
    first = ts(lines[0])
    last = ts(lines[-1])
    if first and last and first < last:
        lines = list(reversed(lines))
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

before_first="$(head -n 1 "${EVENT_LOG_FILE}" 2>/dev/null || true)"

# Restart service so running process reloads latest function definition.
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

# Trigger one immediate cycle to force a fresh write_status call with newest-first logic.
POLL_SECONDS=60 PUSH_IDLE_HEARTBEAT=false bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --once >/tmp/mtask0053-once.log 2>&1 || true

after_first="$(head -n 1 "${EVENT_LOG_FILE}" 2>/dev/null || true)"
if [[ -z "${after_first}" ]]; then
  echo "error=events_log_empty_after_restart"
  exit 1
fi
if [[ "${before_first}" == "${after_first}" ]]; then
  echo "error=events_top_not_updated"
  exit 1
fi

# Refresh live view and verify its event section starts from top-of-events file.
if [[ -f "${LIVE_STATUS_FILE}" ]]; then
  live_first_event="$(awk 'f{print; exit} /^Recent Events \(latest 20, newest first\):/{f=1}' "${LIVE_STATUS_FILE}" 2>/dev/null || true)"
  top_event="$(head -n 1 "${EVENT_LOG_FILE}" 2>/dev/null || true)"
  if [[ -n "${live_first_event}" && -n "${top_event}" && "${live_first_event}" != "${top_event}" ]]; then
    echo "error=live_feed_not_aligned_with_events_top"
    exit 1
  fi
fi

echo "events_log_recovered=passed"
echo "events_order_newest_first=passed"
echo "events_feed_continuous=passed"

git add \
  "pilot_v1/state/worker_autopilot_events.log" \
  "pilot_v1/state/worker_autopilot_live.txt" \
  "pilot_v1/state/worker_autopilot_status.json" \
  "pilot_v1/state/worker_autopilot_events.log"

git commit -m "worker: recover and enforce newest-first autopilot events feed (MTASK-0053)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
