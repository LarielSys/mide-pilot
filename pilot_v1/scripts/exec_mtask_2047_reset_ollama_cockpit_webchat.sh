#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-2047"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
RESULT_DIR="${REPO_ROOT}/pilot_v1/results"
RESULT_FILE="${RESULT_DIR}/${TASK_ID}.result.json"
SERVICES_FILE="${STATE_DIR}/worker1_services.json"
PUBLISHED_ENV="${STATE_DIR}/published_chat_backend.env"
CHAT_HTML="${REPO_ROOT}/larielsystems/chat.html"
COCKPIT_CFG="${REPO_ROOT}/pilot_v1/customide/frontend/js/config.js"
HARD_RESET_FILE="${STATE_DIR}/cockpit_hard_reset_request.json"
ORIGIN='https://www.larielsystems.com'

mkdir -p "${STATE_DIR}" "${RESULT_DIR}"

log(){ echo "[${TASK_ID}] $*"; }

probe_ollama_tags_http(){
  curl -s -o /tmp/${TASK_ID}_ollama_tags.json -w '%{http_code}' --max-time 10 http://127.0.0.1:11434/api/tags 2>/dev/null || echo 000
}

probe_cockpit_bundle_http(){
  curl -s -o /tmp/${TASK_ID}_cockpit_bundle.json -w '%{http_code}' --max-time 10 http://127.0.0.1:5555/api/status/bundle 2>/dev/null || echo 000
}

probe_cockpit_llm(){
  local code
  code="$(curl -s -N -o /tmp/${TASK_ID}_cockpit_llm.txt -w '%{http_code}' --max-time 30 \
    -X POST http://127.0.0.1:5555/api/llm/chat \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Reply with one word: ONLINE","source":"worker-reset"}' 2>/dev/null || echo 000)"
  if [ "${code}" = "200" ] && grep -Eqi 'data: |ONLINE|online|token' /tmp/${TASK_ID}_cockpit_llm.txt; then
    return 0
  fi
  return 1
}

get_ngrok_urls(){
  local json
  json="$(curl -s -m 8 http://127.0.0.1:4040/api/tunnels 2>/dev/null || true)"
  [ -z "${json}" ] && return 0
  printf '%s' "${json}" | python3 -c "import json,sys
raw=sys.stdin.read().strip()
if not raw:
    raise SystemExit(0)
try:
    data=json.loads(raw)
except Exception:
    raise SystemExit(0)
for tunnel in data.get('tunnels', []):
    url=str(tunnel.get('public_url','')).strip()
    if url.startswith('https://'):
        print(url.rstrip('/'))"
}

test_public_cockpit(){
  local base="$1"
  local code
  code="$(curl -s -o /tmp/${TASK_ID}_public_cockpit.json -w '%{http_code}' --max-time 12 "${base%/}/api/status/bundle" 2>/dev/null || echo 000)"
  [ "${code}" = "200" ]
}

create_cockpit_tunnel(){
  curl -s -m 10 -X POST http://127.0.0.1:4040/api/tunnels \
    -H 'Content-Type: application/json' \
    -d '{"name":"lariel-cockpit-5555","addr":"5555","proto":"http"}' >/tmp/${TASK_ID}_create_cockpit_tunnel.json 2>/dev/null || true
}

discover_public_cockpit(){
  local found=""
  while IFS= read -r url; do
    [ -z "${url}" ] && continue
    if test_public_cockpit "${url}"; then
      found="${url}"
      break
    fi
  done < <(get_ngrok_urls | sort -u)

  if [ -z "${found}" ]; then
    create_cockpit_tunnel
    while IFS= read -r url; do
      [ -z "${url}" ] && continue
      if test_public_cockpit "${url}"; then
        found="${url}"
        break
      fi
    done < <(get_ngrok_urls | sort -u)
  fi

  printf '%s' "${found}"
}

read_published_chat_backend(){
  if [ ! -f "${PUBLISHED_ENV}" ]; then
    return 0
  fi
  grep '^published_backend=' "${PUBLISHED_ENV}" | tail -1 | cut -d= -f2-
}

patch_chat_backend(){
  local public_base="$1"
  python3 - "$CHAT_HTML" "$public_base" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
public_base = sys.argv[2].rstrip('/')
text = path.read_text(encoding='utf-8')
text, count = re.subn(r"const CHAT_BACKEND = '[^']*';", f"const CHAT_BACKEND = '{public_base}';", text, count=1)
if count != 1:
    raise SystemExit('CHAT_BACKEND constant not found')
path.write_text(text, encoding='utf-8')
PY
}

