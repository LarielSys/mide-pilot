#!/usr/bin/env bash
# MTASK-0132 — Deploy mide-chat multi-user WebSocket chat service in Docker on Ubuntu
# All files are in git under pilot_v1/customide/mide-chat/
# docker-compose.yml already contains the mide-chat service definition.
set -euo pipefail

REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="$REPO/pilot_v1/customide"
RESULT_FILE="$REPO/pilot_v1/results/MTASK-0132.result.json"
TS_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[MTASK-0132] start $TS_START"

# Pull latest from git
cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git pull origin main 2>&1 | tail -5

# Verify mide-chat files exist
echo "[MTASK-0132] mide-chat dir:"
ls -la "$CUSTOMIDE/mide-chat/" 2>&1 || { echo "MISSING: mide-chat dir not found after git pull"; exit 1; }
ls -la "$CUSTOMIDE/mide-chat/static/" 2>&1 || { echo "MISSING: static dir not found"; exit 1; }

# Build and start
cd "$CUSTOMIDE"

echo "[MTASK-0132] Building mide-chat Docker image..."
docker compose build mide-chat 2>&1 | tail -10

echo "[MTASK-0132] Starting mide-chat container..."
docker compose up -d mide-chat

echo "[MTASK-0132] Waiting 8s for startup..."
sleep 8

HEALTH=$(curl -sf --max-time 10 http://127.0.0.1:7070/health 2>&1 || echo "FAIL")
echo "[MTASK-0132] Health: $HEALTH"

if echo "$HEALTH" | grep -q '"ok"'; then
    FINAL_STATUS="MIDE_CHAT_DEPLOYED_OK"
else
    FINAL_STATUS="MIDE_CHAT_HEALTH_FAIL"
    docker logs mide-chat --tail=20 2>&1 || true
fi

TS_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$(dirname "$RESULT_FILE")"
cat > "$RESULT_FILE" << RESULT_EOF
{
  "task_id": "MTASK-0132",
  "completed_at": "$TS_END",
  "execution_status": "completed",
  "summary": "$FINAL_STATUS",
  "health_response": $(echo "$HEALTH" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
}
RESULT_EOF

echo "[MTASK-0132] done: $FINAL_STATUS"
