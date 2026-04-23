#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOMIDE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_ROOT="${CUSTOMIDE_ROOT}/backend"
FRONTEND_ROOT="${CUSTOMIDE_ROOT}/frontend"

PYTHON_BIN="${PYTHON_BIN:-python3}"
BACKEND_PORT="${BACKEND_PORT:-5555}"
FRONTEND_PORT="${FRONTEND_PORT:-5570}"

cd "${BACKEND_ROOT}"
if [[ ! -d .venv ]]; then
  "${PYTHON_BIN}" -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null

uvicorn app.main:app --host 127.0.0.1 --port "${BACKEND_PORT}" >/tmp/customide-backend.log 2>&1 &
BACK_PID=$!

cd "${FRONTEND_ROOT}"
"${PYTHON_BIN}" -m http.server "${FRONTEND_PORT}" >/tmp/customide-frontend.log 2>&1 &
FRONT_PID=$!

echo "backend_pid=${BACK_PID}"
echo "frontend_pid=${FRONT_PID}"
echo "backend_url=http://127.0.0.1:${BACKEND_PORT}"
echo "frontend_url=http://127.0.0.1:${FRONTEND_PORT}"
echo "Stop with: kill ${BACK_PID} ${FRONT_PID}"
