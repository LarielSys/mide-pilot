#!/usr/bin/env bash
set -euo pipefail

ORIGIN='https://www.larielsystems.com'
STATE_DIR='pilot_v1/state'
mkdir -p "$STATE_DIR"

log(){ echo "[MTASK-2024] $*"; }

test_local_chat(){
  local base="$1"
  local chat_url="${base%/}/api/chat"
  local code
  code="$(curl -s -m 12 -o /tmp/mtask2024_local_chat.json -w '%{http_code}' -X POST "$chat_url" \
    -H 'Content-Type: application/json' \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ] && grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2024_local_chat.json; then
    echo "$base"
    return 0
  fi
  return 1
}

test_public_chat(){
  local base="$1"
  local endpoint="${base%/}/api/chat"

  local headers
  headers="$(curl -s -m 12 -I -X OPTIONS "$endpoint" \
    -H "Origin: ${ORIGIN}" \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,ngrok-skip-browser-warning' | tr -d '\r' || true)"

  echo "candidate=${base}" >> "$STATE_DIR/mtask_2024_diagnostics.txt"
  echo "endpoint=${endpoint}" >> "$STATE_DIR/mtask_2024_diagnostics.txt"
  echo "$headers" >> "$STATE_DIR/mtask_2024_diagnostics.txt"

  echo "$headers" | grep -qi '^access-control-allow-origin:' || return 1

  local code
  code="$(curl -s -m 15 -o /tmp/mtask2024_public_chat.json -w '%{http_code}' -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'ngrok-skip-browser-warning: true' \
    -H "Origin: ${ORIGIN}" \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"

  echo "post_status=${code}" >> "$STATE_DIR/mtask_2024_diagnostics.txt"
  if [ -f /tmp/mtask2024_public_chat.json ]; then
    echo "post_body=$(head -c 500 /tmp/mtask2024_public_chat.json | tr '\n' ' ')" >> "$STATE_DIR/mtask_2024_diagnostics.txt"
  fi

  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] || return 1
  grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2024_public_chat.json || return 1
  return 0
}

get_ngrok_https_urls(){
  local json
  json="$(curl -s -m 8 http://127.0.0.1:4040/api/tunnels || true)"
  if [ -z "$json" ]; then
    return 0
  fi
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

log 'Step 1: discover live local chat upstream'
: > "$STATE_DIR/mtask_2024_diagnostics.txt"
LOCAL_CANDIDATES=(
  'http://127.0.0.1:8082'
  'http://127.0.0.1:8000'
  'http://127.0.0.1:8090'
  'http://localhost:8082'
)
LIVE_LOCAL=''
for b in "${LOCAL_CANDIDATES[@]}"; do
  if test_local_chat "$b"; then
    LIVE_LOCAL="$b"
    break
  fi
done

if [ -z "$LIVE_LOCAL" ]; then
  echo 'No local /api/chat upstream responded 2xx with chat payload on Ubuntu.' >&2
  exit 1
fi

echo "live_local=${LIVE_LOCAL}" >> "$STATE_DIR/mtask_2024_diagnostics.txt"

log 'Step 2: inspect existing ngrok https tunnels'
PUBLIC_OK=''
while IFS= read -r u; do
  [ -z "$u" ] && continue
  if test_public_chat "$u"; then
    PUBLIC_OK="$u"
    break
  fi
  echo '---' >> "$STATE_DIR/mtask_2024_diagnostics.txt"
done < <(get_ngrok_https_urls | sort -u)

if [ -z "$PUBLIC_OK" ]; then
  log 'Step 3: attempt ngrok API tunnel creation for live local upstream'
  if command -v curl >/dev/null 2>&1; then
    port="${LIVE_LOCAL##*:}"
    curl -s -m 10 -X POST http://127.0.0.1:4040/api/tunnels \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"lariel-chat-${port}\",\"addr\":\"${port}\",\"proto\":\"http\"}" >/tmp/mtask2024_tunnel_create.json || true
  fi

  while IFS= read -r u; do
    [ -z "$u" ] && continue
    if test_public_chat "$u"; then
      PUBLIC_OK="$u"
      break
    fi
    echo '---' >> "$STATE_DIR/mtask_2024_diagnostics.txt"
  done < <(get_ngrok_https_urls | sort -u)
fi

if [ -z "$PUBLIC_OK" ]; then
  echo 'No ngrok public URL passed CORS + POST after tunnel rebinding attempt.' >&2
  echo '--- mtask_2024 diagnostics begin ---' >&2
  tail -n 240 "$STATE_DIR/mtask_2024_diagnostics.txt" >&2 || true
  echo '--- mtask_2024 diagnostics end ---' >&2
  exit 1
fi

log 'Step 4: publish validated backend endpoint'
{
  echo "published_backend=${PUBLIC_OK}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "origin=${ORIGIN}"
  echo "host=$(hostname)"
} > "$STATE_DIR/published_chat_backend.env"

log 'completed'
