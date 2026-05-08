#!/usr/bin/env bash
set -euo pipefail

ORIGIN='https://www.larielsystems.com'
STATE_DIR='pilot_v1/state'
mkdir -p "$STATE_DIR"

log(){ echo "[MTASK-2025] $*"; }

probe_chat(){
  local base="$1"
  local code
  code="$(curl -s -m 12 -o /tmp/mtask2025_chat_probe.json -w '%{http_code}' -X POST "${base%/}/api/chat" \
    -H 'Content-Type: application/json' \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ] && grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2025_chat_probe.json; then
    return 0
  fi
  return 1
}

try_start_upstream(){
  if [ -f docker-compose.yml ]; then
    if docker compose ps >/dev/null 2>&1; then
      docker compose up -d >/tmp/mtask2025_compose_up.log 2>&1 || true
    elif docker-compose ps >/dev/null 2>&1; then
      docker-compose up -d >/tmp/mtask2025_compose_up.log 2>&1 || true
    fi
  fi

  # Try common service starters used in this repo on Ubuntu workers.
  if [ -f setup.bat ] || [ -f start.bat ]; then
    :
  fi

  if [ -f backend/main.py ]; then
    nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port 8082 >/tmp/mtask2025_uvicorn.log 2>&1 &
    sleep 2 || true
  fi

  if [ -f olegreen/bridge_server.py ]; then
    nohup python3 olegreen/bridge_server.py >/tmp/mtask2025_bridge.log 2>&1 &
    sleep 2 || true
  fi
}

get_ngrok_urls(){
  local json
  json="$(curl -s -m 8 http://127.0.0.1:4040/api/tunnels || true)"
  [ -z "$json" ] && return 0
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c "import json,sys
raw=sys.stdin.read().strip()
if not raw:
    raise SystemExit(0)
try:
    d=json.loads(raw)
except Exception:
    raise SystemExit(0)
for t in d.get('tunnels',[]):
    u=str(t.get('public_url','')).strip()
    if u.startswith('https://'):
        print(u.rstrip('/'))"
  else
    echo "$json" | sed -n 's/.*"public_url":"\([^"]*\)".*/\1/p' | grep '^https://' || true
  fi
}

test_public(){
  local base="$1"
  local endpoint="${base%/}/api/chat"
  local headers
  headers="$(curl -s -m 10 -I -X OPTIONS "$endpoint" \
    -H "Origin: ${ORIGIN}" \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,ngrok-skip-browser-warning' | tr -d '\r' || true)"

  {
    echo "candidate=${base}"
    echo "endpoint=${endpoint}"
    echo "$headers"
  } >> "$STATE_DIR/mtask_2025_diagnostics.txt"

  echo "$headers" | grep -qi '^access-control-allow-origin:' || return 1

  local code
  code="$(curl -s -m 15 -o /tmp/mtask2025_public_probe.json -w '%{http_code}' -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'ngrok-skip-browser-warning: true' \
    -H "Origin: ${ORIGIN}" \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"

  echo "post_status=${code}" >> "$STATE_DIR/mtask_2025_diagnostics.txt"
  if [ -f /tmp/mtask2025_public_probe.json ]; then
    echo "post_body=$(head -c 500 /tmp/mtask2025_public_probe.json | tr '\n' ' ')" >> "$STATE_DIR/mtask_2025_diagnostics.txt"
  fi

  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] || return 1
  grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2025_public_probe.json || return 1
  return 0
}

: > "$STATE_DIR/mtask_2025_diagnostics.txt"
log 'Step 1: locate live local /api/chat upstream'
LOCAL_BASE=''
for b in 'http://127.0.0.1:8082' 'http://127.0.0.1:8000' 'http://127.0.0.1:8090' 'http://localhost:8082'; do
  if probe_chat "$b"; then
    LOCAL_BASE="$b"
    break
  fi
done

if [ -z "$LOCAL_BASE" ]; then
  log 'Step 2: bootstrap upstream services'
  try_start_upstream
  for b in 'http://127.0.0.1:8082' 'http://127.0.0.1:8000' 'http://127.0.0.1:8090' 'http://localhost:8082'; do
    if probe_chat "$b"; then
      LOCAL_BASE="$b"
      break
    fi
  done
fi

if [ -z "$LOCAL_BASE" ]; then
  echo 'Unable to bring up local /api/chat upstream on Ubuntu after bootstrap attempts.' >&2
  exit 1
fi

echo "local_base=${LOCAL_BASE}" >> "$STATE_DIR/mtask_2025_diagnostics.txt"

log 'Step 3: validate existing ngrok URLs; create one if needed'
PUBLIC_OK=''
while IFS= read -r u; do
  [ -z "$u" ] && continue
  if test_public "$u"; then
    PUBLIC_OK="$u"
    break
  fi
  echo '---' >> "$STATE_DIR/mtask_2025_diagnostics.txt"
done < <(get_ngrok_urls | sort -u)

if [ -z "$PUBLIC_OK" ]; then
  port="${LOCAL_BASE##*:}"
  curl -s -m 10 -X POST http://127.0.0.1:4040/api/tunnels \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"lariel-chat-${port}\",\"addr\":\"${port}\",\"proto\":\"http\"}" >/tmp/mtask2025_tunnel_create.json || true

  while IFS= read -r u; do
    [ -z "$u" ] && continue
    if test_public "$u"; then
      PUBLIC_OK="$u"
      break
    fi
    echo '---' >> "$STATE_DIR/mtask_2025_diagnostics.txt"
  done < <(get_ngrok_urls | sort -u)
fi

if [ -z "$PUBLIC_OK" ]; then
  echo 'No ngrok public URL passed CORS + POST after local upstream bootstrap.' >&2
  echo '--- mtask_2025 diagnostics begin ---' >&2
  tail -n 260 "$STATE_DIR/mtask_2025_diagnostics.txt" >&2 || true
  echo '--- mtask_2025 diagnostics end ---' >&2
  exit 1
fi

log 'Step 4: publish endpoint'
{
  echo "published_backend=${PUBLIC_OK}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "origin=${ORIGIN}"
  echo "host=$(hostname)"
  echo "local_base=${LOCAL_BASE}"
} > "$STATE_DIR/published_chat_backend.env"

log 'completed'
