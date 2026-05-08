#!/usr/bin/env bash
# MTASK-2010 — Serve CustomIDE cockpit frontend on port 8095 (replaces funhost/olegreen)
# Serves pilot_v1/customide/frontend/ — the same UI as localhost:8091
set -uo pipefail

TASK_ID="MTASK-2010"
REPO_ROOT="/home/larieladmin/mide-pilot"
SERVE_DIR="${REPO_ROOT}/pilot_v1/customide/frontend"
PORT=8095
LOG_FILE="/tmp/funhost_8095.log"
PID_FILE="/tmp/funhost_8095.pid"

echo "[${TASK_ID}] Starting CustomIDE cockpit deploy on port ${PORT}..."
echo "[${TASK_ID}] serve_dir=${SERVE_DIR}"

# Sync to latest
cd "${REPO_ROOT}"
git fetch origin main 2>&1 | tail -2
git reset --hard origin/main 2>&1 | tail -2
echo "[${TASK_ID}] git_sync_done"

# Verify frontend directory exists
if [[ ! -d "${SERVE_DIR}" ]]; then
  echo "[${TASK_ID}] ERROR: frontend directory not found at ${SERVE_DIR}"
  echo "[${TASK_ID}] final_status=FAILED_DIR_MISSING"
  exit 1
fi

echo "[${TASK_ID}] frontend_files=$(ls ${SERVE_DIR} | tr '\n' ' ')"

# Kill any existing process on port 8095
OLD_PID=$(lsof -ti tcp:${PORT} 2>/dev/null || true)
if [[ -n "${OLD_PID}" ]]; then
  echo "[${TASK_ID}] killing_old_pid=${OLD_PID}"
  kill "${OLD_PID}" 2>/dev/null || true
  sleep 1
fi

# Start Python HTTP server
cd "${SERVE_DIR}"
nohup python3 -m http.server ${PORT} --bind 0.0.0.0 > "${LOG_FILE}" 2>&1 &
NEW_PID=$!
echo "${NEW_PID}" > "${PID_FILE}"
echo "[${TASK_ID}] customide_host_pid=${NEW_PID}"

sleep 3

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" 2>/dev/null || echo "unreachable")
echo "[${TASK_ID}] customide_http_status=${HTTP_STATUS}"
echo "[${TASK_ID}] customide_url=http://$(hostname -I | awk '{print $1}'):${PORT}/"

if [[ "${HTTP_STATUS}" == "200" ]]; then
  echo "[${TASK_ID}] final_status=CUSTOMIDE_LIVE"
  echo "[${TASK_ID}] message=CustomIDE cockpit now serving on port ${PORT}"
else
  echo "[${TASK_ID}] server_log=$(tail -5 ${LOG_FILE} 2>/dev/null || echo 'no log')"
  echo "[${TASK_ID}] final_status=FAILED"
fi

echo "[${TASK_ID}] Done."
exit 0
