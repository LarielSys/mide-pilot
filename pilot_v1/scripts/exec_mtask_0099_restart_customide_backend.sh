#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-0099"
echo "objective=restart_customide_backend"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

BACKEND_PORT=5555
REPO_ROOT="/home/larieladmin/mide-pilot"

# Current status
CURRENT=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${BACKEND_PORT}/health 2>/dev/null || echo "000")
echo "current_port${BACKEND_PORT}=${CURRENT}"

if [[ "$CURRENT" == "200" || "$CURRENT" == "404" ]]; then
  echo "backend_status=ALREADY_UP"
  echo "snapshot=complete"
  exit 0
fi

# Kill any stale process on 5555
STALE_PID=$(lsof -ti tcp:${BACKEND_PORT} 2>/dev/null | head -1 || echo "")
if [[ -n "$STALE_PID" ]]; then
  kill -9 "$STALE_PID" 2>/dev/null || true
  echo "killed_stale_pid=${STALE_PID}"
fi
sleep 2

# Locate backend entrypoint
CANDIDATES=(
  "${REPO_ROOT}/pilot_v1/customide/backend/app/main.py"
  "${REPO_ROOT}/pilot_v1/customide/backend/main.py"
  "${REPO_ROOT}/customide/backend/app/main.py"
)
BACKEND_MAIN=""
for p in "${CANDIDATES[@]}"; do
  if [[ -f "$p" ]]; then
    BACKEND_MAIN="$p"
    break
  fi
done

# Fallback search
if [[ -z "$BACKEND_MAIN" ]]; then
  BACKEND_MAIN=$(grep -rl "5555\|uvicorn\|FastAPI" "$REPO_ROOT" --include="*.py" 2>/dev/null | grep -v "__pycache__" | head -1 || echo "")
fi

echo "backend_entrypoint=${BACKEND_MAIN:-NOT_FOUND}"

if [[ -z "$BACKEND_MAIN" ]]; then
  echo "backend_status=NO_ENTRYPOINT_FOUND"
  echo "snapshot=complete"
  exit 0
fi

# Start backend
cd "$(dirname "$BACKEND_MAIN")"
nohup python3 -m uvicorn app.main:app --host 0.0.0.0 --port ${BACKEND_PORT} > /tmp/customide_backend_MTASK-0099.log 2>&1 &
echo "backend_started_pid=$!"
sleep 6

NEW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${BACKEND_PORT}/health 2>/dev/null || echo "000")
echo "port${BACKEND_PORT}_after_start=${NEW_STATUS}"

if [[ "$NEW_STATUS" == "200" || "$NEW_STATUS" == "404" ]]; then
  echo "backend_status=UP"
else
  echo "backend_status=FAIL_HTTP_${NEW_STATUS}"
  echo "log_tail=$(tail -15 /tmp/customide_backend_MTASK-0099.log 2>/dev/null || echo none)"
fi

echo "snapshot=complete"
