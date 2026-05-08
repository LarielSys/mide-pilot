#!/usr/bin/env bash
set -euo pipefail

ORIGIN='https://www.larielsystems.com'
KNOWN_FALLBACK_BASE='https://jawed-lapel-dispersed.ngrok-free.dev'

log(){ echo "[MTASK-2022] $*"; }

check_url(){
  local base="$1"
  local endpoint="${base%/}/api/chat"
  local diag_file="$2"

  local headers
  headers="$(curl -s -m 12 -I -X OPTIONS "$endpoint" \
    -H "Origin: ${ORIGIN}" \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,ngrok-skip-browser-warning' | tr -d '\r' || true)"

  {
    echo "candidate=${base}"
    echo "endpoint=${endpoint}"
    echo "options_headers_begin"
    echo "$headers"
    echo "options_headers_end"
  } >> "$diag_file"

  echo "$headers" | grep -qi '^access-control-allow-origin:' || {
    echo "result=no_cors_allow_origin" >> "$diag_file"
    return 1
  }

  local code
  code="$(curl -s -m 20 -o /tmp/mtask2022_resp.json -w '%{http_code}' -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'ngrok-skip-browser-warning: true' \
    -H "Origin: ${ORIGIN}" \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"

  echo "post_status=${code}" >> "$diag_file"
  if [ -f /tmp/mtask2022_resp.json ]; then
    echo "post_body=$(head -c 500 /tmp/mtask2022_resp.json | tr '\n' ' ')" >> "$diag_file"
  fi

  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] || {
    echo "result=post_non_2xx" >> "$diag_file"
    return 1
  }

  grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2022_resp.json || {
    echo "result=post_missing_expected_tokens" >> "$diag_file"
    return 1
  }

  echo "result=ok" >> "$diag_file"
  return 0
}

log 'Step 1: discover current tunnel candidates'
CANDIDATES_FILE='/tmp/mtask2022_candidates.list'
: > "$CANDIDATES_FILE"

if command -v ngrok >/dev/null 2>&1; then
  ngrok_json="$(curl -s -m 8 http://127.0.0.1:4040/api/tunnels || true)"
  if [ -n "$ngrok_json" ]; then
    if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$ngrok_json" | python3 -c "import json,sys
raw=sys.stdin.read().strip()
if not raw:
  raise SystemExit(0)
try:
  data=json.loads(raw)
except Exception:
  raise SystemExit(0)
for t in data.get('tunnels',[]):
  u=str(t.get('public_url','')).strip()
  if u.startswith('https://'):
    print(u.rstrip('/'))" >> "$CANDIDATES_FILE"
    else
      echo "$ngrok_json" | sed -n 's/.*"public_url":"\([^"]*\)".*/\1/p' | grep '^https://' >> "$CANDIDATES_FILE" || true
    fi
  fi
fi

if [ -f pilot_v1/state/published_chat_backend.env ]; then
  grep '^published_backend=' pilot_v1/state/published_chat_backend.env | cut -d'=' -f2- >> "$CANDIDATES_FILE" || true
fi

echo "$KNOWN_FALLBACK_BASE" >> "$CANDIDATES_FILE"

CANDIDATES="$(awk 'NF {gsub(/\/+$/, "", $0); print $0}' "$CANDIDATES_FILE" | sort -u)"

if [ -z "$CANDIDATES" ]; then
  echo 'No tunnel candidates found from ngrok API, published state, or fallback base.' >&2
  exit 1
fi

log 'Step 2: validate each candidate and publish first healthy endpoint'
mkdir -p pilot_v1/state
: > pilot_v1/state/mtask_2022_candidates.txt
: > pilot_v1/state/mtask_2022_diagnostics.txt
FOUND=''
while IFS= read -r c; do
  [ -z "$c" ] && continue
  echo "$c" >> pilot_v1/state/mtask_2022_candidates.txt
  if check_url "$c" pilot_v1/state/mtask_2022_diagnostics.txt; then
    FOUND="$c"
    break
  fi
  echo "---" >> pilot_v1/state/mtask_2022_diagnostics.txt
done <<< "$CANDIDATES"

if [ -z "$FOUND" ]; then
  echo 'No candidate tunnel passed CORS + POST validation.' >&2
  if [ -f pilot_v1/state/mtask_2022_diagnostics.txt ]; then
    echo '--- mtask_2022 diagnostics begin ---' >&2
    tail -n 200 pilot_v1/state/mtask_2022_diagnostics.txt >&2 || true
    echo '--- mtask_2022 diagnostics end ---' >&2
  fi
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
