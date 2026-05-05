#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-0100"
echo "objective=fix_itheia_llm_server_port_conflict"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

ITHEIA_PORT=8082
ITHEIA_SCRIPT="/home/larieladmin/Documents/itheia-llm/server.py"

# Who is on 8082?
STALE_PID=$(lsof -ti tcp:${ITHEIA_PORT} 2>/dev/null | head -1 || echo "")
STALE_CMD=$(ps -p "$STALE_PID" -o cmd= 2>/dev/null || echo "unknown")
echo "port${ITHEIA_PORT}_occupied_pid=${STALE_PID:-none}"
echo "port${ITHEIA_PORT}_occupied_cmd=${STALE_CMD}"

# Kill it
if [[ -n "$STALE_PID" ]]; then
  kill -9 "$STALE_PID" 2>/dev/null || true
  echo "killed_pid=${STALE_PID}"
  sleep 3
fi

# Verify port now free
STILL_UP=$(lsof -ti tcp:${ITHEIA_PORT} 2>/dev/null | head -1 || echo "")
echo "port_free_after_kill=${STILL_UP:-yes}"

# Restart iTHEIA LLM server
cd "$(dirname "$ITHEIA_SCRIPT")"
nohup python3 "$(basename "$ITHEIA_SCRIPT")" > /tmp/itheia_llm_MTASK-0100.log 2>&1 &
echo "itheia_started_pid=$!"
sleep 8

NEW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${ITHEIA_PORT} 2>/dev/null || echo "000")
echo "port${ITHEIA_PORT}_after_start=${NEW_STATUS}"

if [[ "$NEW_STATUS" == "200" || "$NEW_STATUS" == "302" || "$NEW_STATUS" == "404" ]]; then
  echo "itheia_llm_status=UP"
else
  echo "itheia_llm_status=FAIL_HTTP_${NEW_STATUS}"
  echo "log_tail=$(tail -20 /tmp/itheia_llm_MTASK-0100.log 2>/dev/null || echo none)"
fi

echo "snapshot=complete"
