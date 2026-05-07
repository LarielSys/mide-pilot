#!/usr/bin/env bash
# MTASK-0110 — Verify/update larielsystems/chat.html CHAT_BACKEND constant
set -uo pipefail

TASK_ID="MTASK-0110"
REPO_ROOT="/home/larieladmin/mide-pilot"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0110.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

cd "$REPO_ROOT"
git pull origin main 2>&1 | tail -3 | tee -a "$LOG"

# Read tunnel URL from worker1_services.json
SERVICES_FILE="$REPO_ROOT/pilot_v1/state/worker1_services.json"
TUNNEL_URL=$(python3 -c "
import json, sys
d = json.load(open('$SERVICES_FILE'))
tv = d.get('tunnel_verification', {})
chat_url = tv.get('chat_url', '')
# Strip /api/chat suffix to get base URL
base = chat_url.replace('/api/chat', '') if chat_url.endswith('/api/chat') else chat_url
print(base.rstrip('/'))
" 2>/dev/null || echo "")

if [[ -z "$TUNNEL_URL" ]]; then
    echo "ERROR: could not read tunnel URL from worker1_services.json" | tee -a "$LOG"
    echo "final_status=TUNNEL_URL_MISSING" | tee -a "$LOG"
    exit 1
fi

echo "tunnel_url=$TUNNEL_URL" | tee -a "$LOG"

# Check current value in chat.html from git
CHAT_HTML_PATH="$REPO_ROOT/larielsystems/chat.html"
if [[ ! -f "$CHAT_HTML_PATH" ]]; then
    echo "ERROR: chat.html not found at $CHAT_HTML_PATH" | tee -a "$LOG"
    echo "final_status=CHAT_HTML_NOT_FOUND" | tee -a "$LOG"
    exit 1
fi

CURRENT_VALUE=$(grep -oP "const CHAT_BACKEND = '\K[^']+" "$CHAT_HTML_PATH" 2>/dev/null || echo "")
echo "current_value=$CURRENT_VALUE" | tee -a "$LOG"
echo "expected_value=$TUNNEL_URL" | tee -a "$LOG"

if [[ "$CURRENT_VALUE" == "$TUNNEL_URL" ]]; then
    echo "chat_backend_status=already_correct" | tee -a "$LOG"
    echo "snapshot=complete" | tee -a "$LOG"
    echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
    exit 0
fi

# Update the value
echo "updating_chat_backend_to=$TUNNEL_URL" | tee -a "$LOG"
sed -i "s|const CHAT_BACKEND = '[^']*'|const CHAT_BACKEND = '$TUNNEL_URL'|g" "$CHAT_HTML_PATH"

# Verify update
NEW_VALUE=$(grep -oP "const CHAT_BACKEND = '\K[^']+" "$CHAT_HTML_PATH" 2>/dev/null || echo "")
echo "new_value=$NEW_VALUE" | tee -a "$LOG"

if [[ "$NEW_VALUE" != "$TUNNEL_URL" ]]; then
    echo "ERROR: sed update failed" | tee -a "$LOG"
    echo "final_status=UPDATE_FAILED" | tee -a "$LOG"
    exit 1
fi

# Commit and push
git add "$CHAT_HTML_PATH"
git commit -m "worker: update CHAT_BACKEND to $TUNNEL_URL — MTASK-0110"
git push origin main 2>&1 | tee -a "$LOG"

echo "chat_backend_status=updated" | tee -a "$LOG"
echo "snapshot=complete" | tee -a "$LOG"
echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
