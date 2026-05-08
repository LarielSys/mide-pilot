#!/usr/bin/env bash
set -euo pipefail

SITE_ORIGIN="https://www.larielsystems.com"
SITE_CHAT="https://www.larielsystems.com/chat"
BRIDGE_LOCAL="http://127.0.0.1:8082"
TARGET_MODEL="qwen2.5-coder:7b"
OLLAMA_BASE="http://192.168.1.21:11434"

log() { echo "[MTASK-2019] $*"; }

log "Step 1: verify Ubuntu Ollama model"
curl -fsS "${OLLAMA_BASE}/api/tags" | grep -q "${TARGET_MODEL}"

log "Step 2: ensure local bridge responds"
curl -fsS "${BRIDGE_LOCAL}/api/connectors" >/tmp/mtask2019_connectors.json

PUBLIC_BASE=""

log "Step 3: discover existing ngrok https tunnel (if available)"
if curl -fsS "http://127.0.0.1:4040/api/tunnels" >/tmp/mtask2019_tunnels.json 2>/dev/null; then
  PUBLIC_BASE="$(python3 - <<'PY'
import json
from pathlib import Path
p = Path('/tmp/mtask2019_tunnels.json')
obj = json.loads(p.read_text())
for t in obj.get('tunnels', []):
    url = str(t.get('public_url') or '')
    cfg = t.get('config') or {}
    addr = str(cfg.get('addr') or '')
    if url.startswith('https://') and ('8082' in addr or 'http://localhost:8082' in addr or 'http://127.0.0.1:8082' in addr):
        print(url.rstrip('/'))
        break
PY
)"
fi

if [ -z "${PUBLIC_BASE}" ]; then
  log "No tunnel found via ngrok API; attempting to start ngrok for 8082"
  if ! command -v ngrok >/dev/null 2>&1; then
    echo "ngrok is not installed on worker and no existing tunnel was discoverable." >&2
    exit 1
  fi

  nohup ngrok http 8082 --log=stdout >/tmp/mtask2019_ngrok.log 2>&1 &

  for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:4040/api/tunnels" >/tmp/mtask2019_tunnels.json 2>/dev/null; then
      PUBLIC_BASE="$(python3 - <<'PY'
import json
from pathlib import Path
p = Path('/tmp/mtask2019_tunnels.json')
obj = json.loads(p.read_text())
for t in obj.get('tunnels', []):
    url = str(t.get('public_url') or '')
    cfg = t.get('config') or {}
    addr = str(cfg.get('addr') or '')
    if url.startswith('https://') and ('8082' in addr or 'http://localhost:8082' in addr or 'http://127.0.0.1:8082' in addr):
        print(url.rstrip('/'))
        break
PY
)"
      [ -n "${PUBLIC_BASE}" ] && break
    fi
    sleep 1
  done
fi

if [ -z "${PUBLIC_BASE}" ]; then
  echo "Could not determine public tunnel URL for bridge 8082." >&2
  exit 1
fi

PUBLIC_ACT_URL="${PUBLIC_BASE}/api/cockpit/act"
log "Discovered public endpoint: ${PUBLIC_ACT_URL}"

log "Step 4: verify CORS preflight allows content-type"
ALLOW_HEADERS="$(curl -s -I -X OPTIONS "${PUBLIC_ACT_URL}" \
  -H "Origin: ${SITE_ORIGIN}" \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type' | tr -d '\r')"

echo "${ALLOW_HEADERS}" | grep -qi '^access-control-allow-origin:' || {
  echo "CORS allow-origin missing on ${PUBLIC_ACT_URL}" >&2
  exit 1
}

echo "${ALLOW_HEADERS}" | grep -qi '^access-control-allow-headers:.*content-type' || {
  echo "CORS allow-headers missing content-type on ${PUBLIC_ACT_URL}" >&2
  exit 1
}

log "Step 5: verify chat response via public endpoint"
RESP="$(curl -fsS -X POST "${PUBLIC_ACT_URL}" \
  -H 'Content-Type: application/json' \
  -H "Origin: ${SITE_ORIGIN}" \
  -d '{"prompt":"reply with one word: online"}')"

echo "${RESP}" | grep -qi 'online\|reply' || {
  echo "Public endpoint response did not contain expected chat payload." >&2
  exit 1
}

log "Step 6: write evidence marker"
mkdir -p pilot_v1/state
{
  echo "task_id=MTASK-2019"
  echo "site_chat=${SITE_CHAT}"
  echo "site_origin=${SITE_ORIGIN}"
  echo "public_base=${PUBLIC_BASE}"
  echo "public_act_url=${PUBLIC_ACT_URL}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
} > pilot_v1/state/mtask_2019_live_chat_backend_ready.txt

log "completed"
