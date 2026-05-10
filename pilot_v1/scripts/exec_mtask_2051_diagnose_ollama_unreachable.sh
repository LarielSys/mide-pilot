#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-2051"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULT_DIR="${REPO_ROOT}/pilot_v1/results"
RESULT_FILE="${RESULT_DIR}/${TASK_ID}.result.json"

mkdir -p "${RESULT_DIR}"

safe_cmd() {
  local cmd="$1"
  bash -lc "${cmd}" 2>&1 || true
}

http_code() {
  local url="$1"
  curl -s -o /tmp/${TASK_ID}_probe.out -w '%{http_code}' --max-time 10 "${url}" 2>/dev/null || echo 000
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

LOCALHOST_TAGS_HTTP="$(http_code 'http://127.0.0.1:11434/api/tags')"
LAN_IP="$(safe_cmd "hostname -I | awk '{print \$1}'" | tr -d '\n')"
if [ -z "${LAN_IP}" ]; then
  LAN_IP="192.168.1.21"
fi
LAN_TAGS_HTTP="$(http_code "http://${LAN_IP}:11434/api/tags")"

OLLAMA_SYSTEMD_STATUS="$(safe_cmd 'systemctl is-active ollama')"
OLLAMA_USER_STATUS="$(safe_cmd 'systemctl --user is-active ollama')"
LISTEN_11434="$(safe_cmd 'ss -lntp | grep 11434')"
DOCKER_PS_OLLAMA="$(safe_cmd "docker ps --format '{{.Names}} {{.Status}} {{.Ports}}' | grep -i ollama")"
IPTABLES_SNIPPET="$(safe_cmd 'sudo iptables -S 2>/dev/null | head -n 80')"
UFW_STATUS="$(safe_cmd 'sudo ufw status 2>/dev/null | head -n 40')"
LOCAL_TAGS_BODY="$(safe_cmd 'curl -s --max-time 12 http://127.0.0.1:11434/api/tags | head -c 4000')"
LAN_TAGS_BODY="$(safe_cmd "curl -s --max-time 12 http://${LAN_IP}:11434/api/tags | head -c 4000")"

FAIL_LAYER="unknown"
SUMMARY="Ollama diagnostics collected."

if [ "${OLLAMA_SYSTEMD_STATUS}" != "active" ] && [ "${OLLAMA_USER_STATUS}" != "active" ] && [ -z "${DOCKER_PS_OLLAMA}" ]; then
  FAIL_LAYER="service_not_running"
  SUMMARY="No active Ollama systemd service or Ollama container detected."
elif [ -z "${LISTEN_11434}" ]; then
  FAIL_LAYER="port_not_listening"
  SUMMARY="Ollama service/container exists but port 11434 is not listening."
elif [ "${LOCALHOST_TAGS_HTTP}" != "200" ]; then
  FAIL_LAYER="localhost_api_unreachable"
  SUMMARY="Port 11434 is listening but localhost Ollama API /api/tags is not returning 200."
elif [ "${LAN_TAGS_HTTP}" != "200" ]; then
  FAIL_LAYER="lan_path_blocked"
  SUMMARY="Localhost API is reachable but LAN IP API is blocked or unroutable."
elif ! printf '%s' "${LOCAL_TAGS_BODY}" | grep -qi 'qwen2.5'; then
  FAIL_LAYER="model_not_present"
  SUMMARY="Ollama API reachable but expected qwen model tags were not found."
else
  FAIL_LAYER="no_ollama_connectivity_failure_detected"
  SUMMARY="Ollama API appears reachable on localhost and LAN with qwen tags present; cockpit failure is likely downstream config/routing."
fi

cat > "${RESULT_FILE}" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "ubuntu-worker-01",
  "execution_status": "completed",
  "summary": ${SUMMARY@Q},
  "diagnosis": {
    "failing_layer": ${FAIL_LAYER@Q},
    "localhost_tags_http": ${LOCALHOST_TAGS_HTTP@Q},
    "lan_ip": ${LAN_IP@Q},
    "lan_tags_http": ${LAN_TAGS_HTTP@Q},
    "systemd_ollama": ${OLLAMA_SYSTEMD_STATUS@Q},
    "user_systemd_ollama": ${OLLAMA_USER_STATUS@Q}
  },
  "evidence": {
    "listen_11434": $(printf '%s' "${LISTEN_11434}" | json_escape),
    "docker_ps_ollama": $(printf '%s' "${DOCKER_PS_OLLAMA}" | json_escape),
    "localhost_tags_body": $(printf '%s' "${LOCAL_TAGS_BODY}" | json_escape),
    "lan_tags_body": $(printf '%s' "${LAN_TAGS_BODY}" | json_escape),
    "ufw_status": $(printf '%s' "${UFW_STATUS}" | json_escape),
    "iptables_snippet": $(printf '%s' "${IPTABLES_SNIPPET}" | json_escape)
  },
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

git add "${RESULT_FILE}" || true
exit 0