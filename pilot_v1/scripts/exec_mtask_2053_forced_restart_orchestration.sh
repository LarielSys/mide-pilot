#!/bin/bash

# MTASK-2053: FORCED ORCHESTRATION RESTART
# Last resort: kill everything and restart the entire system

RESULT_FILE="/tmp/mtask_2053_result.json"
WORKER_HOME="/home/larieladmin"
REPO_PATH="$WORKER_HOME/mide-pilot"

cd "$REPO_PATH" || exit 1

echo "=== MTASK-2053: FORCED RESTART ===" >&2

# Kill everything
echo "Killing all processes..." >&2
pkill -9 -f "python.*autopilot" 2>/dev/null || true
pkill -9 -f "python.*worker" 2>/dev/null || true
pkill -9 -f "npm.*customide" 2>/dev/null || true
sleep 1

# Stop docker containers
echo "Stopping docker..." >&2
cd "$REPO_PATH/pilot_v1/customide" 2>/dev/null && docker-compose down -v 2>/dev/null || true
sleep 2

# Start docker daemon if down
echo "Checking docker daemon..." >&2
docker ps >/dev/null 2>&1 || systemctl restart docker 2>/dev/null || true
sleep 2

# Restart services
echo "Restarting services..." >&2
cd "$REPO_PATH/pilot_v1/customide" 2>/dev/null && docker-compose up -d 2>&1 | tail -5

# Wait for services
sleep 10

# Verify services
echo "Verifying services..." >&2
curl -s http://localhost:5555/health >/dev/null 2>&1 && echo "Cockpit: UP" >&2 || echo "Cockpit: DOWN" >&2
curl -s http://localhost:11434/api/tags >/dev/null 2>&1 && echo "Ollama: UP" >&2 || echo "Ollama: DOWN" >&2

# Restart autopilot
echo "Restarting autopilot..." >&2
cd "$REPO_PATH"
git fetch origin main 2>&1 | head -3

# Find and execute first pending task
pending=$(git ls-tree -r --name-only origin/main pilot_v1/tasks/ | grep MTASK-204 | head -1)
if [ -n "$pending" ]; then
    task_id=$(echo "$pending" | sed 's|.*MTASK-\([0-9]*\).*|\1|')
    echo "Next task: MTASK-$task_id" >&2
else
    task_id="NONE"
fi

# Result
cat > "$RESULT_FILE" <<EOF
{
  "mtask_id": "MTASK-2053",
  "execution_status": "completed",
  "action": "forced_orchestration_restart",
  "next_task": "MTASK-$task_id",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

cp "$RESULT_FILE" "$REPO_PATH/pilot_v1/results/MTASK-2053.result.json"
git add pilot_v1/results/MTASK-2053.result.json
git commit -m "MTASK-2053: Forced restart complete" || true
git push origin main 2>&1 | head -5

echo "MTASK-2053 DONE" >&2
exit 0
