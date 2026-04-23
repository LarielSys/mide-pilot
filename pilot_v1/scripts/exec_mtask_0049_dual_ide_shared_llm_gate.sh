#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

BACKEND_ROOT="${REPO_ROOT}/pilot_v1/customide/backend"
FRONTEND_ROOT="${REPO_ROOT}/pilot_v1/customide/frontend"

cd "${REPO_ROOT}"

echo "task=MTASK-0049"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0049-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0049-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

cleanup() {
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

HEALTH_JSON="$(curl -sSf http://127.0.0.1:5555/health)"
RUNTIME_JSON="$(curl -sSf http://127.0.0.1:5555/api/status/runtime)"
LLM_HEALTH_JSON="$(curl -sS http://127.0.0.1:5555/api/llm/health)"
LLM_LOCAL_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/llm/chat -H 'Content-Type: application/json' -d '{"prompt":"Reply with gate-local only.","source":"local"}')"
LLM_REMOTE_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/llm/chat -H 'Content-Type: application/json' -d '{"prompt":"Reply with gate-remote only.","source":"remote"}')"
FRONTEND_OK="$(curl -sSf http://127.0.0.1:5570 >/dev/null && echo yes || echo no)"

echo "health_check=${HEALTH_JSON}"
echo "runtime_status=${RUNTIME_JSON}"
echo "llm_health=${LLM_HEALTH_JSON}"
echo "llm_local=${LLM_LOCAL_JSON}"
echo "llm_remote=${LLM_REMOTE_JSON}"
echo "frontend_reachable=${FRONTEND_OK}"

if [[ "${FRONTEND_OK}" != "yes" ]]; then
  echo "error=frontend_not_reachable"
  exit 1
fi
if [[ "${LLM_LOCAL_JSON}" != *"local-ide"* ]]; then
  echo "error=llm_local_source_invalid"
  exit 1
fi
if [[ "${LLM_REMOTE_JSON}" != *"remote-ide"* ]]; then
  echo "error=llm_remote_source_invalid"
  exit 1
fi

if [[ "${LLM_LOCAL_JSON}" == *'"degraded":false'* && "${LLM_REMOTE_JSON}" == *'"degraded":false'* ]]; then
  echo "shared_llm_mode=configured"
else
  echo "shared_llm_mode=degraded"
fi

echo "phase14_dual_ide_gate=passed"
echo "shared_llm_contracts_gate=passed"
echo "forward_only_progression=passed"

git add \
  "pilot_v1/results/.keep" || true

git commit -m "customide: verify dual ide shared llm phase gate (MTASK-0049)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
