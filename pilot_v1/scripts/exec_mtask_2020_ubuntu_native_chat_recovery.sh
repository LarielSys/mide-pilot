#!/usr/bin/env bash
set -euo pipefail

SITE_ORIGIN="https://www.larielsystems.com"
OLLAMA_BASE="http://127.0.0.1:11434"
MODEL="qwen2.5-coder:7b"

log() { echo "[MTASK-2020] $*"; }

log "Step 1: verify local Ubuntu Ollama and model"
curl -fsS "${OLLAMA_BASE}/api/version" >/dev/null
curl -fsS "${OLLAMA_BASE}/api/tags" | grep -q "${MODEL}"

choose_public_base_from_ngrok_api() {
  python3 - <<'PY'
import json
from pathlib import Path
p = Path('/tmp/mtask2020_tunnels.json')
obj = json.loads(p.read_text())
# Prefer HTTPS tunnels that likely front API-capable local services.
for t in obj.get('tunnels', []):
    url = str(t.get('public_url') or '')
    cfg = t.get('config') or {}
    addr = str(cfg.get('addr') or '')
    if not url.startswith('https://'):
        continue
    if any(port in addr for port in ('7070','8082','8091','8090')):
        print(url.rstrip('/'))
        raise SystemExit(0)
# Fallback: first https tunnel
for t in obj.get('tunnels', []):
    url = str(t.get('public_url') or '')
    if url.startswith('https://'):
        print(url.rstrip('/'))
        raise SystemExit(0)
PY
}

PUBLIC_BASE=""

log "Step 2: detect active ngrok tunnels on Ubuntu"
if curl -fsS "http://127.0.0.1:4040/api/tunnels" >/tmp/mtask2020_tunnels.json 2>/dev/null; then
  PUBLIC_BASE="$(choose_public_base_from_ngrok_api || true)"
fi

if [ -z "${PUBLIC_BASE}" ]; then
  log "No active tunnel discovered; attempting to start ngrok for port 7070"
  if ! command -v ngrok >/dev/null 2>&1; then
    echo "ngrok not installed on Ubuntu worker and no tunnel is active." >&2
    exit 1
  fi

  nohup ngrok http 7070 --log=stdout >/tmp/mtask2020_ngrok.log 2>&1 &
  for _ in $(seq 1 25); do
    if curl -fsS "http://127.0.0.1:4040/api/tunnels" >/tmp/mtask2020_tunnels.json 2>/dev/null; then
      PUBLIC_BASE="$(choose_public_base_from_ngrok_api || true)"
      [ -n "${PUBLIC_BASE}" ] && break
    fi
    sleep 1
  done
fi

if [ -z "${PUBLIC_BASE}" ]; then
  echo "Unable to resolve a public tunnel URL from Ubuntu." >&2
  exit 1
fi

log "Discovered PUBLIC_BASE=${PUBLIC_BASE}"

# Candidate endpoints and payloads.
CANDIDATES=(
  "${PUBLIC_BASE}/api/chat|{\"message\":\"reply with one word: online\",\"stream\":false}"
  "${PUBLIC_BASE}/api/cockpit/act|{\"prompt\":\"reply with one word: online\"}"
)

SUCCESS_URL=""
SUCCESS_BODY=""
SUCCESS_ALLOW=""

log "Step 3: validate endpoint candidates with CORS + POST"
for row in "${CANDIDATES[@]}"; do
  URL="${row%%|*}"
  BODY="${row#*|}"

  ALLOW_HEADERS="$(curl -s -I -X OPTIONS "${URL}" \
    -H "Origin: ${SITE_ORIGIN}" \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type' | tr -d '\r' || true)"

  echo "${ALLOW_HEADERS}" | grep -qi '^access-control-allow-origin:' || continue
  echo "${ALLOW_HEADERS}" | grep -qi '^access-control-allow-headers:.*content-type' || continue

  RESP_FILE="/tmp/mtask2020_resp.json"
  STATUS="$(curl -s -o "${RESP_FILE}" -w '%{http_code}' -X POST "${URL}" \
    -H 'Content-Type: application/json' \
    -H "Origin: ${SITE_ORIGIN}" \
    -d "${BODY}" || true)"

  if [ "${STATUS}" -ge 200 ] && [ "${STATUS}" -lt 300 ]; then
    RESP="$(cat "${RESP_FILE}")"
    if echo "${RESP}" | grep -Eqi 'online|reply|answer|message'; then
      SUCCESS_URL="${URL}"
      SUCCESS_BODY="${RESP}"
      SUCCESS_ALLOW="${ALLOW_HEADERS}"
      break
    fi
  fi
done

if [ -z "${SUCCESS_URL}" ]; then
  echo "No public endpoint candidate passed CORS + POST verification." >&2
  exit 1
fi

log "Step 4: write evidence marker"
mkdir -p pilot_v1/state
{
  echo "task_id=MTASK-2020"
  echo "public_base=${PUBLIC_BASE}"
  echo "verified_endpoint=${SUCCESS_URL}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
  echo "response_excerpt=$(echo "${SUCCESS_BODY}" | head -c 220 | tr '\n' ' ')"
} > pilot_v1/state/mtask_2020_ubuntu_native_chat_ready.txt

log "completed"
