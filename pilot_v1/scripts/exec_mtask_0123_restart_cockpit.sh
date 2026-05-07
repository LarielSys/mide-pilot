#!/usr/bin/env bash
set -uo pipefail

COCKPIT_REPO="/home/larieladmin/mide-pilot"
COCKPIT_VENV="${COCKPIT_REPO}/pilot_v1/customide/backend/.venv"
COCKPIT_APP="${COCKPIT_REPO}/pilot_v1/customide/backend/app/main.py"
COCKPIT_PORT=5555
NGROK_SKIP_HEADER="ngrok-skip-browser-warning: true"

echo "task=MTASK-0123"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Step 1: Pull latest into cockpit backend repo
echo "step=git_pull"
GIT_TERMINAL_PROMPT=0 timeout 60 git -C "${COCKPIT_REPO}" pull --ff-only origin main
echo "git_pull_status=$?"

# Step 2: Kill any running uvicorn on port 5555
echo "step=kill_old_backend"
pkill -f "uvicorn.*main:app" 2>/dev/null || true
sleep 2

# Step 3: Start backend detached
echo "step=start_backend"
cd "${COCKPIT_REPO}/pilot_v1/customide/backend"
nohup "${COCKPIT_VENV}/bin/uvicorn" app.main:app --host 0.0.0.0 --port ${COCKPIT_PORT} \
  > /home/larieladmin/mide-pilot/pilot_v1/state/cockpit_backend.log 2>&1 &
BACKEND_PID=$!
echo "backend_pid=${BACKEND_PID}"
sleep 4

# Step 4: Verify
echo "step=verify"
TASK_HISTORY=$(curl -s -H "${NGROK_SKIP_HEADER}" "http://localhost:${COCKPIT_PORT}/api/status/task-history" 2>/dev/null || echo "")
COUNT=$(echo "${TASK_HISTORY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
echo "task_history_count=${COUNT}"

if [ "${COUNT}" -gt 0 ] 2>/dev/null; then
  echo "final_status=ALL_CHECKS_PASSED"
else
  echo "final_status=TASK_HISTORY_EMPTY"
fi
