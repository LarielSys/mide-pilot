#!/usr/bin/env bash
# RULE: No git push from executor. Autopilot handles all git operations.
set -euo pipefail

TASK_ID="MTASK-0140"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Send a fresh message to LARIEL
ASK=$(curl -sf -X POST http://localhost:7070/rooms/OPS-CENTRAL/ask-ai \
  -H 'Content-Type: application/json' \
  -d '{"text":"MTASK-0140 final confirmation: LARIEL, confirm OPS-CENTRAL is fully operational.","caller":"worker"}' 2>&1 || echo "ASK_FAIL")
echo "[${TASK_ID}] ask: $ASK"

sleep 20

HISTORY=$(curl -sf "http://localhost:7070/rooms/OPS-CENTRAL/history?limit=30" 2>&1 || echo "HISTORY_FAIL")

AI_STATUS=$(echo "$HISTORY" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    # history endpoint returns {room, messages:[...]}
    msgs = data.get('messages', data) if isinstance(data, dict) else data
    ai_msgs = [m for m in msgs if m.get('kind') == 'ai']
    good = [m for m in ai_msgs if '[ERROR]' not in m.get('text','')]
    if good:
        print('ok: ' + good[-1].get('text','')[:120])
    elif ai_msgs:
        print('error: ' + ai_msgs[-1].get('text','')[:120])
    else:
        print('missing: no ai messages')
except Exception as e:
    print('parse_error: ' + str(e))
" 2>&1 || echo "parse_error: python3 failed")

echo "[${TASK_ID}] ai_status: $AI_STATUS"

if echo "$AI_STATUS" | grep -q "^ok:"; then
  echo "[${TASK_ID}] OPS-CENTRAL FULLY OPERATIONAL — LARIEL RESPONDING"
  exit 0
else
  echo "[${TASK_ID}] LARIEL not responding correctly"
  exit 1
fi
