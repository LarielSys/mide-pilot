#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-2050"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULT_DIR="${REPO_ROOT}/pilot_v1/results"
CONFIG_DIR="${REPO_ROOT}/pilot_v1/config"
RESULT_FILE="${RESULT_DIR}/${TASK_ID}.result.json"
COMPOSE_FILE="${REPO_ROOT}/pilot_v1/customide/docker-compose.yml"
FRONTEND_CONFIG="${REPO_ROOT}/pilot_v1/customide/frontend/js/config.js"
SERVICES_FILE="${CONFIG_DIR}/worker1_services.json"

mkdir -p "${RESULT_DIR}" "${CONFIG_DIR}"

http_code() {
  local url="$1"
  curl -s -o /tmp/${TASK_ID}_probe.out -w '%{http_code}' --max-time 12 "${url}" 2>/dev/null || echo 000
}

first_reachable_ollama() {
  local candidate code
  for candidate in "http://192.168.1.21:11434" "http://127.0.0.1:11434"; do
    code="$(http_code "${candidate}/api/tags")"
    if [ "${code}" = "200" ]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

pick_model() {
  local base="$1"
  local tags
  tags="$(curl -s --max-time 15 "${base}/api/tags" 2>/dev/null || true)"
  for model in "qwen2.5-coder:7b" "qwen2.5:14b" "qwen2.5:7b"; do
    if printf '%s' "${tags}" | grep -q "\"${model}\""; then
      echo "${model}"
      return 0
    fi
  done
  echo "qwen2.5-coder:7b"
}

patch_compose() {
  local base="$1"
  local model="$2"
  python3 - "$COMPOSE_FILE" "$base" "$model" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
base = sys.argv[2].rstrip('/')
model = sys.argv[3]
text = path.read_text(encoding='utf-8')

text = re.sub(r'CUSTOMIDE_OLLAMA_BASE_URL=.*', f'CUSTOMIDE_OLLAMA_BASE_URL={base}', text)
if 'CUSTOMIDE_OLLAMA_MODEL=' in text:
    text = re.sub(r'CUSTOMIDE_OLLAMA_MODEL=.*', f'CUSTOMIDE_OLLAMA_MODEL={model}', text)
else:
    text = text.replace('CUSTOMIDE_OLLAMA_BASE_URL=' + base, 'CUSTOMIDE_OLLAMA_BASE_URL=' + base + f'\n      - CUSTOMIDE_OLLAMA_MODEL={model}')

if 'OLLAMA_BASE_URL=' in text:
    text = re.sub(r'OLLAMA_BASE_URL=.*', f'OLLAMA_BASE_URL={base}', text)
if 'OLLAMA_CHAT_MODEL=' in text:
    text = re.sub(r'OLLAMA_CHAT_MODEL=.*', f'OLLAMA_CHAT_MODEL={model}', text)

path.write_text(text, encoding='utf-8')
PY
}

patch_frontend() {
  python3 - "$FRONTEND_CONFIG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
text, n = re.subn(r'backendBaseUrl:\s*"[^"]+"', 'backendBaseUrl: "http://127.0.0.1:5555"', text, count=1)
if n != 1:
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
  docker compose up -d --force-recreate backend >/tmp/${TASK_ID}_backend_restart.log 2>&1
}

wait_backend() {
  local i
  for i in $(seq 1 40); do
    if [ "$(http_code "http://127.0.0.1:5555/health")" = "200" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

llm_health() {
  curl -s --max-time 20 "http://127.0.0.1:5555/api/llm/health" 2>/dev/null || echo '{}'
}

llm_chat() {
  local model="$1"
  curl -s --max-time 35 -X POST "http://127.0.0.1:5555/api/llm/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"Reply with COCKPIT_OK\",\"source\":\"local\",\"model\":\"${model}\"}" 2>/dev/null || echo '{}'
}

write_result() {
  local status="$1" summary="$2" base="$3" model="$4" health="$5" chat="$6"
  cat > "${RESULT_FILE}" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "${status}",
  "summary": "${summary}",
  "ollama_base_url": "${base}",
  "model_used": "${model}",
  "llm_health": ${health},
  "llm_chat": ${chat},
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

BASE="$(first_reachable_ollama || true)"
if [ -z "${BASE}" ]; then
  write_result "failed" "No reachable Ollama /api/tags endpoint for cockpit recovery." "" "" "{}" "{}"
  git add "${RESULT_FILE}" || true
  exit 1
fi

MODEL="$(pick_model "${BASE}")"

patch_compose "${BASE}" "${MODEL}"
patch_frontend

if ! restart_backend; then
  write_result "failed" "Backend restart failed in docker compose." "${BASE}" "${MODEL}" "{}" "{}"
  git add "${RESULT_FILE}" "${COMPOSE_FILE}" "${FRONTEND_CONFIG}" || true
  exit 1
fi

if ! wait_backend; then
  write_result "failed" "Backend health on :5555 did not recover after restart." "${BASE}" "${MODEL}" "{}" "{}"
  git add "${RESULT_FILE}" "${COMPOSE_FILE}" "${FRONTEND_CONFIG}" || true
  exit 1
fi

HEALTH="$(llm_health)"
CHAT="$(llm_chat "${MODEL}")"

STATUS="completed"
SUMMARY="Cockpit AI connected to Ollama and /api/llm/chat is non-degraded."

if ! printf '%s' "${HEALTH}" | grep -q '"status"'; then
  STATUS="failed"
  SUMMARY="/api/llm/health did not return expected status contract."
fi
if printf '%s' "${CHAT}" | grep -q '"degraded":true'; then
  STATUS="failed"
  SUMMARY="/api/llm/chat still degraded after recovery actions."
fi
if ! printf '%s' "${CHAT}" | grep -qi 'COCKPIT_OK'; then
  STATUS="failed"
  SUMMARY="/api/llm/chat response proof token missing."
fi

python3 - "$SERVICES_FILE" "$BASE" "$MODEL" "$HEALTH" "$CHAT" <<'PY'
import json
import pathlib
import sys
from datetime import datetime

path = pathlib.Path(sys.argv[1])
base = sys.argv[2]
model = sys.argv[3]
health = json.loads(sys.argv[4]) if sys.argv[4].strip() else {}
chat = json.loads(sys.argv[5]) if sys.argv[5].strip() else {}

data = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
services = data.setdefault('services', {})
cb = services.setdefault('customide_backend', {})
cb['backend_base'] = 'http://127.0.0.1:5555'
cb['ollama_base_url'] = base
cb['model'] = model
cb['llm_health'] = health
cb['llm_chat_last'] = chat
cb['status'] = 'UP' if not chat.get('degraded', True) else 'DEGRADED'
data['tunnel_last_updated'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY

write_result "${STATUS}" "${SUMMARY}" "${BASE}" "${MODEL}" "${HEALTH}" "${CHAT}"

git add "${COMPOSE_FILE}" "${FRONTEND_CONFIG}" "${SERVICES_FILE}" "${RESULT_FILE}" || true

if [ "${STATUS}" = "completed" ]; then
  exit 0
fi
exit 1