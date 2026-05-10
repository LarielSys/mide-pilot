#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-2049"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULT_DIR="${REPO_ROOT}/pilot_v1/results"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
CONFIG_DIR="${REPO_ROOT}/pilot_v1/config"
RESULT_FILE="${RESULT_DIR}/${TASK_ID}.result.json"
COMPOSE_FILE="${REPO_ROOT}/pilot_v1/customide/docker-compose.yml"
FRONTEND_CONFIG="${REPO_ROOT}/pilot_v1/customide/frontend/js/config.js"
SERVICES_FILE="${CONFIG_DIR}/worker1_services.json"

mkdir -p "${RESULT_DIR}" "${STATE_DIR}" "${CONFIG_DIR}"

log() { echo "[${TASK_ID}] $*"; }

http_code() {
  local url="$1"
  curl -s -o /tmp/${TASK_ID}_probe.out -w '%{http_code}' --max-time 12 "${url}" 2>/dev/null || echo 000
}

probe_ollama_base() {
  local base="$1"
  local code
  code="$(http_code "${base%/}/api/tags")"
  [ "${code}" = "200" ]
}

ensure_model() {
  local base="$1"
  local model="$2"
  if curl -s --max-time 15 "${base%/}/api/tags" | grep -q "\"${model}\""; then
    return 0
  fi
  log "model_missing=${model}; attempting pull"
  curl -s --max-time 900 -X POST "${base%/}/api/pull" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\",\"stream\":false}" >/tmp/${TASK_ID}_pull_${model//[:\/]/_}.json 2>/dev/null || true
  curl -s --max-time 15 "${base%/}/api/tags" | grep -q "\"${model}\""
}

patch_compose() {
  local base="$1"
  python3 - "$COMPOSE_FILE" "$base" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
base = sys.argv[2].rstrip('/')
text = path.read_text(encoding='utf-8')

text = re.sub(r'CUSTOMIDE_OLLAMA_BASE_URL=.*', f'CUSTOMIDE_OLLAMA_BASE_URL={base}', text)
if 'CUSTOMIDE_OLLAMA_MODEL=' in text:
    text = re.sub(r'CUSTOMIDE_OLLAMA_MODEL=.*', 'CUSTOMIDE_OLLAMA_MODEL=qwen2.5-coder:7b', text)
else:
    text = text.replace('CUSTOMIDE_OLLAMA_BASE_URL=' + base, 'CUSTOMIDE_OLLAMA_BASE_URL=' + base + '\n      - CUSTOMIDE_OLLAMA_MODEL=qwen2.5-coder:7b')

if 'OLLAMA_CHAT_MODEL=' in text:
    text = re.sub(r'OLLAMA_CHAT_MODEL=.*', 'OLLAMA_CHAT_MODEL=qwen2.5-coder:7b', text)

path.write_text(text, encoding='utf-8')
PY
}

patch_frontend_config() {
  python3 - "$FRONTEND_CONFIG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')

text, n1 = re.subn(r'backendBaseUrl:\s*"[^"]+"', 'backendBaseUrl: "http://127.0.0.1:5555"', text, count=1)
if n1 != 1:
    raise SystemExit('backendBaseUrl not found')

text = re.sub(
    r'backendCandidates:\s*\[[^\]]*\]',
    'backendCandidates: [\n    "http://127.0.0.1:5555",\n    "http://localhost:5555"\n  ]',
    text,
    count=1,
    flags=re.S,
)

path.write_text(text, encoding='utf-8')
PY
}

restart_backend() {
  cd "${REPO_ROOT}/pilot_v1/customide"
  docker compose up -d --force-recreate backend >/tmp/${TASK_ID}_compose_backend.log 2>&1 || return 1
  return 0
}

wait_backend_ready() {
  local i
  for i in $(seq 1 30); do
    if [ "$(http_code 'http://127.0.0.1:5555/health')" = "200" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

llm_health_json() {
  curl -s --max-time 20 'http://127.0.0.1:5555/api/llm/health' 2>/dev/null || echo '{}'
}

llm_chat_json() {
  curl -s --max-time 35 -X POST 'http://127.0.0.1:5555/api/llm/chat' \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Reply with CONNECTED","source":"local","model":"qwen2.5-coder:7b"}' 2>/dev/null || echo '{}'
}

update_worker_services() {
  local base="$1"
  local health_json="$2"
  local chat_json="$3"
  python3 - "$SERVICES_FILE" "$base" "$health_json" "$chat_json" <<'PY'
import json
import pathlib
import sys
from datetime import datetime

path = pathlib.Path(sys.argv[1])
base = sys.argv[2]
health = json.loads(sys.argv[3]) if sys.argv[3].strip() else {}
chat = json.loads(sys.argv[4]) if sys.argv[4].strip() else {}

data = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
services = data.setdefault('services', {})
customide = services.setdefault('customide_backend', {})
customide['backend_base'] = 'http://127.0.0.1:5555'
customide['llm_health'] = health
customide['llm_chat_last'] = chat
customide['ollama_base_url'] = base
customide['status'] = 'UP' if not chat.get('degraded', True) else 'DEGRADED'
data['tunnel_last_updated'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY
}

write_result() {
  local status="$1"
  local summary="$2"
  local ollama_base="$3"
  local tags_http="$4"
  local health_json="$5"
  local chat_json="$6"
  cat > "${RESULT_FILE}" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${status}",
  "summary": "${summary}",
  "ollama_base_url": "${ollama_base}",
  "ollama_tags_http": "${tags_http}",
  "llm_health": ${health_json},
  "llm_chat": ${chat_json},
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

cd "${REPO_ROOT}"
log "start_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

OLLAMA_BASE=""
for base in "http://192.168.1.21:11434" "http://127.0.0.1:11434"; do
  if probe_ollama_base "${base}"; then
    OLLAMA_BASE="${base}"
    break
  fi
done

if [ -z "${OLLAMA_BASE}" ]; then
  write_result "failed" "No reachable Ubuntu Ollama endpoint for cockpit backend." "" "000" "{}" "{}"
  git add "${RESULT_FILE}" || true
  exit 1
fi

TAGS_HTTP="$(http_code "${OLLAMA_BASE}/api/tags")"

if ! ensure_model "${OLLAMA_BASE}" "qwen2.5-coder:7b"; then
  write_result "failed" "Required model qwen2.5-coder:7b not available on Ubuntu Ollama." "${OLLAMA_BASE}" "${TAGS_HTTP}" "{}" "{}"
  git add "${RESULT_FILE}" || true
  exit 1
fi

if ! ensure_model "${OLLAMA_BASE}" "qwen2.5vl:7b"; then
  write_result "failed" "Required model qwen2.5vl:7b not available on Ubuntu Ollama." "${OLLAMA_BASE}" "${TAGS_HTTP}" "{}" "{}"
  git add "${RESULT_FILE}" || true
  exit 1
fi

patch_compose "${OLLAMA_BASE}"
patch_frontend_config

if ! restart_backend; then
  write_result "failed" "docker compose backend restart failed while reconnecting cockpit AI." "${OLLAMA_BASE}" "${TAGS_HTTP}" "{}" "{}"
  git add "${RESULT_FILE}" "${COMPOSE_FILE}" "${FRONTEND_CONFIG}" || true
  exit 1
fi

if ! wait_backend_ready; then
  write_result "failed" "Cockpit backend did not become healthy on :5555 after restart." "${OLLAMA_BASE}" "${TAGS_HTTP}" "{}" "{}"
  git add "${RESULT_FILE}" "${COMPOSE_FILE}" "${FRONTEND_CONFIG}" || true
  exit 1
fi

LLM_HEALTH="$(llm_health_json)"
LLM_CHAT="$(llm_chat_json)"

STATUS="completed"
SUMMARY="Cockpit AI reconnected to Ubuntu Ollama and validated via /api/llm/chat."

if ! printf '%s' "${LLM_HEALTH}" | grep -q '"status"'; then
  STATUS="failed"
  SUMMARY="/api/llm/health did not return expected status contract."
fi

if printf '%s' "${LLM_CHAT}" | grep -q '"degraded":true'; then
  STATUS="failed"
  SUMMARY="/api/llm/chat still degraded after cockpit repair."
fi

if ! printf '%s' "${LLM_CHAT}" | grep -qi 'CONNECTED'; then
  STATUS="failed"
  SUMMARY="/api/llm/chat returned but did not contain expected reply proof."
fi

update_worker_services "${OLLAMA_BASE}" "${LLM_HEALTH}" "${LLM_CHAT}"
write_result "${STATUS}" "${SUMMARY}" "${OLLAMA_BASE}" "${TAGS_HTTP}" "${LLM_HEALTH}" "${LLM_CHAT}"

git add \
  "${COMPOSE_FILE}" \
  "${FRONTEND_CONFIG}" \
  "${SERVICES_FILE}" \
  "${RESULT_FILE}" || true

if [ "${STATUS}" = "completed" ]; then
  log 'completed'
  exit 0
fi

log 'failed'
exit 1