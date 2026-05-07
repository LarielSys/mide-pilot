#!/usr/bin/env bash
# RULE: This executor must NOT run git add/commit/push, and must NOT write result.json.
# The autopilot framework (worker_mtask_autopilot.sh) owns all git operations
# and writes the result JSON from this script's stdout/stderr.
# MIDE_NO_GIT_PUSH=true is set by the autopilot when running this script.
set -euo pipefail

TASK_ID="MTASK-0138"
REPO="/home/larieladmin/mide-pilot"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Send a fresh ask-ai message (no git sync needed - autopilot already synced)
ASK=$(curl -sf -X POST http://localhost:7070/rooms/OPS-CENTRAL/ask-ai \
  -H 'Content-Type: application/json' \
  -d "{\"text\":\"MTASK-0138 fresh validation - reply if you can hear us\",\"caller\":\"worker\"}" 2>&1 || echo "ASK_FAIL")

echo "[${TASK_ID}] ask result: $ASK"

# Wait for AI to respond
sleep 15

# Get history and check for a good AI reply
HISTORY=$(curl -sf "http://localhost:7070/rooms/OPS-CENTRAL/history?limit=20" 2>&1 || echo "HISTORY_FAIL")

echo "[${TASK_ID}] history snippet: ${HISTORY:0:500}"

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

echo "[${TASK_ID}] ai_status=$AI_STATUS"
echo "[${TASK_ID}] ai_snippet=$AI_SNIPPET"

# Exit code signals pass/fail to autopilot
if [ "$AI_STATUS" = "ok" ]; then
  echo "[${TASK_ID}] VALIDATION PASSED — LARIEL is responding via LAN Ollama"
  exit 0
else
  echo "[${TASK_ID}] VALIDATION FAILED — ai_reply_check=$AI_STATUS"
  exit 1
fi

