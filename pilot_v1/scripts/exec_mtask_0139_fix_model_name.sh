#!/usr/bin/env bash
# RULE: No git push from executor. Autopilot handles all git operations.
set -euo pipefail

TASK_ID="MTASK-0139"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="$REPO/pilot_v1/customide"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$CUSTOMIDE"

# Verify model is correct
MODEL=$(grep "OLLAMA_CHAT_MODEL" docker-compose.yml | head -1)
echo "[${TASK_ID}] current model env: $MODEL"

# Ensure it's qwen2.5:7b (not qwen2.5-coder:7b which doesn't exist on this host)
if echo "$MODEL" | grep -q "qwen2.5-coder"; then
  echo "[${TASK_ID}] patching model from qwen2.5-coder:7b to qwen2.5:7b..."
  sed -i 's/OLLAMA_CHAT_MODEL=qwen2.5-coder:7b/OLLAMA_CHAT_MODEL=qwen2.5:7b/g' docker-compose.yml
fi

echo "[${TASK_ID}] restarting mide-chat with correct model (no rebuild needed, env only)..."
docker compose up -d --force-recreate mide-chat 2>&1 | tail -10
sleep 8

HEALTH=$(curl -sf http://localhost:7070/health 2>&1 || echo "HEALTH_FAIL")
echo "[${TASK_ID}] health: $HEALTH"

# Send a test message and wait for AI reply
ASK=$(curl -sf -X POST http://localhost:7070/rooms/OPS-CENTRAL/ask-ai \
  -H 'Content-Type: application/json' \
  -d '{"text":"MTASK-0139 validation: confirm you can hear us, LARIEL","caller":"worker"}' 2>&1 || echo "ASK_FAIL")
echo "[${TASK_ID}] ask: $ASK"

sleep 20

HISTORY=$(curl -sf "http://localhost:7070/rooms/OPS-CENTRAL/history?limit=20" 2>&1 || echo "HISTORY_FAIL")
AI_STATUS=$(echo "$HISTORY" | python3 -c "
import sys, json
try:
    items = json.loads(sys.stdin.read())
    ai_msgs = [m for m in items if m.get('kind') == 'ai']
    good = [m for m in ai_msgs if '[ERROR]' not in m.get('text','')]
    if good:
        print('ok: ' + good[-1].get('text','')[:100])
    elif ai_msgs:
        print('error: ' + ai_msgs[-1].get('text','')[:100])
    else:
        print('missing: no ai messages')
except Exception as e:
    print('parse_error: ' + str(e))
" 2>&1 || echo "parse_error: python3 failed")

echo "[${TASK_ID}] ai_status: $AI_STATUS"

if echo "$AI_STATUS" | grep -q "^ok:"; then
  echo "[${TASK_ID}] LARIEL IS RESPONDING CORRECTLY"
  exit 0
else
  echo "[${TASK_ID}] LARIEL still not responding"
  exit 1
fi
