#!/usr/bin/env bash
set -euo pipefail

ORIGIN='https://www.larielsystems.com'
STATE_DIR='pilot_v1/state'
SHIM_PORT='8091'
OLLAMA_MODEL='qwen2.5-coder:7b'
mkdir -p "$STATE_DIR"

log(){ echo "[MTASK-2026] $*"; }

probe_api_chat(){
  local base="$1"
  local code
  code="$(curl -s -m 12 -o /tmp/mtask2026_probe_chat.json -w '%{http_code}' -X POST "${base%/}/api/chat" \
    -H 'Content-Type: application/json' \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"
  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] && grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2026_probe_chat.json
}

probe_cockpit(){
  local base="$1"
  local code
  code="$(curl -s -m 12 -o /tmp/mtask2026_probe_act.json -w '%{http_code}' -X POST "${base%/}/api/cockpit/act" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Reply with one word: online"}' || true)"
  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] && grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2026_probe_act.json
}

start_bridge(){
  if [ -f olegreen/bridge_server.py ]; then
    nohup python3 olegreen/bridge_server.py >/tmp/mtask2026_bridge.log 2>&1 &
    sleep 2 || true
  fi
}

write_shim(){
  local target_url="$1"
  local mode="$2"
  cat > /tmp/mtask2026_chat_shim.py <<'PY'
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

TARGET=os.environ.get('MTASK2026_TARGET','http://127.0.0.1:8082/api/cockpit/act')
MODE=os.environ.get('MTASK2026_MODE','cockpit')
MODEL=os.environ.get('MTASK2026_MODEL','qwen2.5-coder:7b')
ORIGIN='https://www.larielsystems.com'

class H(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', ORIGIN)
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'content-type, ngrok-skip-browser-warning')

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        if self.path != '/api/chat':
            self.send_response(404)
            self._cors()
            self.end_headers()
            self.wfile.write(b'{"error":"not found"}')
            return
        try:
            n=int(self.headers.get('Content-Length','0'))
            raw=self.rfile.read(n) if n>0 else b'{}'
            data=json.loads(raw.decode('utf-8') or '{}')
            msg=data.get('message') or ''
            if MODE == 'ollama':
              payload={'model': MODEL, 'prompt': msg, 'stream': False}
            else:
              payload={'prompt': msg}
            body=json.dumps(payload).encode('utf-8')
            req=Request(TARGET,data=body,headers={'Content-Type':'application/json'})
            with urlopen(req,timeout=20) as r:
                upstream=json.loads(r.read().decode('utf-8') or '{}')
            if MODE == 'ollama':
              reply=upstream.get('response') or upstream.get('error') or ''
            else:
              reply=upstream.get('reply') or upstream.get('answer') or upstream.get('error') or ''
            out={'answer': reply, 'reply': reply}
            b=json.dumps(out).encode('utf-8')
            self.send_response(200)
            self._cors()
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        except Exception as e:
            b=json.dumps({'error':str(e)}).encode('utf-8')
            self.send_response(502)
            self._cors()
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(b)))
            self.end_headers()
            self.wfile.write(b)

HTTPServer(('127.0.0.1', 8091), H).serve_forever()
PY

  export MTASK2026_TARGET="$target_url"
  export MTASK2026_MODE="$mode"
  export MTASK2026_MODEL="$OLLAMA_MODEL"
}

start_shim(){
  local target_url="$1"
  local mode="$2"
  write_shim "$target_url" "$mode"
  nohup python3 /tmp/mtask2026_chat_shim.py >/tmp/mtask2026_shim.log 2>&1 &
  sleep 2 || true
}

probe_ollama(){
  local base="$1"
  local code
  code="$(curl -s -m 12 -o /tmp/mtask2026_probe_ollama.json -w '%{http_code}' -X POST "${base%/}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"Reply with one word: online\",\"stream\":false}" || true)"
  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] && grep -Eqi 'online|response|error' /tmp/mtask2026_probe_ollama.json
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
    echo "$json" | sed -n 's/.*\"public_url\":\"\([^\"]*\)\".*/\1/p' | grep '^https://' || true
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
  } >> "$STATE_DIR/mtask_2026_diagnostics.txt"

  echo "$headers" | grep -qi '^access-control-allow-origin:' || return 1

  local code
  code="$(curl -s -m 15 -o /tmp/mtask2026_public_probe.json -w '%{http_code}' -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'ngrok-skip-browser-warning: true' \
    -H "Origin: ${ORIGIN}" \
    -d '{"message":"Reply with one word: online","stream":false}' || true)"

  echo "post_status=${code}" >> "$STATE_DIR/mtask_2026_diagnostics.txt"
  if [ -f /tmp/mtask2026_public_probe.json ]; then
    echo "post_body=$(head -c 500 /tmp/mtask2026_public_probe.json | tr '\n' ' ')" >> "$STATE_DIR/mtask_2026_diagnostics.txt"
  fi

  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] || return 1
  grep -Eqi 'online|reply|answer|message|token' /tmp/mtask2026_public_probe.json || return 1
  return 0
}

