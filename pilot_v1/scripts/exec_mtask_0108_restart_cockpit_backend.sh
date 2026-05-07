#!/usr/bin/env bash
set -uo pipefail
echo task=MTASK-0108
echo objective=restart_cockpit_backend_with_operator_loop
echo timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REPO_ROOT=/home/larieladmin/Documents/itheia-llm/MIDE
cd "$REPO_ROOT"

# Pull latest code
git pull origin main --no-rebase --quiet
echo git_pull=ok

# Find and restart the cockpit backend process
BACKEND_PID=$(pgrep -f "uvicorn.*app.main" 2>/dev/null | head -1 || echo "")
if [[ -n "$BACKEND_PID" ]]; then
  kill "$BACKEND_PID" 2>/dev/null || true
  sleep 2
  echo backend_old_pid_killed=$BACKEND_PID
fi

# Start backend detached
BACKEND_DIR="$REPO_ROOT/pilot_v1/customide/backend"
cd "$BACKEND_DIR"
if [[ -d ".venv" ]]; then
  PYTHON=".venv/bin/python"
else
  PYTHON="python3"
fi
nohup $PYTHON -m uvicorn app.main:app --host 0.0.0.0 --port 5555 > /tmp/customide_backend.log 2>&1 &
NEW_PID=$!
echo backend_new_pid=$NEW_PID
sleep 4

# Verify health
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5555/health 2>/dev/null || echo 000)
echo backend_health=$HTTP

# Verify operator-loop endpoint
LOOP=$(curl -s http://127.0.0.1:5555/api/status/operator-loop 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('alive=' + str(d.get('alive')))" 2>/dev/null || echo "alive=unknown")
echo operator_loop_endpoint=$LOOP

if [[ "$HTTP" == "200" ]]; then
  echo backend_health=UP
else
  echo backend_health=FAIL_HTTP_$HTTP
  exit 1
fi
echo snapshot=complete
