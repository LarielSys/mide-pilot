#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-0098"
echo "objective=restart_site_kb_server"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

KB_PORT=8091
REPO_ROOT="/home/larieladmin/mide-pilot"

# Current status
CURRENT=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${KB_PORT} 2>/dev/null || echo "000")
echo "current_port${KB_PORT}=${CURRENT}"

if [[ "$CURRENT" == "200" || "$CURRENT" == "302" || "$CURRENT" == "404" ]]; then
  echo "site_kb_status=ALREADY_UP"
  echo "snapshot=complete"
  exit 0
fi

# Find running process
KB_PID=$(pgrep -f "site_kb\|8091\|knowledge" 2>/dev/null | head -1 || echo "none")
echo "kb_pid_before=${KB_PID}"

# Search for the kb server entrypoint
KB_APP=$(grep -rl "8091\|site_kb" "$REPO_ROOT" --include="*.py" 2>/dev/null | grep -v "__pycache__" | head -5 || echo "")
echo "kb_candidates=${KB_APP}"

KB_MAIN=$(echo "$KB_APP" | head -1)

if [[ -z "$KB_MAIN" ]]; then
  # Try known path from previous sessions
  KNOWN_PATHS=(
    "/home/larieladmin/site_kb_server/app.py"
    "/home/larieladmin/site_kb/app.py"
    "/home/larieladmin/Documents/itheia-llm/app.py"
    "/home/larieladmin/Documents/itheia-llm/server.py"
  )
  for p in "${KNOWN_PATHS[@]}"; do
    if [[ -f "$p" ]]; then
      KB_MAIN="$p"
      echo "found_at_known_path=${KB_MAIN}"
      break
    fi
  done
fi

if [[ -z "$KB_MAIN" ]]; then
  echo "site_kb_status=NO_ENTRYPOINT_FOUND"
  echo "diagnosis=need_manual_path_for_site_kb_server"
  echo "snapshot=complete"
  exit 0
fi

echo "kb_entrypoint=${KB_MAIN}"

# Kill stale, start fresh
pkill -f "site_kb\|8091" 2>/dev/null || true
sleep 2

cd "$(dirname "$KB_MAIN")"
nohup python3 "$(basename "$KB_MAIN")" > /tmp/site_kb_${TASK_ID:-MTASK-0098}.log 2>&1 &
KB_NEW_PID=$!
echo "kb_server_started_pid=${KB_NEW_PID}"
sleep 6

NEW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${KB_PORT} 2>/dev/null || echo "000")
echo "port${KB_PORT}_after_start=${NEW_STATUS}"

if [[ "$NEW_STATUS" == "200" || "$NEW_STATUS" == "302" || "$NEW_STATUS" == "404" ]]; then
  echo "site_kb_status=UP"
else
  echo "site_kb_status=FAIL_HTTP_${NEW_STATUS}"
  echo "log_tail=$(tail -10 /tmp/site_kb_MTASK-0098.log 2>/dev/null || echo none)"
fi

echo "snapshot=complete"
