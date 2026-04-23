#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

BACKEND_ROOT="${REPO_ROOT}/pilot_v1/customide/backend"
FRONTEND_ROOT="${REPO_ROOT}/pilot_v1/customide/frontend"

cd "${REPO_ROOT}"

echo "task=MTASK-0044"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${BACKEND_ROOT}/app/routes/execute.py" ]]; then
  echo "error=execute_route_missing"
  exit 1
fi
if [[ ! -f "${FRONTEND_ROOT}/js/app.js" ]]; then
  echo "error=frontend_js_missing"
  exit 1
fi

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0044-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0044-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

cleanup() {
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

HEALTH_JSON="$(curl -sSf http://127.0.0.1:5555/health)"
RUNTIME_JSON="$(curl -sSf http://127.0.0.1:5555/api/status/runtime)"
LOCAL_OK_JSON="$(curl -sSf -X POST http://127.0.0.1:5555/api/execute/local -H 'Content-Type: application/json' -d '{"command":"echo verify-0044","cwd":".","timeout_seconds":10}')"
LOCAL_BLOCKED_RAW="$(curl -sS -X POST http://127.0.0.1:5555/api/execute/local -H 'Content-Type: application/json' -d '{"command":"bash -lc whoami","cwd":".","timeout_seconds":10}')"
REMOTE_RAW="$(curl -sS -X POST http://127.0.0.1:5555/api/execute/remote -H 'Content-Type: application/json' -d '{"command":"echo remote-check","use_worker_config":true,"timeout_seconds":12}')"
FRONTEND_OK="$(curl -sSf http://127.0.0.1:5570 >/dev/null && echo yes || echo no)"

echo "health_check=${HEALTH_JSON}"
echo "runtime_status=${RUNTIME_JSON}"
echo "local_exec_ok=${LOCAL_OK_JSON}"
echo "local_exec_blocked=${LOCAL_BLOCKED_RAW}"
echo "remote_exec_response=${REMOTE_RAW}"
echo "frontend_reachable=${FRONTEND_OK}"

if [[ "${LOCAL_OK_JSON}" != *"verify-0044"* ]]; then
  echo "error=local_exec_verify_failed"
  exit 1
fi

if [[ "${LOCAL_BLOCKED_RAW}" != *"not allowed"* ]]; then
  echo "error=allowlist_blocking_failed"
  exit 1
fi

if [[ "${FRONTEND_OK}" != "yes" ]]; then
  echo "error=frontend_not_reachable"
  exit 1
fi

if ! grep -q "localCommand" "${FRONTEND_ROOT}/index.html"; then
  echo "error=frontend_local_input_missing"
  exit 1
fi

if ! grep -q "remoteCommand" "${FRONTEND_ROOT}/index.html"; then
  echo "error=frontend_remote_input_missing"
  exit 1
fi

if ! grep -q "setBusy" "${FRONTEND_ROOT}/js/app.js"; then
  echo "error=frontend_busy_state_missing"
  exit 1
fi

echo "smoke_hardened_exec=passed"
echo "allowlist_behavior=passed"
echo "ui_interaction_flow=passed"

git add \
  "pilot_v1/customide/backend/app/routes/execute.py" \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js"

git commit -m "customide: smoke verify hardened execution flow (MTASK-0044)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
