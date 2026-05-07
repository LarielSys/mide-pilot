#!/usr/bin/env bash
# MTASK-0115 — Fix cockpit backend: use /home/larieladmin/mide-pilot (correct repo) + .venv
set -uo pipefail

TASK_ID="MTASK-0115"
CORRECT_REPO="/home/larieladmin/mide-pilot"
COCKPIT_DIR="$CORRECT_REPO/pilot_v1/customide/backend"
VENV="$COCKPIT_DIR/.venv"
PYTHON="$VENV/bin/python"
BACKEND_URL="http://127.0.0.1:5555"
LOG="$CORRECT_REPO/pilot_v1/state/mtask_0115.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"
echo "correct_repo=$CORRECT_REPO" | tee -a "$LOG"
echo "venv=$VENV" | tee -a "$LOG"

# --- 1. Pull latest into correct repo ---
echo "--- git_pull ---" | tee -a "$LOG"
cd "$CORRECT_REPO"
git fetch origin main 2>&1 | tee -a "$LOG"
git merge origin/main --no-edit 2>&1 | tee -a "$LOG"
echo "head=$(git rev-parse --short HEAD)" | tee -a "$LOG"

# Verify _repo_root fix is present
grep -c "git.*exists" "$COCKPIT_DIR/app/routes/runtime.py" 2>/dev/null | tee -a "$LOG" && echo "_repo_root_fix=present" | tee -a "$LOG" || echo "_repo_root_fix=not_found" | tee -a "$LOG"

# --- 2. Verify venv has fastapi ---
echo "--- venv_check ---" | tee -a "$LOG"
FASTAPI_VER=$("$PYTHON" -c "import fastapi; print(fastapi.__version__)" 2>/dev/null || echo "NOT_INSTALLED")
echo "fastapi_version=$FASTAPI_VER" | tee -a "$LOG"
if [ "$FASTAPI_VER" = "NOT_INSTALLED" ]; then
  echo "ERROR: fastapi not in venv" | tee -a "$LOG"
  exit 1
fi

# --- 3. Kill all processes on port 5555 ---
echo "--- kill_port_5555 ---" | tee -a "$LOG"
while IFS= read -r pid; do
  [ -z "$pid" ] && continue
  echo "killing pid=$pid" | tee -a "$LOG"
  kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
done < <(lsof -ti :5555 2>/dev/null || true)
sleep 3

# Force kill any survivors
while IFS= read -r pid; do
  [ -z "$pid" ] && continue
  echo "force_killing pid=$pid" | tee -a "$LOG"
  kill -9 "$pid" 2>/dev/null || true
done < <(lsof -ti :5555 2>/dev/null || true)
sleep 2

STILL_BOUND=$(lsof -ti :5555 2>/dev/null | tr '\n' ',' || echo "")
echo "port_5555_after_kill=$STILL_BOUND" | tee -a "$LOG"

# --- 4. Start backend from correct repo + venv ---
echo "--- start_backend ---" | tee -a "$LOG"
cd "$COCKPIT_DIR"
nohup "$PYTHON" -m uvicorn app.main:app --host 0.0.0.0 --port 5555 \
  > "$CORRECT_REPO/pilot_v1/state/cockpit_backend.log" 2>&1 &
NEW_PID=$!
echo "new_pid=$NEW_PID" | tee -a "$LOG"

# --- 5. Wait for backend ready ---
echo "--- wait_ready ---" | tee -a "$LOG"
READY=0
for i in $(seq 1 20); do
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
  echo "startup_tail=$(tail -20 "$CORRECT_REPO/pilot_v1/state/cockpit_backend.log" | tr '\n' '|')" | tee -a "$LOG"
  exit 1
fi
echo "backend_start=OK" | tee -a "$LOG"

# --- 6. Verify token counters ---
echo "--- verify_token_counters ---" | tee -a "$LOG"
TC=$(curl -s "$BACKEND_URL/api/status/token-counters" 2>/dev/null || echo '{"error":"curl_failed"}')
echo "token_counters_response=$TC" | tee -a "$LOG"

ROWS=$(echo "$TC" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('rows', [])))" 2>/dev/null || echo "0")
SOURCE=$(echo "$TC" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(d.get('source','?'))" 2>/dev/null || echo "?")
SOURCE_FILE=$(echo "$TC" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(d.get('source_file','?'))" 2>/dev/null || echo "?")
echo "rows_count=$ROWS" | tee -a "$LOG"
echo "source=$SOURCE" | tee -a "$LOG"
echo "source_file=$SOURCE_FILE" | tee -a "$LOG"

if [ "$ROWS" -gt "0" ] 2>/dev/null; then
  echo "token_counter_fixed=yes" | tee -a "$LOG"
  echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
else
  echo "token_counter_fixed=no" | tee -a "$LOG"
  # Show startup errors
  grep -i "traceback\|error\|exception" "$CORRECT_REPO/pilot_v1/state/cockpit_backend.log" 2>/dev/null | head -10 | tee -a "$LOG" || true
  echo "final_status=TOKEN_COUNTER_EMPTY" | tee -a "$LOG"
fi
