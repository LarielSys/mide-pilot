#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

TASK_ID="MTASK-2046"
TARGET_COMMIT="599c13081"
PUBLIC_CHAT_URL="https://jawed-lapel-dispersed.ngrok-free.dev/api/chat"
UBUNTU_OLLAMA_TAGS="http://192.168.1.21:11434/api/tags"
LOCAL_HEALTH_URL="http://127.0.0.1:8091/health"
LOCAL_CHAT_URL="http://127.0.0.1:8091/api/chat"

log() { echo "[${TASK_ID}] $*"; }

probe_public_chat() {
  local code
  code="$(curl -sS -m 20 -o /tmp/${TASK_ID}_public_chat.json -w '%{http_code}' \
    -X POST "${PUBLIC_CHAT_URL}" \
    -H 'Content-Type: application/json' \
    -H 'Origin: https://larielsystems.com' \
    -H 'ngrok-skip-browser-warning: true' \
    -d '{"message":"hello","session_id":null}' || true)"
  [ "${code}" = "200" ]
}

probe_local_health() {
  local code
  code="$(curl -sS -m 10 -o /tmp/${TASK_ID}_local_health.json -w '%{http_code}' "${LOCAL_HEALTH_URL}" || true)"
  [ "${code}" = "200" ]
}

probe_local_chat() {
  local code
  code="$(curl -sS -m 15 -o /tmp/${TASK_ID}_local_chat.json -w '%{http_code}' \
    -X POST "${LOCAL_CHAT_URL}" \
    -H 'Content-Type: application/json' \
    -d '{"message":"hello","session_id":null}' || true)"
  [ "${code}" = "200" ]
}

probe_ubuntu_ollama() {
  local code
  code="$(curl -sS -m 10 -o /tmp/${TASK_ID}_ollama_tags.json -w '%{http_code}' "${UBUNTU_OLLAMA_TAGS}" || true)"
  [ "${code}" = "200" ]
}

report_probe_status() {
  local name="$1"
  local func="$2"
  if "${func}"; then
    log "${name}=PASS"
  else
    log "${name}=FAIL"
  fi
}

log "start_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log "repo_root=${REPO_ROOT}"
log "target_commit=${TARGET_COMMIT}"

report_probe_status "pre_public_chat" probe_public_chat
report_probe_status "pre_local_health" probe_local_health
report_probe_status "pre_local_chat" probe_local_chat
report_probe_status "pre_ubuntu_ollama_tags" probe_ubuntu_ollama

if probe_public_chat && probe_local_health && probe_local_chat && probe_ubuntu_ollama; then
  log "already_healthy=true"
  log "result=PASS"
  exit 0
fi

log "restoring_known_good_files_from_commit=${TARGET_COMMIT}"
git checkout "${TARGET_COMMIT}" -- \
  pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh \
  pilot_v1/customide/frontend/js/config.js \
  pilot_v1/customide/docker-compose.yml \
  pilot_v1/state/worker1_services.json || true

if [ -f pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh ]; then
  chmod +x pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh || true
  log "running_exec_mtask_2026_chat_shim_publish"
  bash pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh || true
fi

report_probe_status "post_public_chat" probe_public_chat
report_probe_status "post_local_health" probe_local_health
report_probe_status "post_local_chat" probe_local_chat
report_probe_status "post_ubuntu_ollama_tags" probe_ubuntu_ollama

if probe_public_chat && probe_local_health && probe_local_chat && probe_ubuntu_ollama; then
  log "result=PASS"
  exit 0
fi

log "result=FAIL"
exit 2