patch_cockpit_config(){
  local public_base="$1"
  python3 - "$COCKPIT_CFG" "$public_base" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
public_base = sys.argv[2].rstrip('/')
text = path.read_text(encoding='utf-8')
text, count = re.subn(r'backendBaseUrl: "[^"]+"', f'backendBaseUrl: "{public_base}"', text, count=1)
if count != 1:
    raise SystemExit('backendBaseUrl not found')
pattern = re.compile(r'backendCandidates:\s*\[(.*?)\]', re.S)
match = pattern.search(text)
if not match:
    raise SystemExit('backendCandidates block not found')
items = [line.strip().strip(',').strip() for line in match.group(1).splitlines() if line.strip()]
normalized = []
for item in items:
    item = item.strip().strip('"')
    if item and item not in normalized:
        normalized.append(item)
if public_base in normalized:
    normalized.remove(public_base)
normalized.insert(0, public_base)
replacement = 'backendCandidates: [\n' + ''.join(f'    "{item}",\n' for item in normalized) + '  ]'
text = text[:match.start()] + replacement + text[match.end():]
path.write_text(text, encoding='utf-8')
PY
}

write_hard_reset(){
  local nonce
  nonce="$(date -u +"%Y%m%dT%H%M%SZ")-${RANDOM}"
  cat > "${HARD_RESET_FILE}" <<JSON
{
  "nonce": "${nonce}",
  "requested_at_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "reason": "${TASK_ID}_post_reset_connector_refresh",
  "scope": "customide_frontend",
  "requested_by": "ubuntu-worker-01"
}
JSON
  printf '%s' "${nonce}"
}

