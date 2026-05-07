#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-0134"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="$REPO/pilot_v1/customide"
RESULT_FILE="$REPO/pilot_v1/results/${TASK_ID}.result.json"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 | tail -5
git reset --hard origin/main
echo "[${TASK_ID}] repo synced: $(git rev-parse --short HEAD)"

cd "$CUSTOMIDE"
echo "[${TASK_ID}] rebuilding frontend + mide-chat..."
docker compose build frontend mide-chat 2>&1 | tail -20

echo "[${TASK_ID}] restarting frontend + mide-chat..."
docker compose up -d --force-recreate frontend mide-chat 2>&1 | tail -10

echo "[${TASK_ID}] waiting 8s for startup..."
sleep 8

HEALTH_CHAT=$(curl -sf http://localhost:7070/health 2>&1 || echo "HEALTH_FAIL")
HEALTH_FRONTEND=$(curl -sfI http://localhost:5570/ 2>&1 | head -1 || echo "FRONTEND_FAIL")

echo "[${TASK_ID}] mide-chat health: $HEALTH_CHAT"
echo "[${TASK_ID}] frontend head: $HEALTH_FRONTEND"

# Verify cockpit room client code is present in frontend payload
FRONTEND_JS=$(curl -sf http://localhost:5570/js/app.js 2>&1 || echo "JS_FETCH_FAIL")
if echo "$FRONTEND_JS" | grep -q "OPS-CENTRAL" && echo "$FRONTEND_JS" | grep -q "connectCockpitRoom"; then
  ROOM_CLIENT_CHECK="ok"
else
  ROOM_CLIENT_CHECK="missing"
fi

echo "[${TASK_ID}] cockpit room client check: $ROOM_CLIENT_CHECK"

STATUS="completed"
if echo "$HEALTH_CHAT" | grep -q "HEALTH_FAIL" || echo "$HEALTH_FRONTEND" | grep -q "FRONTEND_FAIL" || [ "$ROOM_CLIENT_CHECK" != "ok" ]; then
  STATUS="failed"
fi

cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${STATUS}",
  "summary": "Deploy cockpit room wiring: frontend cockpit pane + mide-chat auto-reply.",
  "mide_chat_health": $(echo "$HEALTH_CHAT" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "frontend_head": $(echo "$HEALTH_FRONTEND" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(json.dumps(d))"),
  "cockpit_room_client": "${ROOM_CLIENT_CHECK}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

cd "$REPO"
git add "pilot_v1/results/${TASK_ID}.result.json"
git commit -m "worker: result ${TASK_ID} ${STATUS}"
GIT_TERMINAL_PROMPT=0 timeout 30 git push origin main 2>&1 | tail -3

echo "[${TASK_ID}] done: COCKPIT_ROOM_DEPLOY_${STATUS^^}"
