#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

BACKEND_ROOT="${REPO_ROOT}/pilot_v1/customide/backend"
FRONTEND_ROOT="${REPO_ROOT}/pilot_v1/customide/frontend"
BACKEND_VENV="${BACKEND_ROOT}/.venv"
BACKEND_PORT="5555"
FRONTEND_PORT="5570"

BACKEND_PID=""
FRONTEND_PID=""

cleanup() {
  if [[ -n "${BACKEND_PID}" ]] && kill -0 "${BACKEND_PID}" 2>/dev/null; then
    kill "${BACKEND_PID}" 2>/dev/null || true
  fi
  if [[ -n "${FRONTEND_PID}" ]] && kill -0 "${FRONTEND_PID}" 2>/dev/null; then
    kill "${FRONTEND_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "${REPO_ROOT}"

echo "task=MTASK-0040"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${BACKEND_ROOT}/app/main.py" ]]; then
  echo "error=backend_main_missing"
  exit 1
fi
if [[ ! -f "${FRONTEND_ROOT}/index.html" ]]; then
  echo "error=frontend_index_missing"
  exit 1
fi

python3 -m venv "${BACKEND_VENV}"
# shellcheck disable=SC1091
source "${BACKEND_VENV}/bin/activate"
pip install --upgrade pip >/dev/null
pip install -r "${BACKEND_ROOT}/requirements.txt" >/dev/null

nohup uvicorn app.main:app --host 127.0.0.1 --port "${BACKEND_PORT}" --app-dir "${BACKEND_ROOT}" >/tmp/customide_backend_5555.log 2>&1 &
BACKEND_PID=$!

nohup python3 -m http.server "${FRONTEND_PORT}" --directory "${FRONTEND_ROOT}" >/tmp/customide_frontend_5570.log 2>&1 &
FRONTEND_PID=$!

backend_ok="false"
for _ in $(seq 1 30); do
  if curl -sS "http://127.0.0.1:${BACKEND_PORT}/health" >/tmp/mtask_0040_backend_health.json 2>/dev/null; then
    backend_ok="true"
    break
  fi
  sleep 1
done

frontend_ok="false"
for _ in $(seq 1 30); do
  if curl -sS "http://127.0.0.1:${FRONTEND_PORT}/" >/tmp/mtask_0040_frontend_root.html 2>/dev/null; then
    frontend_ok="true"
    break
  fi
  sleep 1
done

if [[ "${backend_ok}" != "true" ]]; then
  echo "error=backend_health_unreachable"
  echo "backend_log_tail=$(tail -n 60 /tmp/customide_backend_5555.log | tr '\n' ';')"
  exit 1
fi
if [[ "${frontend_ok}" != "true" ]]; then
  echo "error=frontend_unreachable"
  echo "frontend_log_tail=$(tail -n 60 /tmp/customide_frontend_5570.log | tr '\n' ';')"
  exit 1
fi

backend_health="$(cat /tmp/mtask_0040_backend_health.json)"
config_json="$(curl -sS "http://127.0.0.1:${BACKEND_PORT}/api/config/services")"
ollama_code="$(curl -sS -o /tmp/mtask_0040_ollama_health.json -w "%{http_code}" "http://127.0.0.1:${BACKEND_PORT}/api/ollama/health" || true)"
frontend_title_hit="$(grep -c "CustomIDE" /tmp/mtask_0040_frontend_root.html || true)"

echo "check_backend_health=pass"
echo "check_frontend_http=pass"
echo "check_frontend_title_hit=${frontend_title_hit}"
echo "check_config_endpoint_json_len=${#config_json}"
echo "check_ollama_health_http_code=${ollama_code}"
echo "backend_health=${backend_health}"
echo "smoke_verify=completed"

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
