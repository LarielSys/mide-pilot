#!/usr/bin/env bash
# MTASK-0117 — Verify token counter works after file was added to git
set -uo pipefail

TASK_ID="MTASK-0117"
REPO_ROOT="/home/larieladmin/mide-pilot"
VENV="$REPO_ROOT/pilot_v1/customide/backend/.venv"
PYTHON="$VENV/bin/python"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0117.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

cd "$REPO_ROOT"
git pull origin main 2>&1 | tail -3 | tee -a "$LOG"

# Confirm file is now available in git
FILE_STATUS=$(git show origin/main:pilot_v1/customide/TOKEN_COUNTER_TASKS.txt 2>&1 | head -2)
echo "file_in_git=$(echo "$FILE_STATUS" | head -1)" | tee -a "$LOG"

# Check if file has data rows
ROW_COUNT=$(git show origin/main:pilot_v1/customide/TOKEN_COUNTER_TASKS.txt 2>/dev/null | grep -c '^MTASK-' || echo 0)
echo "file_rows=$ROW_COUNT" | tee -a "$LOG"

# Kill existing backend instances on port 5555
echo "--- kill_port_5555 ---" | tee -a "$LOG"
PIDS=$(lsof -ti :5555 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        echo "killing pid=$pid" | tee -a "$LOG"
        kill -9 "$pid" 2>/dev/null || true
    done <<< "$PIDS"
    sleep 2
fi
echo "port_5555_after_kill=$(lsof -ti :5555 2>/dev/null | tr '\n' ',' || echo none)" | tee -a "$LOG"

# Verify venv
FASTAPI_VER=$("$PYTHON" -c "import fastapi; print(fastapi.__version__)" 2>/dev/null || echo MISSING)
echo "fastapi_version=$FASTAPI_VER" | tee -a "$LOG"
if [[ "$FASTAPI_VER" == "MISSING" ]]; then
    echo "final_status=VENV_BROKEN_FASTAPI_MISSING" | tee -a "$LOG"
    exit 1
fi

# Start backend
echo "--- start_backend ---" | tee -a "$LOG"
cd "$REPO_ROOT/pilot_v1/customide"
nohup "$PYTHON" -m uvicorn backend.app.main:app --host 0.0.0.0 --port 5555 > "$REPO_ROOT/pilot_v1/state/cockpit_backend.log" 2>&1 &
NEW_PID=$!
echo "new_pid=$NEW_PID" | tee -a "$LOG"

# Wait for ready
echo "--- wait_ready ---" | tee -a "$LOG"
for i in 1 2 3 4 5 6 7 8; do
    sleep 3
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5555/api/status/runtime 2>/dev/null || echo 000)
    echo "attempt=$i http=$HTTP" | tee -a "$LOG"
    [[ "$HTTP" == "200" ]] && break
done

if [[ "$HTTP" != "200" ]]; then
    echo "backend_start=FAIL_HTTP_$HTTP" | tee -a "$LOG"
    echo "final_status=BACKEND_START_FAILED" | tee -a "$LOG"
    exit 1
fi
echo "backend_start=OK" | tee -a "$LOG"

# Wait for git fetch TTL (30s) so backend picks up latest origin
echo "waiting_for_fetch_ttl=30s" | tee -a "$LOG"
sleep 31

# Query token counters
echo "--- verify_token_counters ---" | tee -a "$LOG"
RESP=$(curl -s http://127.0.0.1:5555/api/status/token-counters 2>/dev/null || echo '{}')
echo "token_counters_response=$RESP" | tee -a "$LOG"

ROWS=$(echo "$RESP" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); print(d.get('summary',{}).get('tasks_tracked',0))" 2>/dev/null || echo 0)
SOURCE=$(echo "$RESP" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); print(d.get('source','unknown'))" 2>/dev/null || echo unknown)
echo "rows_count=$ROWS" | tee -a "$LOG"
echo "source=$SOURCE" | tee -a "$LOG"

if [[ "$ROWS" -gt 0 ]]; then
    echo "token_counter_fixed=yes" | tee -a "$LOG"
    echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
else
    echo "token_counter_fixed=no" | tee -a "$LOG"
    echo "final_status=TOKEN_COUNTER_STILL_EMPTY" | tee -a "$LOG"
    exit 1
fi
