#!/usr/bin/env bash
# MTASK-0128 — Ensure /api/messenger supports localhost browser CORS for Ole Green polling
set -euo pipefail

REPO="/home/larieladmin/mide-pilot"
BACKEND="$REPO/pilot_v1/customide/backend"
VENV="$BACKEND/.venv"
RESULT_FILE="$REPO/pilot_v1/results/MTASK-0128.result.json"
TS_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[MTASK-0128] start $TS_START"
cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 || true
GIT_TERMINAL_PROMPT=0 timeout 60 git checkout origin/main -- pilot_v1/customide/backend/app/routes/messenger.py

RESTART_MODE="unknown"
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -Eq 'mide-backend|cockpit|backend'; then
  RESTART_MODE="docker"
  docker compose up -d --build mide-backend 2>/tmp/mtask0128_docker.log || docker restart mide-backend 2>/tmp/mtask0128_docker.log || true
else
  RESTART_MODE="uvicorn"
  pkill -f "uvicorn.*main:app" 2>/dev/null || true
  sleep 2
  cd "$BACKEND"
  nohup "$VENV/bin/uvicorn" app.main:app --host 0.0.0.0 --port 5555 >/tmp/cockpit_uvicorn.log 2>&1 &
fi

sleep 4
HEALTH=$(curl -sf --max-time 8 http://127.0.0.1:5555/health 2>&1 || echo "FAIL")

POST_OUT=$(curl -sf --max-time 8 -X POST http://127.0.0.1:5555/api/messenger \
  -H 'Content-Type: application/json' \
  -d '{"text":"MTASK-0128 CORS self-test","sender":"cockpit","type":"test"}' 2>&1 || echo "FAIL")

GET_OUT=$(curl -sf --max-time 8 'http://127.0.0.1:5555/api/messenger?limit=5' 2>&1 || echo "FAIL")

CORS_HEADERS=$(curl -s -i --max-time 8 'http://127.0.0.1:5555/api/messenger?limit=1' -H 'Origin: http://localhost:8080' | tr -d '\r')
if echo "$CORS_HEADERS" | grep -qi '^Access-Control-Allow-Origin: \*'; then
  CORS_STATUS="ok"
else
  CORS_STATUS="missing"
fi

if echo "$POST_OUT" | grep -q '"ok":true' && echo "$GET_OUT" | grep -q '"messages"' && [ "$CORS_STATUS" = "ok" ]; then
  FINAL_STATUS="MESSENGER_CORS_OK"
else
  FINAL_STATUS="MESSENGER_CORS_FAIL"
fi

TS_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$RESULT_FILE" << RESULT_EOF
{
  "task_id": "MTASK-0128",
  "completed_at": "$TS_END",
  "execution_status": "ok",
  "final_status": "$FINAL_STATUS",
  "restart_mode": "$RESTART_MODE",
  "health_check": "$HEALTH",
  "cors_status": "$CORS_STATUS",
  "post_out": $(echo "$POST_OUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))"),
  "get_out": $(echo "$GET_OUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
}
RESULT_EOF

echo "[MTASK-0128] done: $FINAL_STATUS"