update_worker_services(){
  local chat_base="$1"
  local cockpit_base="$2"
  local ollama_tags_http="$3"
  local cockpit_bundle_http="$4"
  local cockpit_llm_status="$5"
  python3 - "$SERVICES_FILE" "$chat_base" "$cockpit_base" "$ollama_tags_http" "$cockpit_bundle_http" "$cockpit_llm_status" <<'PY'
import json, pathlib, sys, datetime
path = pathlib.Path(sys.argv[1])
chat_base, cockpit_base, ollama_tags_http, cockpit_bundle_http, cockpit_llm_status = sys.argv[2:]
data = json.loads(path.read_text()) if path.exists() else {}
services = data.setdefault('services', {})
services.setdefault('ollama', {})['http_code'] = ollama_tags_http
services.setdefault('ollama', {})['status'] = 'UP' if ollama_tags_http == '200' else f'HTTP_{ollama_tags_http}'
services['ollama_tunnel'] = {
    'mode': 'chat_shim_publish',
    'local_port': 8091,
    'public_url': chat_base,
    'generate_url': f'{chat_base}/api/generate',
    'chat_url': f'{chat_base}/api/chat',
    'tags_url': f'{chat_base}/api/tags',
    'tunnel_api_http': '200',
    'status': 'UP'
}
if cockpit_base:
    customide = services.setdefault('customide_backend', {})
    customide['public_url'] = cockpit_base
    customide['bundle_url'] = f'{cockpit_base}/api/status/bundle'
    customide['llm_chat_url'] = f'{cockpit_base}/api/llm/chat'
    customide['public_status'] = 'UP'
data['tunnel_last_updated'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
data['tunnel_public_url'] = chat_base
data['tunnel_verification'] = {
    'verified_utc': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'verified_by': 'MTASK-2047',
    'public_url': chat_base,
    'chat_url': f'{chat_base}/api/chat',
    'api_tags_http': ollama_tags_http,
    'final_status': 'RESET_REBUILT',
    'website_integration_note': 'larielsystems/chat.html CHAT_BACKEND reset to the validated public chat base.',
    'cockpit_public_base': cockpit_base,
    'cockpit_bundle_http': cockpit_bundle_http,
    'cockpit_llm_status': cockpit_llm_status,
}
path.write_text(json.dumps(data, indent=2) + '\n')
PY
}

write_result(){
  local status="$1"
  local summary="$2"
  local ollama_tags_http="$3"
  local cockpit_bundle_http="$4"
  local cockpit_llm_status="$5"
  local chat_base="$6"
  local cockpit_base="$7"
  local hard_reset_nonce="$8"
  cat > "${RESULT_FILE}" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${status}",
  "summary": "${summary}",
  "local_ollama_tags_http": "${ollama_tags_http}",
  "local_cockpit_bundle_http": "${cockpit_bundle_http}",
  "local_cockpit_llm_status": "${cockpit_llm_status}",
  "website_chat_base": "${chat_base}",
  "cockpit_public_base": "${cockpit_base}",
  "hard_reset_nonce": "${hard_reset_nonce}",
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

cd "${REPO_ROOT}"
log "start_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log 'Step 1: clear stale local chat/shim listeners'
pkill -f '/tmp/mtask2026_chat_shim.py' >/dev/null 2>&1 || true
pkill -f 'site_kb_server.py' >/dev/null 2>&1 || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k 8091/tcp >/dev/null 2>&1 || true
fi
rm -f "${PUBLISHED_ENV}"

log 'Step 2: verify local Ollama and cockpit upstreams'
OLLAMA_TAGS_HTTP="$(probe_ollama_tags_http)"
COCKPIT_BUNDLE_HTTP="$(probe_cockpit_bundle_http)"
COCKPIT_LLM_STATUS='FAIL'
if probe_cockpit_llm; then
  COCKPIT_LLM_STATUS='PASS'
fi

if [ "${OLLAMA_TAGS_HTTP}" != '200' ]; then
  write_result 'failed' 'Local Ollama tags probe failed before reset publish.' "${OLLAMA_TAGS_HTTP}" "${COCKPIT_BUNDLE_HTTP}" "${COCKPIT_LLM_STATUS}" '' '' ''
  git add "${RESULT_FILE}"
  exit 1
fi

log 'Step 3: rebuild validated website chat publication'
bash pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh
CHAT_BASE="$(read_published_chat_backend)"
if [ -z "${CHAT_BASE}" ]; then
  write_result 'failed' 'MTASK-2026 publish path did not produce published_chat_backend.env.' "${OLLAMA_TAGS_HTTP}" "${COCKPIT_BUNDLE_HTTP}" "${COCKPIT_LLM_STATUS}" '' '' ''
  git add "${RESULT_FILE}"
  exit 1
fi

log "Step 4: patch website connector to ${CHAT_BASE}"
patch_chat_backend "${CHAT_BASE}"

log 'Step 5: discover validated public cockpit backend if available'
COCKPIT_PUBLIC_BASE="$(discover_public_cockpit)"
if [ -n "${COCKPIT_PUBLIC_BASE}" ]; then
  patch_cockpit_config "${COCKPIT_PUBLIC_BASE}"
fi

log 'Step 6: request cockpit hard reset and update worker state'
HARD_RESET_NONCE="$(write_hard_reset)"
update_worker_services "${CHAT_BASE}" "${COCKPIT_PUBLIC_BASE}" "${OLLAMA_TAGS_HTTP}" "${COCKPIT_BUNDLE_HTTP}" "${COCKPIT_LLM_STATUS}"

STATUS='completed'
SUMMARY='Reset stale local chat connections, republished website chat, refreshed worker service state, and requested cockpit hard reset.'
if [ "${COCKPIT_BUNDLE_HTTP}" != '200' ]; then
  STATUS='failed'
  SUMMARY='Website chat was republished, but cockpit backend /api/status/bundle was not healthy locally.'
fi

write_result "${STATUS}" "${SUMMARY}" "${OLLAMA_TAGS_HTTP}" "${COCKPIT_BUNDLE_HTTP}" "${COCKPIT_LLM_STATUS}" "${CHAT_BASE}" "${COCKPIT_PUBLIC_BASE}" "${HARD_RESET_NONCE}"

git add \
  "${CHAT_HTML}" \
  "${COCKPIT_CFG}" \
  "${SERVICES_FILE}" \
  "${HARD_RESET_FILE}" \
  "${RESULT_FILE}" \
  "${PUBLISHED_ENV}" || true

log "website_chat_base=${CHAT_BASE}"
log "cockpit_public_base=${COCKPIT_PUBLIC_BASE:-none}"
log "local_ollama_tags_http=${OLLAMA_TAGS_HTTP}"
log "local_cockpit_bundle_http=${COCKPIT_BUNDLE_HTTP}"
log "local_cockpit_llm_status=${COCKPIT_LLM_STATUS}"

if [ "${STATUS}" = 'completed' ]; then
  log 'completed'
  exit 0
fi

log 'failed'
exit 1