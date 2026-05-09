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

probe_api_chat_contact(){
  local base="$1"
  local code
  code="$(curl -s -m 12 -o /tmp/mtask2026_probe_chat_contact.json -w '%{http_code}' -X POST "${base%/}/api/chat" \
    -H 'Content-Type: application/json' \
    -d '{"message":"what is the contact information on the Lariel Systems website?","stream":false}' || true)"
  [ "$code" -ge 200 ] && [ "$code" -lt 300 ] && grep -Eqi 'larielsystems.com/contact|get quote|contact page' /tmp/mtask2026_probe_chat_contact.json
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
import html
from collections import Counter
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
  'https://www.larielsystems.com/moss-demo',
  'https://www.larielsystems.com/contact',
]

def _html_to_text(raw_html):
  t=re.sub(r'(?is)<script.*?>.*?</script>', ' ', raw_html)
  t=re.sub(r'(?is)<style.*?>.*?</style>', ' ', t)
  t=re.sub(r'(?s)<[^>]+>', ' ', t)
  t=html.unescape(t)
  t=re.sub(r'\s+', ' ', t).strip()
  return t

def _build_site_kb():
  docs=[]
  parts=[]
  for u in KB_URLS:
    try:
      req=Request(u, headers={'User-Agent':'mtask-2026-chat-shim'})
      with urlopen(req, timeout=10) as r:
        raw=r.read().decode('utf-8', errors='ignore')
      txt=_html_to_text(raw)
      if txt:
        t=txt[:2800]
        docs.append({'url':u,'text':t,'lower':t.lower()})
        parts.append(f'URL: {u}\\n{t[:1400]}')
    except Exception:
      continue
  kb='\\n\\n'.join(parts)
  return kb[:7000], docs

SITE_KB, SITE_DOCS=_build_site_kb()

