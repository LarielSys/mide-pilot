#!/usr/bin/env bash
set -uo pipefail
TASK_ID="MTASK-0119"
REPO_ROOT="/home/larieladmin/mide-pilot"
VENV="$REPO_ROOT/pilot_v1/customide/backend/.venv"
PYTHON="$VENV/bin/python"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0119.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

cd "$REPO_ROOT"
git pull origin main 2>&1 | tail -3 | tee -a "$LOG"

# Verify new endpoint is present
ENDPOINT_CHECK=$(grep -c "task-history" "$REPO_ROOT/pilot_v1/customide/backend/app/routes/runtime.py" 2>/dev/null || echo 0)
echo "task_history_endpoint_lines=$ENDPOINT_CHECK" | tee -a "$LOG"

# Kill existing on 5555
echo "--- kill_port_5555 ---" | tee -a "$LOG"
lsof -ti :5555 2>/dev/null | while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    echo "killing pid=$pid" | tee -a "$LOG"
    kill -9 "$pid" 2>/dev/null || true
done
sleep 2

# Start backend
echo "--- start_backend ---" | tee -a "$LOG"
cd "$REPO_ROOT/pilot_v1/customide"
nohup "$PYTHON" -m uvicorn backend.app.main:app --host 0.0.0.0 --port 5555 > "$REPO_ROOT/pilot_v1/state/cockpit_backend.log" 2>&1 &
echo "new_pid=$!" | tee -a "$LOG"

# Wait ready
for i in 1 2 3 4 5 6 7 8; do
    sleep 3
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5555/api/status/runtime 2>/dev/null || echo 000)
    echo "attempt=$i http=$HTTP" | tee -a "$LOG"
    [[ "$HTTP" == "200" ]] && break
done
[[ "$HTTP" != "200" ]] && { echo "final_status=BACKEND_START_FAILED"; exit 1; }
echo "backend_start=OK" | tee -a "$LOG"

# Verify task-history endpoint
HIST=$(curl -s http://127.0.0.1:5555/api/status/task-history 2>/dev/null || echo '{}')
COUNT=$(echo "$HIST" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo 0)
echo "task_history_count=$COUNT" | tee -a "$LOG"

if [[ "$COUNT" -gt 0 ]]; then
    echo "snapshot=complete"
    echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
else
    echo "final_status=TASK_HISTORY_EMPTY" | tee -a "$LOG"
    exit 1
fi
