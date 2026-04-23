#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
STATUS_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_status.json"
EVENTS_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_events.log"
RUNTIME_ROUTE="${REPO_ROOT}/pilot_v1/customide/backend/app/routes/runtime.py"

cd "${REPO_ROOT}"

echo "task=MTASK-0058"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

if [[ ! -f "${STATUS_FILE}" ]]; then
  echo "error=status_file_missing"
  exit 1
fi

poll_seconds="$(python3 - <<'PY'
import json
from pathlib import Path
p = Path('pilot_v1/state/worker_autopilot_status.json')
obj = json.loads(p.read_text(encoding='utf-8'))
print(obj.get('poll_seconds', ''))
PY
)"

if [[ "${poll_seconds}" != "60" ]]; then
  echo "error=poll_seconds_not_60 value=${poll_seconds}"
  exit 1
fi

echo "cadence_60s=passed"

if ! grep -q '@router.get("/sync-health")' "${RUNTIME_ROUTE}"; then
  echo "error=sync_health_route_missing"
  exit 1
fi
if ! grep -q '"sync_error": sync_error' "${RUNTIME_ROUTE}"; then
  echo "error=sync_health_contract_missing"
  exit 1
fi

echo "sync_health_contract=passed"

before_count="$(grep -c 'git_sync failed; retrying next poll' "${EVENTS_FILE}" 2>/dev/null || true)"
POLL_SECONDS=60 PUSH_IDLE_HEARTBEAT=false bash "${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh" --worker-id="${WORKER_ID}" --once >/tmp/mtask0058-once.log 2>&1 || true
after_count="$(grep -c 'git_sync failed; retrying next poll' "${EVENTS_FILE}" 2>/dev/null || true)"

if [[ "${before_count}" != "${after_count}" ]]; then
  echo "error=new_sync_drift_event_detected before=${before_count} after=${after_count}"
  exit 1
fi

echo "sync_drift_gate=passed"

git add \
  "pilot_v1/state/worker_autopilot_events.log" \
  "pilot_v1/state/worker_autopilot_live.txt" \
  "pilot_v1/state/worker_autopilot_status.json"
git commit -m "autopilot: phase20 sync stability gate observation (MTASK-0058)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
