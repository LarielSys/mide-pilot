#!/usr/bin/env bash
set -euo pipefail

# MTASK-2013: Repair chat page path to Ubuntu Ollama.
# Scope is intentionally narrow: chat page connectivity and verification only.

echo "[MTASK-2013] start"

echo "[MTASK-2013] Step 1: Verify Ubuntu Ollama endpoint reachability"
curl -fsS http://192.168.1.21:11434/api/version >/dev/null

echo "[MTASK-2013] Step 2: Verify required models are present"
MODELS_JSON="$(curl -fsS http://192.168.1.21:11434/api/tags)"
echo "$MODELS_JSON" | grep -q 'qwen2.5-coder:7b'
echo "$MODELS_JSON" | grep -q 'qwen2.5vl:7b'

echo "[MTASK-2013] Step 3: Ensure OLEGREEN bridge uses Ubuntu endpoint and local mode"
export OLEGREEN_OLLAMA_BASE_URL="http://192.168.1.21:11434"
export OLEGREEN_MTASK_MODE="local"
export OLEGREEN_PAUSE_GIT="1"

echo "[MTASK-2013] Step 4: Restart bridge"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "c:/AI Assistant/olegreen/restart_bridge.ps1"

echo "[MTASK-2013] Step 5: Verify bridge endpoint + chat response"
python3 - <<'PY'
import json
import urllib.request

connectors = json.loads(urllib.request.urlopen('http://127.0.0.1:8082/api/connectors', timeout=10).read().decode('utf-8'))
assert connectors.get('ollama_endpoint') == 'http://192.168.1.21:11434', connectors
assert connectors.get('git_paused') is True, connectors

body = json.dumps({'prompt': 'reply with one word: online'}).encode('utf-8')
req = urllib.request.Request('http://127.0.0.1:8082/api/cockpit/act', data=body, headers={'Content-Type':'application/json'}, method='POST')
resp = json.loads(urllib.request.urlopen(req, timeout=30).read().decode('utf-8'))
assert resp.get('ok') is True, resp
print('chat_ok', resp.get('reply', '')[:60])
PY

echo "[MTASK-2013] completed"
