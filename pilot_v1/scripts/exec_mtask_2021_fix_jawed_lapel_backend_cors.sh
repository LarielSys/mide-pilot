#!/usr/bin/env bash
set -euo pipefail

BASE="https://jawed-lapel-dispersed.ngrok-free.dev"
ORIGIN="https://www.larielsystems.com"

log() { echo "[MTASK-2021] $*"; }

check_endpoint() {
  local url="$1"
  local body="$2"

  local headers
  headers="$(curl -s -I -X OPTIONS "${url}" \
    -H "Origin: ${ORIGIN}" \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,ngrok-skip-browser-warning' | tr -d '\r' || true)"

  echo "${headers}" | grep -qi '^access-control-allow-origin:' || return 1
  echo "${headers}" | grep -qi '^access-control-allow-headers:.*content-type' || return 1

  local status
  status="$(curl -s -o /tmp/mtask2021_resp.json -w '%{http_code}' -X POST "${url}" \
    -H 'Content-Type: application/json' \
    -H 'ngrok-skip-browser-warning: true' \
    -H "Origin: ${ORIGIN}" \
    -d "${body}" || true)"

  [ "${status}" -ge 200 ] && [ "${status}" -lt 300 ] || return 1
  grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2021_resp.json || return 1
  return 0
}

log "Step 1: Validate /api/chat and /api/cockpit/act"
CHAT_OK=0
ACT_OK=0

if check_endpoint "${BASE}/api/chat" '{"message":"reply with one word: online","stream":false}'; then
  CHAT_OK=1
fi
if check_endpoint "${BASE}/api/cockpit/act" '{"prompt":"reply with one word: online"}'; then
  ACT_OK=1
fi

if [ "${CHAT_OK}" -eq 0 ] && [ "${ACT_OK}" -eq 0 ]; then
  log "Step 2: repair upstream routing/service and retry checks"
  # Worker actions required on Ubuntu:
  # - ensure bridge/backend process is running and bound to target port
  # - ensure ngrok tunnel forwards to the correct local service
  # - ensure CORS headers include larielsystems origin and content-type
  # Then this script is retried by autopilot.
  echo "Both chat endpoints failed CORS/POST verification on ${BASE}." >&2
  exit 1
fi

log "Step 3: write evidence marker"
mkdir -p pilot_v1/state
{
  echo "task_id=MTASK-2021"
  echo "base=${BASE}"
  echo "chat_ok=${CHAT_OK}"
  echo "act_ok=${ACT_OK}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
} > pilot_v1/state/mtask_2021_jawed_lapel_fixed.txt

log "completed"
