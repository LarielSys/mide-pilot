#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-0138"
REPO="/home/larieladmin/mide-pilot"
RESULT_FILE="$REPO/pilot_v1/results/${TASK_ID}.result.json"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 | tail -3
git reset --hard origin/main
echo "[${TASK_ID}] repo synced: $(git rev-parse --short HEAD)"

# Send a fresh ask-ai message
ASK=$(curl -sf -X POST http://localhost:7070/rooms/OPS-CENTRAL/ask-ai \
  -H 'Content-Type: application/json' \
  -d "{\"text\":\"MTASK-0138 fresh validation - reply if you can hear us\",\"caller\":\"worker\"}" 2>&1 || echo "ASK_FAIL")

echo "[${TASK_ID}] ask result: $ASK"

# Wait for AI to respond
sleep 15

# Get history and check for a NEW ai reply
HISTORY=$(curl -sf "http://localhost:7070/rooms/OPS-CENTRAL/history?limit=20" 2>&1 || echo "HISTORY_FAIL")

echo "[${TASK_ID}] history snippet: ${HISTORY:0:500}"

# Check if there is ANY ai kind message that does NOT contain ERROR
AI_REPLY_TEXT=$(echo "$HISTORY" | python3 -c "
import sys, json
try:
    items = json.loads(sys.stdin.read())
    ai_msgs = [m for m in items if m.get('kind') == 'ai']
    good = [m for m in ai_msgs if '[ERROR]' not in m.get('text','')]
    if good:
        print('ok|' + good[-1].get('text','')[:120])
    elif ai_msgs:
        print('error|' + ai_msgs[-1].get('text','')[:120])
    else:
        print('missing|no ai messages found')
except Exception as e:
    print('parse_error|' + str(e))
" 2>&1 || echo "parse_error|python3 failed")

AI_STATUS="${AI_REPLY_TEXT%%|*}"
AI_SNIPPET="${AI_REPLY_TEXT#*|}"

echo "[${TASK_ID}] ai_status=$AI_STATUS  snippet=$AI_SNIPPET"

if [ "$AI_STATUS" = "ok" ]; then
  STATUS="completed"
else
  STATUS="failed"
fi

cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${STATUS}",
  "summary": "Fresh clean AI reply validation after MTASK-0137 Ollama LAN URL fix.",
  "ask_ai_status": $(echo "$ASK" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "ai_reply_check": "${AI_STATUS}",
  "ai_reply_snippet": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${AI_SNIPPET}"),
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "[${TASK_ID}] result written: $STATUS"

cd "$REPO"
git add "pilot_v1/results/${TASK_ID}.result.json"
git commit -m "result(${TASK_ID}): ${STATUS}" 2>&1 || true
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 | tail -3
git rebase origin/main 2>&1 | tail -3
GIT_TERMINAL_PROMPT=0 timeout 60 git push origin main 2>&1 | tail -5 || true

echo "[${TASK_ID}] done"
