#!/usr/bin/env bash
# MTASK-0131 — Force live cockpit backend to load messenger.py with /read endpoint
set -euo pipefail

REPO="/home/larieladmin/mide-pilot"
RESULT_FILE="$REPO/pilot_v1/results/MTASK-0131.result.json"
TS_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[MTASK-0131] start $TS_START"
cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 || true
GIT_TERMINAL_PROMPT=0 timeout 60 git checkout origin/main -- pilot_v1/customide/backend/app/routes/messenger.py

SOURCE_FILE="$REPO/pilot_v1/customide/backend/app/routes/messenger.py"
PATCH_MODE="host-restart"
CONTAINER_NAME=""
READ_STATUS="unknown"

if command -v docker >/dev/null 2>&1; then
  CANDIDATES=$(docker ps --format '{{.Names}}' | grep -Ei 'mide-backend|backend|cockpit|customide' || true)
  if [ -n "$CANDIDATES" ]; then
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      TARGET_PATH=$(docker exec "$c" sh -lc 'python - <<PY
import importlib.util
spec = importlib.util.find_spec("app.routes.messenger")
print(spec.origin if spec and spec.origin else "")
PY' 2>/dev/null | tr -d '\r' | tail -n 1)
      if [ -n "$TARGET_PATH" ]; then
        docker cp "$SOURCE_FILE" "$c:$TARGET_PATH"
        docker restart "$c" >/dev/null
        CONTAINER_NAME="$c"
        PATCH_MODE="docker-copy-restart"
        break
      fi
    done <<< "$CANDIDATES"
  fi
fi

if [ "$PATCH_MODE" = "host-restart" ]; then
  BACKEND="$REPO/pilot_v1/customide/backend"
  VENV="$BACKEND/.venv"
  pkill -f "uvicorn.*main:app" 2>/dev/null || true
  sleep 2
  cd "$BACKEND"
  nohup "$VENV/bin/uvicorn" app.main:app --host 0.0.0.0 --port 5555 >/tmp/cockpit_uvicorn.log 2>&1 &
fi

sleep 4
HEALTH=$(curl -sf --max-time 8 http://127.0.0.1:5555/health 2>&1 || echo "FAIL")
READ_RAW=$(curl -s -o /tmp/mtask0131_read.out -w "%{http_code}" -X POST http://127.0.0.1:5555/api/messenger/read -H 'Content-Type: application/json' -d '{"limit":3}' || echo "000")
READ_BODY=$(cat /tmp/mtask0131_read.out 2>/dev/null || true)

if [ "$READ_RAW" = "200" ]; then
  READ_STATUS="ok"
else
  READ_STATUS="http_$READ_RAW"
fi

if [ "$READ_STATUS" = "ok" ] && echo "$READ_BODY" | grep -q '"messages"'; then
  FINAL_STATUS="LIVE_READ_OK"
else
  FINAL_STATUS="LIVE_READ_FAIL"
fi

TS_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$RESULT_FILE" << RESULT_EOF
{
  "task_id": "MTASK-0131",
  "completed_at": "$TS_END",
  "execution_status": "ok",
  "final_status": "$FINAL_STATUS",
  "patch_mode": "$PATCH_MODE",
  "container_name": "$CONTAINER_NAME",
  "health_check": "$HEALTH",
  "read_status": "$READ_STATUS",
  "read_body": $(echo "$READ_BODY" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
}
RESULT_EOF

echo "[MTASK-0131] done: $FINAL_STATUS ($PATCH_MODE)"
