#!/usr/bin/env bash
# MTASK-0127 — Patch messenger.py with in-memory store and restart cockpit backend
set -euo pipefail

REPO="/home/larieladmin/mide-pilot"
BACKEND="$REPO/pilot_v1/customide/backend"
VENV="$BACKEND/.venv"
RESULT_FILE="$REPO/pilot_v1/results/MTASK-0127.result.json"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[MTASK-0127] Starting messenger.py patch — $TS"

# Pull latest origin to get updated messenger.py
cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 || true
GIT_TERMINAL_PROMPT=0 timeout 60 git checkout origin/main -- pilot_v1/customide/backend/app/routes/messenger.py

echo "[MTASK-0127] messenger.py checked out from origin/main"

# Verify it has the in-memory store (no relay proxy)
if grep -q "_messages" "$BACKEND/app/routes/messenger.py"; then
  PATCH_STATUS="ok"
  echo "[MTASK-0127] In-memory store confirmed in messenger.py"
else
  PATCH_STATUS="warning: _messages not found — file may be wrong version"
  echo "[MTASK-0127] WARNING: expected content not found"
fi

# Restart uvicorn
echo "[MTASK-0127] Restarting cockpit backend..."
pkill -f "uvicorn.*main:app" 2>/dev/null || true
sleep 2
cd "$BACKEND"
nohup "$VENV/bin/uvicorn" app.main:app --host 0.0.0.0 --port 5555 \
  > /tmp/cockpit_uvicorn.log 2>&1 &
UVICORN_PID=$!
sleep 4

# Verify health
HEALTH=$(curl -sf --max-time 8 http://127.0.0.1:5555/health 2>&1 || echo "FAIL")
echo "[MTASK-0127] Health check: $HEALTH"

# Test messenger endpoint
MESSENGER_TEST=$(curl -sf --max-time 8 -X POST http://127.0.0.1:5555/api/messenger \
  -H 'Content-Type: application/json' \
  -d '{"text":"MTASK-0127 self-test","sender":"worker","type":"test"}' 2>&1 || echo "FAIL")
echo "[MTASK-0127] Messenger test: $MESSENGER_TEST"

if echo "$MESSENGER_TEST" | grep -q '"ok":true'; then
  FINAL_STATUS="MESSENGER_OK"
else
  FINAL_STATUS="MESSENGER_FAIL"
fi

TS_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$RESULT_FILE" << RESULT_EOF
{
  "task_id": "MTASK-0127",
  "completed_at": "$TS_END",
  "execution_status": "ok",
  "final_status": "$FINAL_STATUS",
  "patch_status": "$PATCH_STATUS",
  "uvicorn_pid": $UVICORN_PID,
  "health_check": "$HEALTH",
  "messenger_test": $(echo "$MESSENGER_TEST" | python3 -c "import sys,json; s=sys.stdin.read().strip(); print(json.dumps(s))")
}
RESULT_EOF

echo "[MTASK-0127] Done — $FINAL_STATUS"
