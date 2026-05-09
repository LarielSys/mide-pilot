#!/usr/bin/env bash
set -euo pipefail

ORIGIN='https://www.larielsystems.com'
STATE_DIR='pilot_v1/state'
SHIM_PORT='8091'
OLLAMA_MODEL='qwen2.5-coder:7b'
WEBSITE_SYSTEM_CONTEXT='You are Lariel, the Lariel Systems website AI assistant and webpage expert. Primary scope: Lariel Systems services, process, MOSS, contact/get quote flow, and website guidance. Respond clearly and concisely in a professional tone. If a question is outside site scope, say so briefly and suggest contacting Lariel Systems. Do not invent unavailable services, prices, or guarantees. Never promise guaranteed outcomes or exact pricing. For any pricing, quote, or guarantee question, direct the user to the Contact/Get Quote flow.'
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
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

TARGET=os.environ.get('MTASK2026_TARGET','http://127.0.0.1:8082/api/cockpit/act')
MODE=os.environ.get('MTASK2026_MODE','cockpit')
MODEL=os.environ.get('MTASK2026_MODEL','qwen2.5-coder:7b')
SYSTEM_CONTEXT=os.environ.get('MTASK2026_SYSTEM_CONTEXT','')
ORIGIN='https://www.larielsystems.com'

KB_URLS=[
  'https://www.larielsystems.com/',
  'https://www.larielsystems.com/services',
  'https://www.larielsystems.com/process',
  'https://www.larielsystems.com/moss',
  'https://www.larielsystems.com/contact',
]

def _html_to_text(html):
  t=re.sub(r'(?is)<script.*?>.*?</script>', ' ', html)
  t=re.sub(r'(?is)<style.*?>.*?</style>', ' ', t)
  t=re.sub(r'(?s)<[^>]+>', ' ', t)
  t=re.sub(r'\s+', ' ', t).strip()
  return t

def _build_site_kb():
  parts=[]
  for u in KB_URLS:
    try:
      req=Request(u, headers={'User-Agent':'mtask-2026-chat-shim'})
      with urlopen(req, timeout=10) as r:
        raw=r.read().decode('utf-8', errors='ignore')
      txt=_html_to_text(raw)
      if txt:
        parts.append(f'URL: {u}\\n{txt[:1400]}')
    except Exception:
      continue
  kb='\\n\\n'.join(parts)
  return kb[:7000]

SITE_KB=_build_site_kb()

def _rule_based_answer(msg):
  m=(msg or '').lower()
  if any(k in m for k in ['contact', 'email', 'phone', 'call', 'reach', 'address', 'get quote', 'quote']):
    return (
      'For contact details and quote requests, use the Contact page: '
      'https://www.larielsystems.com/contact and the Get Quote flow on the website. '
      'If you share what you need, I can help you prepare the request message.'
    )
  if any(k in m for k in ['service', 'services', 'offer', 'offering', 'capabilities']):
    return (
      'Lariel Systems services are outlined on https://www.larielsystems.com/services. '
      'You can also review MOSS-specific information at https://www.larielsystems.com/moss '
      'and the delivery workflow at https://www.larielsystems.com/process.'
    )
  if any(k in m for k in ['process', 'workflow', 'how do you work', 'how you work']):
    return 'The website process flow is documented at https://www.larielsystems.com/process.'
  if any(k in m for k in ['moss', 'demo', 'studio']):
    return 'MOSS information is available at https://www.larielsystems.com/moss.'
  return None

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
            direct=_rule_based_answer(msg)
            if direct:
              out={'answer': direct, 'reply': direct}
              b=json.dumps(out).encode('utf-8')
              self.send_response(200)
              self._cors()
              self.send_header('Content-Type','application/json')
              self.send_header('Content-Length',str(len(b)))
              self.end_headers()
              self.wfile.write(b)
              return
            if MODE == 'ollama':
              prompt=(
                  f"{SYSTEM_CONTEXT}\n\n"
                  f"Website context (authoritative excerpts):\n{SITE_KB}\n\n"
                  f"User question: {msg}\n\n"
                  "Assistant answer:"
              )
              payload={'model': MODEL, 'prompt': prompt, 'stream': False}
            else:
              routed=f"{SYSTEM_CONTEXT}\n\nUser question: {msg}"
              payload={'prompt': routed}
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
  export MTASK2026_SYSTEM_CONTEXT="$WEBSITE_SYSTEM_CONTEXT"
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

log 'Step 1: ensure website-expert upstream (ollama first, cockpit fallback)'
BASE='http://127.0.0.1:8082'
UPSTREAM_MODE=''
UPSTREAM_TARGET=''
for ob in 'http://192.168.1.21:11434' 'http://127.0.0.1:11434' 'http://localhost:11434'; do
  if probe_ollama "$ob"; then
    UPSTREAM_MODE='ollama'
    UPSTREAM_TARGET="${ob%/}/api/generate"
    break
  fi
done

if [ -z "$UPSTREAM_MODE" ]; then
  if ! probe_cockpit "$BASE"; then
    start_bridge
  fi
  if probe_cockpit "$BASE"; then
    UPSTREAM_MODE='cockpit'
    UPSTREAM_TARGET='http://127.0.0.1:8082/api/cockpit/act'
  fi
fi

if [ -z "$UPSTREAM_MODE" ]; then
  echo 'Unable to reach /api/cockpit/act and no Ollama /api/generate endpoint was reachable.' >&2
  exit 1
fi

echo "upstream_mode=${UPSTREAM_MODE}" >> "$STATE_DIR/mtask_2026_diagnostics.txt"
echo "upstream_target=${UPSTREAM_TARGET}" >> "$STATE_DIR/mtask_2026_diagnostics.txt"

log 'Step 2: ensure /api/chat via native or shim'
LOCAL_CHAT_BASE=''
start_shim "$UPSTREAM_TARGET" "$UPSTREAM_MODE"
if probe_api_chat "http://127.0.0.1:${SHIM_PORT}"; then
  LOCAL_CHAT_BASE="http://127.0.0.1:${SHIM_PORT}"
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
