#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-0133"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="$REPO/pilot_v1/customide"
RESULT_FILE="$REPO/pilot_v1/results/${TASK_ID}.result.json"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 1. Sync repo ──────────────────────────────────────────────────────────────
cd "$REPO"
GIT_TERMINAL_PROMPT=0 timeout 60 git fetch origin main 2>&1 | tail -5
git reset --hard origin/main
echo "[${TASK_ID}] repo synced: $(git rev-parse --short HEAD)"

# ── 2. Rebuild backend image ──────────────────────────────────────────────────
echo "[${TASK_ID}] rebuilding mide-backend..."
cd "$CUSTOMIDE"
docker compose build backend 2>&1 | tail -10
echo "[${TASK_ID}] build done"

# ── 3. Restart backend container ─────────────────────────────────────────────
echo "[${TASK_ID}] restarting mide-backend..."
docker compose up -d --force-recreate backend 2>&1 | tail -5
echo "[${TASK_ID}] waiting 6s for startup..."
sleep 6

# ── 4. Health check ───────────────────────────────────────────────────────────
HEALTH=$(curl -sf http://localhost:5555/health 2>&1 || echo "HEALTH_FAIL")
echo "[${TASK_ID}] health: $HEALTH"

# ── 5. Verify messenger route exists ─────────────────────────────────────────
MESSENGER=$(curl -sf -X POST http://localhost:5555/api/messenger \
  -H 'Content-Type: application/json' \
  -d '{"text":"MTASK-0133 smoke test","sender":"worker","type":"test"}' 2>&1 || echo "MESSENGER_FAIL")
echo "[${TASK_ID}] messenger POST: $MESSENGER"

# ── 6. Write result ───────────────────────────────────────────────────────────
STATUS="completed"
if echo "$HEALTH" | grep -q "HEALTH_FAIL" || echo "$MESSENGER" | grep -q "MESSENGER_FAIL"; then
  STATUS="failed"
fi

cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${STATUS}",
  "summary": "Backend rebuilt and restarted with mide-chat messenger bridge.",
  "health": $(echo "$HEALTH" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "messenger_test": $(echo "$MESSENGER" | python3 -c "import sys,json; d=sys.stdin.read().strip(); print(d if d.startswith('{') else json.dumps(d))"),
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

cd "$REPO"
git add "pilot_v1/results/${TASK_ID}.result.json"
git commit -m "worker: result ${TASK_ID} ${STATUS}"
GIT_TERMINAL_PROMPT=0 timeout 30 git push origin main 2>&1 | tail -3

echo "[${TASK_ID}] done: BACKEND_REDEPLOYED_${STATUS^^}"
