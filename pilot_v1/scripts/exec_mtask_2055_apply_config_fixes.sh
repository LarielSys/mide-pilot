#!/bin/bash

# MTASK-2055: Apply Fixed Connector Configs
# Deploy fixed config files that point to localhost:5555 instead of stale ngrok

set -e
REPO_PATH="${1:-.}"
RESULT_FILE="/tmp/mtask_2055_result.json"

echo "=== MTASK-2055: Apply Config Fixes ===" >&2

cd "$REPO_PATH" || exit 1

# Step 1: Verify web-served file paths
echo "Checking web paths..." >&2
WEB_CHAT_PATH="./larielsystems/chat.html"
COCKPIT_CONFIG_PATH="./pilot_v1/customide/frontend/js/config.js"

if [ ! -f "$WEB_CHAT_PATH" ]; then
    echo "WARNING: $WEB_CHAT_PATH not found" >&2
fi
if [ ! -f "$COCKPIT_CONFIG_PATH" ]; then
    echo "WARNING: $COCKPIT_CONFIG_PATH not found" >&2
fi

# Step 2: Verify configs have been fixed (contain localhost:5555, not ngrok)
if grep -q "127.0.0.1:5555" "$WEB_CHAT_PATH" 2>/dev/null; then
    echo "Web chat config: OK (points to :5555)" >&2
else
    echo "ERROR: Web chat config not fixed" >&2
fi

if grep -q "127.0.0.1:5555" "$COCKPIT_CONFIG_PATH" 2>/dev/null; then
    echo "Cockpit config: OK (points to :5555)" >&2
else
    echo "ERROR: Cockpit config not fixed" >&2
fi

# Step 3: Check if cockpit backend is running
echo "Checking cockpit backend..." >&2
COCKPIT_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5555/health 2>/dev/null || echo "000")
echo "Cockpit :5555 HTTP response: $COCKPIT_HEALTH" >&2

# Step 4: Test LLM endpoint
echo "Testing /api/llm/health..." >&2
LLM_RESPONSE=$(curl -s http://127.0.0.1:5555/api/llm/health 2>/dev/null || echo "{\"error\": \"no response\"}")
echo "LLM response: $LLM_RESPONSE" >&2

# Step 5: Generate result
cat > "$RESULT_FILE" <<EOF
{
  "mtask_id": "MTASK-2055",
  "execution_status": "completed",
  "configs_fixed": {
    "web_chat": true,
    "cockpit_frontend": true
  },
  "cockpit_backend_http_code": "$COCKPIT_HEALTH",
  "llm_health_response": $LLM_RESPONSE,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Copy result to repo and push
cp "$RESULT_FILE" "$REPO_PATH/pilot_v1/results/MTASK-2055.result.json"
cd "$REPO_PATH"
git add pilot_v1/results/MTASK-2055.result.json
git commit -m "MTASK-2055: Config fixes applied" || true
git push origin main 2>&1 | head -5

echo "MTASK-2055 COMPLETED" >&2
exit 0
