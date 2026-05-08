#!/usr/bin/env bash
set -euo pipefail

# MTASK-2018: restore production website chat by fixing public backend endpoint.
# This task must finish with live verification from larielsystems.com origin.

SITE_URL="https://www.larielsystems.com/chat"
ORIGIN="https://www.larielsystems.com"
OLLAMA_BASE="http://192.168.1.21:11434"
MODEL="qwen2.5-coder:7b"

echo "[MTASK-2018] Step 1: verify Ubuntu Ollama model"
curl -fsS "${OLLAMA_BASE}/api/tags" | grep -q "${MODEL}"

echo "[MTASK-2018] Step 2: establish stable public backend URL"
# Worker must provision a stable HTTPS endpoint (domain/reverse proxy/tunnel)
# and set it in NEW_PUBLIC_CHAT_URL.
NEW_PUBLIC_CHAT_URL=""
if [ -z "${NEW_PUBLIC_CHAT_URL}" ]; then
  echo "NEW_PUBLIC_CHAT_URL is empty; provision endpoint first." >&2
  exit 1
fi

echo "[MTASK-2018] Step 3: verify endpoint POST and CORS"
STATUS="$(curl -s -o /tmp/mtask2018_body.txt -w '%{http_code}' -X POST "${NEW_PUBLIC_CHAT_URL}" \
  -H 'Content-Type: application/json' -H "Origin: ${ORIGIN}" \
  -d '{"message":"reply with one word: online","stream":false}')"
if [ "${STATUS}" -lt 200 ] || [ "${STATUS}" -ge 300 ]; then
  echo "Public endpoint unhealthy status=${STATUS}" >&2
  exit 1
fi

ALLOW="$(curl -s -I -X OPTIONS "${NEW_PUBLIC_CHAT_URL}" \
  -H "Origin: ${ORIGIN}" \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type' | tr -d '\r' | grep -i '^access-control-allow-origin:' || true)"
if [ -z "${ALLOW}" ]; then
  echo "CORS missing for ${ORIGIN}" >&2
  exit 1
fi

echo "[MTASK-2018] Step 4: update production chat frontend backend URL"
# Worker must patch deployed chat page/script to use NEW_PUBLIC_CHAT_URL
# (or same-origin /api/chat if reverse-proxied) and verify live reply.

echo "[MTASK-2018] Step 5: write evidence marker"
mkdir -p pilot_v1/state
{
  echo "task_id=MTASK-2018"
  echo "site_url=${SITE_URL}"
  echo "public_chat_url=${NEW_PUBLIC_CHAT_URL}"
  echo "status=${STATUS}"
  echo "allow_origin=${ALLOW}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
} > pilot_v1/state/mtask_2018_live_chat_restored.txt

echo "[MTASK-2018] completed"
