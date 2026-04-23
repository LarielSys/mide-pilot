#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
SERVICE_BOOTSTRAP="${REPO_ROOT}/pilot_v1/scripts/exec_task_0019_enable_autopilot_service.sh"
MTASK_RECOVERY="${REPO_ROOT}/pilot_v1/scripts/exec_mtask_0035_recover_ap_and_drain_0033_retries.sh"
TASK_RECOVERY_0035="${REPO_ROOT}/pilot_v1/scripts/exec_task_0035_recover_ap_and_drain_0033_retries.sh"
TASK_RECOVERY_0032="${REPO_ROOT}/pilot_v1/scripts/exec_task_0032_recover_ap_and_drain_0033_retries.sh"
TASK_FORCE_0030="${REPO_ROOT}/pilot_v1/scripts/exec_task_0030_pull_and_force_mtask_0031.sh"
POLL_GUARD="${REPO_ROOT}/pilot_v1/scripts/exec_task_0016_poll_guard.sh"
STATUS_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_status.json"
LIVE_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_live.txt"

cd "${REPO_ROOT}"

echo "task=MTASK-0051"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

python3 - <<'PY'
from pathlib import Path

replacements = {
    Path("pilot_v1/scripts/worker_mtask_autopilot.sh"): [('POLL_SECONDS="${POLL_SECONDS:-180}"', 'POLL_SECONDS="${POLL_SECONDS:-60}"')],
    Path("pilot_v1/scripts/exec_task_0019_enable_autopilot_service.sh"): [('POLL_SECONDS="${POLL_SECONDS:-180}"', 'POLL_SECONDS="${POLL_SECONDS:-60}"')],
    Path("pilot_v1/scripts/exec_mtask_0035_recover_ap_and_drain_0033_retries.sh"): [('POLL_SECONDS="${POLL_SECONDS:-180}"', 'POLL_SECONDS="${POLL_SECONDS:-60}"')],
    Path("pilot_v1/scripts/exec_task_0035_recover_ap_and_drain_0033_retries.sh"): [('POLL_SECONDS="${POLL_SECONDS:-180}"', 'POLL_SECONDS="${POLL_SECONDS:-60}"')],
    Path("pilot_v1/scripts/exec_task_0032_recover_ap_and_drain_0033_retries.sh"): [('POLL_SECONDS="${POLL_SECONDS:-180}"', 'POLL_SECONDS="${POLL_SECONDS:-60}"')],
    Path("pilot_v1/scripts/exec_task_0030_pull_and_force_mtask_0031.sh"): [('POLL_SECONDS="${POLL_SECONDS:-180}"', 'POLL_SECONDS="${POLL_SECONDS:-60}"')],
    Path("pilot_v1/scripts/exec_task_0016_poll_guard.sh"): [('POLL_SECONDS="${POLL_SECONDS:-180}"', 'POLL_SECONDS="${POLL_SECONDS:-60}"')],
    Path("pilot_v1/state/worker_autopilot_status.json"): [('"poll_seconds": 180', '"poll_seconds": 60')],
    Path("pilot_v1/state/worker_autopilot_live.txt"): [('poll_seconds: 180', 'poll_seconds: 60')],
}

for path, pairs in replacements.items():
    text = path.read_text(encoding="utf-8")
    for old, new in pairs:
        text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")
PY

for file in \
  "${AUTOPILOT_SCRIPT}" \
  "${SERVICE_BOOTSTRAP}" \
  "${MTASK_RECOVERY}" \
  "${TASK_RECOVERY_0035}" \
  "${TASK_RECOVERY_0032}" \
  "${TASK_FORCE_0030}"; do
  if ! grep -q 'POLL_SECONDS="${POLL_SECONDS:-60}"' "$file"; then
    echo "error=poll_seconds_not_updated_in_${file##*/}"
    exit 1
  fi
done

if ! grep -q 'POLL_SECONDS="${POLL_SECONDS:-60}"' "${POLL_GUARD}"; then
  echo "error=poll_guard_not_updated"
  exit 1
fi
if ! grep -q '"poll_seconds": 60' "${STATUS_FILE}"; then
  echo "error=status_snapshot_not_updated"
  exit 1
fi
if ! grep -q 'poll_seconds: 60' "${LIVE_FILE}"; then
  echo "error=live_snapshot_not_updated"
  exit 1
fi

echo "autopilot_poll_default=60"
echo "heartbeat_snapshot=60"
echo "autopilot_heartbeat_patch=passed"

git add \
  "pilot_v1/scripts/worker_mtask_autopilot.sh" \
  "pilot_v1/scripts/exec_task_0019_enable_autopilot_service.sh" \
  "pilot_v1/scripts/exec_mtask_0035_recover_ap_and_drain_0033_retries.sh" \
  "pilot_v1/scripts/exec_task_0035_recover_ap_and_drain_0033_retries.sh" \
  "pilot_v1/scripts/exec_task_0032_recover_ap_and_drain_0033_retries.sh" \
  "pilot_v1/scripts/exec_task_0030_pull_and_force_mtask_0031.sh" \
  "pilot_v1/scripts/exec_task_0016_poll_guard.sh" \
  "pilot_v1/state/worker_autopilot_status.json" \
  "pilot_v1/state/worker_autopilot_live.txt"

git commit -m "worker: reduce autopilot heartbeat to 60 seconds (MTASK-0051)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
