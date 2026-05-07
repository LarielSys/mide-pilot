#!/usr/bin/env bash
set -uo pipefail

COCKPIT_REPO="/home/larieladmin/mide-pilot"
COCKPIT_VENV="${COCKPIT_REPO}/pilot_v1/customide/backend/.venv"
COCKPIT_PORT=5555

echo "task=MTASK-0124"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Step 1: Force-sync cockpit repo to origin/main
echo "step=git_fetch"
GIT_TERMINAL_PROMPT=0 timeout 60 git -C "${COCKPIT_REPO}" fetch origin main
echo "fetch_status=$?"

# Only sync the backend code file we need — don't touch anything else
echo "step=checkout_runtime_py"
git -C "${COCKPIT_REPO}" checkout origin/main -- \
  pilot_v1/customide/backend/app/routes/runtime.py
echo "checkout_status=$?"

# Verify the fix is present (git archive + tarfile import)
echo "step=verify_code"
grep -c "git archive" "${COCKPIT_REPO}/pilot_v1/customide/backend/app/routes/runtime.py" && echo "git_archive_present=yes" || echo "git_archive_present=no"

# Step 2: Kill old backend and restart
echo "step=restart_backend"
pkill -f "uvicorn.*main:app" 2>/dev/null || true
sleep 2
cd "${COCKPIT_REPO}/pilot_v1/customide/backend"
nohup "${COCKPIT_VENV}/bin/uvicorn" app.main:app --host 0.0.0.0 --port ${COCKPIT_PORT} \
  > "${COCKPIT_REPO}/pilot_v1/state/cockpit_backend.log" 2>&1 &
echo "backend_pid=$!"
sleep 4

# Step 3: Verify task-history count
echo "step=verify"
COUNT=$(curl -s "http://localhost:${COCKPIT_PORT}/api/status/task-history" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
echo "task_history_count=${COUNT}"

if [ "${COUNT:-0}" -gt 5 ] 2>/dev/null; then
  echo "final_status=ALL_CHECKS_PASSED"
else
  echo "final_status=LOW_COUNT_count=${COUNT}"
fi
