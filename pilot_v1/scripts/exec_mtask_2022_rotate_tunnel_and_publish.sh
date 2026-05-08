#!/usr/bin/env bash
set -euo pipefail

ORIGIN='https://www.larielsystems.com'

log(){ echo "[MTASK-2022] $*"; }

check_url(){
  local base="$1"
  local endpoint="${base%/}/api/chat"

  local headers
  headers="$(curl -s -I -X OPTIONS "$endpoint" \
    -H "Origin: ${ORIGIN}" \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,ngrok-skip-browser-warning' | tr -d '\r' || true)"

  echo "$headers" | grep -qi '^access-control-allow-origin:' || return 1

  local code
  code="$(curl -s -o /tmp/mtask2022_resp.json -w '%{http_code}' -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'ngrok-skip-browser-warning: true' \
    -H "Origin: ${ORIGIN}" \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"

  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] || return 1
  grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2022_resp.json || return 1
  return 0
}

log 'Step 1: discover current tunnel candidates'
CANDIDATES=""
if command -v ngrok >/dev/null 2>&1; then
  CANDIDATES="$(curl -s http://127.0.0.1:4040/api/tunnels | sed -n 's/.*"public_url":"\([^"]*\)".*/\1/p' | grep '^https://' || true)"
fi

if [ -z "$CANDIDATES" ]; then
  echo 'No active ngrok https tunnel found via local API.' >&2
  exit 1
fi

log 'Step 2: validate each candidate and publish first healthy endpoint'
mkdir -p pilot_v1/state
: > pilot_v1/state/mtask_2022_candidates.txt
FOUND=''
while IFS= read -r c; do
  [ -z "$c" ] && continue
  echo "$c" >> pilot_v1/state/mtask_2022_candidates.txt
  if check_url "$c"; then
    FOUND="$c"
    break
  fi
done <<< "$CANDIDATES"

if [ -z "$FOUND" ]; then
  echo 'No candidate tunnel passed CORS + POST validation.' >&2
  exit 1
fi

log "Step 3: persist published backend endpoint"
{
  echo "published_backend=${FOUND}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "origin=${ORIGIN}"
  echo "host=$(hostname)"
} > pilot_v1/state/published_chat_backend.env

log 'completed'
