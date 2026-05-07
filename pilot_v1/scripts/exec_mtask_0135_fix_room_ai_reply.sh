#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-0135"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="$REPO/pilot_v1/customide"
RESULT_FILE="$REPO/pilot_v1/results/${TASK_ID}.result.json"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 | tail -5
git reset --hard origin/main
echo "[${TASK_ID}] repo synced: $(git rev-parse --short HEAD)"

cd "$CUSTOMIDE"
echo "[${TASK_ID}] rebuilding mide-chat..."
docker compose build mide-chat 2>&1 | tail -15

echo "[${TASK_ID}] restarting mide-chat..."
docker compose up -d --force-recreate mide-chat 2>&1 | tail -10
sleep 8

HEALTH=$(curl -sf http://localhost:7070/health 2>&1 || echo "HEALTH_FAIL")

echo "[${TASK_ID}] health: $HEALTH"

# Trigger AI and inspect recent room history for successful reply.
ASK=$(curl -sf -X POST http://localhost:7070/rooms/OPS-CENTRAL/ask-ai \
  -H 'Content-Type: application/json' \
  -d '{"text":"MTASK-0135 validation ping","caller":"worker"}' 2>&1 || echo "ASK_FAIL")

sleep 6
HISTORY=$(curl -sf "http://localhost:7070/rooms/OPS-CENTRAL/history?limit=10" 2>&1 || echo "HISTORY_FAIL")

echo "[${TASK_ID}] ask-ai: $ASK"

AI_REPLY_CHECK="ok"
if echo "$HISTORY" | grep -q "\[ERROR\] Ollama unreachable"; then
  AI_REPLY_CHECK="error"
fi
if echo "$HISTORY" | grep -q '"kind":"ai"'; then
  :
else
  AI_REPLY_CHECK="missing"
fi

STATUS="completed"
if echo "$HEALTH" | grep -q "HEALTH_FAIL" || echo "$ASK" | grep -q "ASK_FAIL" || echo "$HISTORY" | grep -q "HISTORY_FAIL" || [ "$AI_REPLY_CHECK" != "ok" ]; then
  STATUS="failed"
fi

cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${STATUS}",
  "summary": "Deploy mide-chat AI endpoint fallback and validate room AI reply.",
  "mide_chat_health": $(echo "$HEALTH" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "ask_ai_status": $(echo "$ASK" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "ai_reply_check": "${AI_REPLY_CHECK}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

cd "$REPO"
git add "pilot_v1/results/${TASK_ID}.result.json"
git commit -m "worker: result ${TASK_ID} ${STATUS}"

# Robust push against heartbeat races.
set +e
GIT_TERMINAL_PROMPT=0 timeout 30 git push origin main >/tmp/${TASK_ID}_push.log 2>&1
PUSH_RC=$?
if [ $PUSH_RC -ne 0 ]; then
  GIT_TERMINAL_PROMPT=0 timeout 30 git fetch origin main >/tmp/${TASK_ID}_fetch.log 2>&1
  GIT_TERMINAL_PROMPT=0 timeout 30 git rebase origin/main >/tmp/${TASK_ID}_rebase.log 2>&1
  GIT_TERMINAL_PROMPT=0 timeout 30 git push origin main >/tmp/${TASK_ID}_push_retry.log 2>&1
  PUSH_RC=$?
fi
set -e

if [ $PUSH_RC -ne 0 ]; then
  echo "[${TASK_ID}] warning: push failed after retry"
  tail -20 /tmp/${TASK_ID}_push.log || true
  tail -20 /tmp/${TASK_ID}_push_retry.log || true
  exit 1
fi

echo "[${TASK_ID}] done: ROOM_AI_REPLY_${STATUS^^}"
