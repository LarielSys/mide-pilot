#!/usr/bin/env bash
set -euo pipefail

# MTASK-2017: restore public website chat backend path with CORS for larielsystems.com.

BASE="https://www.larielsystems.com"
ORIGIN="https://www.larielsystems.com"
TARGET_MODEL="qwen2.5-coder:7b"

echo "[MTASK-2017] Step 1: verify Ubuntu Ollama has required model"
curl -fsS http://192.168.1.21:11434/api/tags | grep -q "${TARGET_MODEL}"

echo "[MTASK-2017] Step 2: verify public chat endpoint is reachable and CORS-enabled"
# Worker should replace this URL with active stable HTTPS backend if tunnel/domain changed.
PUBLIC_CHAT_URL="https://jawed-lapel-dispersed.ngrok-free.dev/api/chat"

STATUS_CODE="$(curl -s -o /tmp/mtask2017_body.txt -w '%{http_code}' -X POST "${PUBLIC_CHAT_URL}" \
  -H 'Content-Type: application/json' \
  -H "Origin: ${ORIGIN}" \
  -d '{"message":"health check","stream":false}')"

echo "status=${STATUS_CODE}"
if [ "${STATUS_CODE}" -lt 200 ] || [ "${STATUS_CODE}" -ge 300 ]; then
  echo "Public chat endpoint not healthy; restart/repoint tunnel or public backend route before completion." >&2
  exit 1
fi

echo "[MTASK-2017] Step 3: CORS preflight check"
ALLOW_ORIGIN="$(curl -s -I -X OPTIONS "${PUBLIC_CHAT_URL}" \
  -H "Origin: ${ORIGIN}" \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type' | tr -d '\r' | grep -i '^access-control-allow-origin:' || true)"

if [ -z "${ALLOW_ORIGIN}" ]; then
  echo "CORS allow-origin header missing on public chat endpoint." >&2
  exit 1
fi

echo "[MTASK-2017] Step 4: write evidence marker"
mkdir -p pilot_v1/state
{
  echo "task_id=MTASK-2017"
  echo "public_chat_url=${PUBLIC_CHAT_URL}"
  echo "status_code=${STATUS_CODE}"
  echo "allow_origin=${ALLOW_ORIGIN}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
} > pilot_v1/state/mtask_2017_website_chat_backend_ready.txt

echo "[MTASK-2017] completed"