: > "$STATE_DIR/mtask_2026_diagnostics.txt"

log 'Step 1: ensure bridge/cockpit upstream'
BASE='http://127.0.0.1:8082'
UPSTREAM_MODE=''
UPSTREAM_TARGET=''
if ! probe_cockpit "$BASE"; then
  start_bridge
fi

if probe_cockpit "$BASE"; then
  UPSTREAM_MODE='cockpit'
  UPSTREAM_TARGET='http://127.0.0.1:8082/api/cockpit/act'
else
  for ob in 'http://127.0.0.1:11434' 'http://localhost:11434' 'http://192.168.1.21:11434'; do
    if probe_ollama "$ob"; then
      UPSTREAM_MODE='ollama'
      UPSTREAM_TARGET="${ob%/}/api/generate"
      break
    fi
  done
fi

if [ -z "$UPSTREAM_MODE" ]; then
  echo 'Unable to reach /api/cockpit/act and no Ollama /api/generate endpoint was reachable.' >&2
  exit 1
fi

echo "upstream_mode=${UPSTREAM_MODE}" >> "$STATE_DIR/mtask_2026_diagnostics.txt"
echo "upstream_target=${UPSTREAM_TARGET}" >> "$STATE_DIR/mtask_2026_diagnostics.txt"

log 'Step 2: ensure /api/chat via native or shim'
LOCAL_CHAT_BASE=''
if probe_api_chat "$BASE"; then
  LOCAL_CHAT_BASE="$BASE"
else
  start_shim "$UPSTREAM_TARGET" "$UPSTREAM_MODE"
  if probe_api_chat "http://127.0.0.1:${SHIM_PORT}"; then
    LOCAL_CHAT_BASE="http://127.0.0.1:${SHIM_PORT}"
  fi
fi

if [ -z "$LOCAL_CHAT_BASE" ]; then
  echo 'Could not establish local /api/chat endpoint (native or shim).' >&2
  exit 1
fi

echo "local_chat_base=${LOCAL_CHAT_BASE}" >> "$STATE_DIR/mtask_2026_diagnostics.txt"

log 'Step 3: verify/publish public ngrok endpoint'
PUBLIC_OK=''
while IFS= read -r u; do
  [ -z "$u" ] && continue
  if test_public "$u"; then
    PUBLIC_OK="$u"
    break
  fi
  echo '---' >> "$STATE_DIR/mtask_2026_diagnostics.txt"
done < <(get_ngrok_urls | sort -u)

if [ -z "$PUBLIC_OK" ]; then
  port="${LOCAL_CHAT_BASE##*:}"
  curl -s -m 10 -X POST http://127.0.0.1:4040/api/tunnels \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"lariel-chat-${port}\",\"addr\":\"${port}\",\"proto\":\"http\"}" >/tmp/mtask2026_tunnel_create.json || true

  while IFS= read -r u; do
    [ -z "$u" ] && continue
    if test_public "$u"; then
      PUBLIC_OK="$u"
      break
    fi
    echo '---' >> "$STATE_DIR/mtask_2026_diagnostics.txt"
  done < <(get_ngrok_urls | sort -u)
fi

if [ -z "$PUBLIC_OK" ]; then
  echo 'No ngrok public URL passed CORS + POST after chat shim bootstrap.' >&2
  echo '--- mtask_2026 diagnostics begin ---' >&2
  tail -n 260 "$STATE_DIR/mtask_2026_diagnostics.txt" >&2 || true
  echo '--- mtask_2026 diagnostics end ---' >&2
  exit 1
fi

{
  echo "published_backend=${PUBLIC_OK}"
  echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "origin=${ORIGIN}"
  echo "host=$(hostname)"
  echo "local_chat_base=${LOCAL_CHAT_BASE}"
} > "$STATE_DIR/published_chat_backend.env"

log 'completed'
