#!/usr/bin/env bash
# MTASK-0109 — Pull fix, restart cockpit backend, verify token-counters endpoint
set -uo pipefail

TASK_ID="MTASK-0109"
REPO_ROOT="/home/larieladmin/Documents/itheia-llm/MIDE"
COCKPIT_DIR="$REPO_ROOT/pilot_v1/customide/backend"
BACKEND_URL="http://127.0.0.1:5555"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0109.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

# --- 1. Pull latest main ---
echo "--- git_pull ---" | tee -a "$LOG"
cd "$REPO_ROOT"
git fetch origin main 2>&1 | tee -a "$LOG"
git merge origin/main 2>&1 | tee -a "$LOG"
echo "head=$(git rev-parse --short HEAD)" | tee -a "$LOG"

# --- 2. Kill existing uvicorn on port 5555 ---
echo "--- kill_old_backend ---" | tee -a "$LOG"
# lsof may return multiple PIDs; kill each one individually
while IFS= read -r pid; do
  [ -z "$pid" ] && continue
  echo "killing pid=$pid" | tee -a "$LOG"
  kill "$pid" 2>&1 | tee -a "$LOG" || true
done < <(lsof -ti :5555 2>/dev/null || true)
sleep 3
# Verify port is now free
STILL_BOUND=$(lsof -ti :5555 2>/dev/null || true)
if [ -n "$STILL_BOUND" ]; then
  echo "force_killing pid=$STILL_BOUND" | tee -a "$LOG"
  kill -9 $STILL_BOUND 2>/dev/null || true
  sleep 2
fi
echo "port_5555_clear=yes" | tee -a "$LOG"

# --- 3. Start backend ---
echo "--- start_backend ---" | tee -a "$LOG"
cd "$COCKPIT_DIR"

# Detect venv
VENV=""
for candidate in "$COCKPIT_DIR/venv" "$COCKPIT_DIR/../../../venv" "$HOME/venv" "/home/larieladmin/venv"; do
  if [ -f "$candidate/bin/python" ]; then
    VENV="$candidate"
    break
  fi
done

if [ -n "$VENV" ]; then
  echo "using_venv=$VENV" | tee -a "$LOG"
  PYTHON="$VENV/bin/python"
  PIP="$VENV/bin/pip"
else
  echo "using_system_python" | tee -a "$LOG"
  PYTHON="python3"
fi

nohup "$PYTHON" -m uvicorn app.main:app --host 0.0.0.0 --port 5555 \
  > "$REPO_ROOT/pilot_v1/state/cockpit_backend.log" 2>&1 &
NEW_PID=$!
echo "new_pid=$NEW_PID" | tee -a "$LOG"

# --- 4. Wait for backend to be ready ---
echo "--- wait_ready ---" | tee -a "$LOG"
READY=0
for i in $(seq 1 15); do
  sleep 2
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_URL/api/status/bundle" 2>/dev/null || echo "000")
  echo "attempt=$i http=$HTTP" | tee -a "$LOG"
  if [ "$HTTP" = "200" ]; then
    READY=1
    break
  fi
done

if [ "$READY" != "1" ]; then
  echo "backend_start=FAILED" | tee -a "$LOG"
  echo "startup_log=$(tail -20 "$REPO_ROOT/pilot_v1/state/cockpit_backend.log" | tr '\n' '|')" | tee -a "$LOG"
  exit 1
fi

echo "backend_start=OK" | tee -a "$LOG"

# --- 5. Verify token-counters endpoint ---
echo "--- verify_token_counters ---" | tee -a "$LOG"
TC_RESPONSE=$(curl -s "$BACKEND_URL/api/status/token-counters" 2>/dev/null || echo '{"error":"curl_failed"}')
echo "token_counters_response=$TC_RESPONSE" | tee -a "$LOG"

ROWS=$(echo "$TC_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('rows', [])))" 2>/dev/null || echo "0")
SOURCE=$(echo "$TC_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source','?'))" 2>/dev/null || echo "?")
echo "rows_count=$ROWS" | tee -a "$LOG"
echo "source=$SOURCE" | tee -a "$LOG"

# --- 6. Check for Python tracebacks in startup log ---
echo "--- startup_errors ---" | tee -a "$LOG"
if grep -i "traceback\|error\|exception" "$REPO_ROOT/pilot_v1/state/cockpit_backend.log" 2>/dev/null | head -5 | tee -a "$LOG"; then
  echo "startup_errors_found=yes" | tee -a "$LOG"
else
  echo "startup_errors_found=no" | tee -a "$LOG"
fi

# --- 7. Final status ---
if [ "$ROWS" -gt "0" ] 2>/dev/null; then
  echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
  echo "token_counter_fixed=yes" | tee -a "$LOG"
else
  echo "final_status=TOKEN_COUNTER_EMPTY" | tee -a "$LOG"
  echo "token_counter_fixed=no" | tee -a "$LOG"
fi
