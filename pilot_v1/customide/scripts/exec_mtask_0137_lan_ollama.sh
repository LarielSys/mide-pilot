#!/usr/bin/env bash
# RULE: This executor must NOT run git add/commit/push.
# The autopilot framework (worker_mtask_autopilot.sh) owns all git operations.
# MIDE_NO_GIT_PUSH=true is set by the autopilot when running this script.
set -euo pipefail

TASK_ID="MTASK-0137"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="$REPO/pilot_v1/customide"
RESULT_FILE="$REPO/pilot_v1/results/${TASK_ID}.result.json"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 | tail -5
git reset --hard origin/main
echo "[${TASK_ID}] repo synced: $(git rev-parse --short HEAD)"

# Patch docker-compose.yml if OLLAMA_BASE_URL is still the docker bridge IP
cd "$CUSTOMIDE"
if grep -q "172.17.0.1" docker-compose.yml; then
  echo "[${TASK_ID}] patching OLLAMA_BASE_URL to LAN IP..."
  sed -i 's|OLLAMA_BASE_URL=http://172.17.0.1:11434|OLLAMA_BASE_URL=http://192.168.1.21:11434|g' docker-compose.yml
  git add docker-compose.yml
  git commit -m "fix(mide-chat): set OLLAMA_BASE_URL to Ubuntu LAN IP [MTASK-0137]" || true
  # NOTE: no git push — autopilot handles push after executor exits
else
  echo "[${TASK_ID}] OLLAMA_BASE_URL already set correctly, no patch needed"
fi

echo "[${TASK_ID}] rebuilding mide-chat..."
docker compose build mide-chat 2>&1 | tail -15

echo "[${TASK_ID}] restarting mide-chat..."
docker compose up -d --force-recreate mide-chat 2>&1 | tail -10
sleep 10

HEALTH=$(curl -sf http://localhost:7070/health 2>&1 || echo "HEALTH_FAIL")
echo "[${TASK_ID}] health: $HEALTH"

ASK=$(curl -sf -X POST http://localhost:7070/rooms/OPS-CENTRAL/ask-ai \
  -H 'Content-Type: application/json' \
  -d '{"text":"MTASK-0137 validation ping","caller":"worker"}' 2>&1 || echo "ASK_FAIL")

sleep 10
HISTORY=$(curl -sf "http://localhost:7070/rooms/OPS-CENTRAL/history?limit=12" 2>&1 || echo "HISTORY_FAIL")

AI_REPLY_CHECK="ok"
if echo "$HISTORY" | grep -q "\[ERROR\] Ollama unreachable"; then
  AI_REPLY_CHECK="error"
fi
if ! echo "$HISTORY" | grep -q '"kind":"ai"'; then
  AI_REPLY_CHECK="missing"
fi

STATUS="completed"
if echo "$HEALTH" | grep -q "HEALTH_FAIL" \
  || echo "$ASK"  | grep -q "ASK_FAIL" \
  || echo "$HISTORY" | grep -q "HISTORY_FAIL" \
  || [ "$AI_REPLY_CHECK" != "ok" ]; then
  STATUS="failed"
fi

cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${STATUS}",
  "summary": "Patched OLLAMA_BASE_URL to Ubuntu LAN IP (192.168.1.21:11434) and validated AI room replies.",
  "mide_chat_health": $(echo "$HEALTH" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "ask_ai_status": $(echo "$ASK" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "ai_reply_check": "${AI_REPLY_CHECK}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "[${TASK_ID}] done: $STATUS"
# NOTE: Autopilot writes the result JSON and handles git push from here.
