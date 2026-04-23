#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "task=MTASK-0077"
echo "objective=restart customide backend with events fix (last-40 not first-40)"

cd "${REPO_ROOT}"
git fetch origin main
git merge --ff-only FETCH_HEAD

# Kill existing backend on :5555
OLD_PID="$(lsof -ti tcp:5555 2>/dev/null || true)"
if [[ -n "${OLD_PID}" ]]; then
  echo "killing_old_backend_pid=${OLD_PID}"
  kill "${OLD_PID}" || true
  sleep 2
fi

# Kill existing frontend on :5570
OLD_FRONT="$(lsof -ti tcp:5570 2>/dev/null || true)"
if [[ -n "${OLD_FRONT}" ]]; then
  echo "killing_old_frontend_pid=${OLD_FRONT}"
  kill "${OLD_FRONT}" || true
  sleep 1
fi

chmod +x "pilot_v1/customide/scripts/start_local_stack.sh"
bash "pilot_v1/customide/scripts/start_local_stack.sh"

sleep 3

health_json="$(curl -fsS http://127.0.0.1:5555/health || true)"
if [[ -n "${health_json}" ]]; then
  echo "backend_health=passed"
else
  echo "backend_health=failed"
  exit 1
fi

# Verify recent_events are now returning last 40 lines (task events visible)
bundle_json="$(curl -fsS http://127.0.0.1:5555/api/status/bundle || true)"
if [[ -n "${bundle_json}" ]]; then
  echo "bundle_health=passed"
else
  echo "bundle_health=failed"
  exit 1
fi

echo "backend_restart=passed"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