def _extract_contact_details():
  contact_docs=[d for d in SITE_DOCS if '/contact' in d.get('url','')]
  if not contact_docs:
    return None
  txt=' '.join(d.get('text','') for d in contact_docs)
  txt=re.sub(r'\s+', ' ', txt)
  emails=re.findall(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', txt)
  phones=[]
  for pat in [r'\+\d{1,3}\s\d{2,4}\s\d{3,4}\s\d{3,4}', r'\d{3}-\d{3}-\d{4}']:
    phones.extend(re.findall(pat, txt))
  uniq_emails=[]
  for e in emails:
    if e not in uniq_emails:
      uniq_emails.append(e)
  uniq_phones=[]
  for p in phones:
    if p not in uniq_phones:
      uniq_phones.append(p)
  return {
    'emails': uniq_emails[:2],
    'phones': uniq_phones[:3],
  }

CONTACT_DETAILS=_extract_contact_details()

def _label_phone(phone):
  p=(phone or '').strip()
  if p.startswith('+52'):
    return f"Mexico: {p}"
  if re.fullmatch(r'\d{3}-\d{3}-\d{4}', p):
    return f"US: {p}"
  return p

def _keywords(msg):
  tokens=re.findall(r"[a-z0-9]+", (msg or '').lower())
  stop={'the','and','for','with','that','this','from','your','about','what','when','where','how','are','can','you','our'}
  return [t for t in tokens if len(t) > 2 and t not in stop]

def _best_docs(msg, n=2):
  kws=_keywords(msg)
  if not kws or not SITE_DOCS:
    return []
  scored=[]
  for d in SITE_DOCS:
    score=0
    for k in kws:
      if k in d['lower']:
        score += 1 + d['lower'].count(k)
    if score:
      scored.append((score, d))
  scored.sort(key=lambda x: x[0], reverse=True)
  return [d for _, d in scored[:n]]

def _best_doc_for_url_hint(url_hint):
  for d in SITE_DOCS:
    if url_hint in d.get('url',''):
      return d
  return None

def _summarize_excerpt(text, msg):
  if not text:
    return ''
  kws=_keywords(msg)
  text=html.unescape(text)
  text=re.sub(r'\s+', ' ', text).strip()
  low=text.lower()
  idx=0
  for k in kws:
    i=low.find(k)
    if i >= 0:
      idx=i
      break
  prev=max(text.rfind('. ', 0, idx), text.rfind('! ', 0, idx), text.rfind('? ', 0, idx))
  start=(prev + 2) if prev >= 0 else max(0, idx-80)
  next_dot=text.find('. ', min(len(text)-1, idx+120))
  next_bang=text.find('! ', min(len(text)-1, idx+120))
  next_q=text.find('? ', min(len(text)-1, idx+120))
  ends=[p for p in [next_dot, next_bang, next_q] if p >= 0]
  end=(min(ends) + 1) if ends else min(len(text), idx+220)

  if start > 0 and start < len(text) and text[start].isalnum() and text[start-1].isalnum():
    next_space=text.find(' ', start)
    if next_space >= 0:
      start=next_space + 1

  snippet=text[start:end].strip()
  snippet=re.sub(r'\s+', ' ', snippet)
  if re.match(r'^(tion|sion|ment|ing)\b', snippet.lower()):
    return ''
  return snippet

def _is_noisy_snippet(snippet):
  s=(snippet or '').lower()
  if not s:
    return True
  noisy_markers=[
    'services process moss ai chat contact get quote',
    'all rights reserved',
    'tiktok',
    'intelligence. integration. innovation',
  ]
  if any(m in s for m in noisy_markers):
    return True
  return False

def _site_grounded_answer(msg):
  docs=_best_docs(msg, n=1)
  if not docs:
    return None
  d=docs[0]
  sn=_summarize_excerpt(d['text'], msg)
  if not sn or _is_noisy_snippet(sn):
    return None
  return f"Based on {d['url']}: {sn}"[:320]

def _grounded_from_hint(url_hint, prefix):
  d=_best_doc_for_url_hint(url_hint)
  if not d:
    fallback=_site_grounded_answer(url_hint or '')
    return (prefix + ' ' + fallback)[:360] if fallback else prefix
  sn=_summarize_excerpt(d.get('text',''), url_hint)
  if not sn or _is_noisy_snippet(sn):
    fallback=_site_grounded_answer(url_hint or '')
    return (prefix + ' ' + fallback)[:360] if fallback else prefix
  return f"{prefix} {sn}"[:360]

def _rule_based_answer(msg):
  m=(msg or '').lower()
  if any(k in m for k in ['contact', 'email', 'phone', 'call', 'reach', 'address', 'get quote', 'quote']):
    parts=['For contact details and quote requests, use https://www.larielsystems.com/contact.']
    if CONTACT_DETAILS:
      if CONTACT_DETAILS.get('emails'):
        parts.append('Email: ' + ', '.join(CONTACT_DETAILS['emails']) + '.')
      if CONTACT_DETAILS.get('phones'):
        labeled=[_label_phone(p) for p in CONTACT_DETAILS['phones']]
        parts.append('Phone: ' + ', '.join(labeled) + '.')
    parts.append('Use the Get Quote flow on the website for project requests.')
    return ' '.join(parts)
  if any(k in m for k in ['service', 'services', 'offer', 'offering', 'capabilities']):
    return _grounded_from_hint(
      '/services',
      'Services are detailed at https://www.larielsystems.com/services. For implementation flow see https://www.larielsystems.com/process and for product context see https://www.larielsystems.com/moss-demo.'
    )
  if any(k in m for k in ['process', 'workflow', 'how do you work', 'how you work']):
    return _grounded_from_hint(
      '/process',
      'Our workflow is documented at https://www.larielsystems.com/process.'
    )
  if any(k in m for k in ['moss', 'demo', 'studio']):
    return _grounded_from_hint(
      '/moss-demo',
      'MOSS information is available at https://www.larielsystems.com/moss-demo.'
    )
  return _site_grounded_answer(msg) or 'I can help with Lariel Systems services, process, MOSS, or contact/quote guidance.'

def _extract_user_question(raw_msg):
  s=(raw_msg or '').strip()
  if not s:
    return ''
  marker='User question:'
  if marker in s:
    # Keep only the latest user question segment if prompt scaffolding was included upstream.
    s=s.split(marker)[-1].strip()
  return s

class H(BaseHTTPRequestHandler):
    def _cors(self):
        req_origin=(self.headers.get('Origin') or '').strip()
        allowed={
          ORIGIN,
          'http://localhost:8080',
          'http://127.0.0.1:8080',
          'null',
        }
        allow_origin=req_origin if req_origin in allowed else ORIGIN
        self.send_header('Access-Control-Allow-Origin', allow_origin)
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
            msg=_extract_user_question(data.get('message') or '')
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
  # Replace any stale shim so latest code is always active.
  if command -v pkill >/dev/null 2>&1; then
    pkill -f '/tmp/mtask2026_chat_shim.py' >/dev/null 2>&1 || true
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser -k 8091/tcp >/dev/null 2>&1 || true
  fi
  write_shim "$target_url" "$mode"
  nohup python3 /tmp/mtask2026_chat_shim.py >/tmp/mtask2026_shim.log 2>&1 &
  sleep 3 || true
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

  # Ensure this endpoint actually serves website-aware chat behavior.
  local code_contact
  code_contact="$(curl -s -m 15 -o /tmp/mtask2026_public_contact.json -w '%{http_code}' -X POST "$endpoint" \
    -H 'Content-Type: application/json' \
    -H 'ngrok-skip-browser-warning: true' \
    -H "Origin: ${ORIGIN}" \
    -d '{"message":"what is the contact information on the Lariel Systems website?","stream":false}' || true)"

  echo "contact_status=${code_contact}" >> "$STATE_DIR/mtask_2026_diagnostics.txt"
  if [ -f /tmp/mtask2026_public_contact.json ]; then
    echo "contact_body=$(head -c 500 /tmp/mtask2026_public_contact.json | tr '\n' ' ')" >> "$STATE_DIR/mtask_2026_diagnostics.txt"
  fi

  [ "$code_contact" -ge 200 ] && [ "$code_contact" -lt 300 ] || return 1
  grep -Eqi 'larielsystems.com/contact|get quote|contact page' /tmp/mtask2026_public_contact.json || return 1

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
if probe_api_chat "http://127.0.0.1:${SHIM_PORT}" && probe_api_chat_contact "http://127.0.0.1:${SHIM_PORT}"; then
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
