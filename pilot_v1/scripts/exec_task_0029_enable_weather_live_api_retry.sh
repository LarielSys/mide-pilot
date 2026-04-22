#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
SITE_SERVER="${HOME}/Documents/itheia-llm/site_kb_server.py"
SITE_DIR="$(dirname "${SITE_SERVER}")"
PORT="8091"
LOG_FILE="/tmp/site_kb_server.log"

if [[ ! -f "${SITE_SERVER}" ]]; then
  echo "error=site_server_not_found"
  echo "expected=${SITE_SERVER}"
  exit 1
fi

echo "task=MTASK-0029"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "site_server=${SITE_SERVER}"

python3 -m py_compile "${SITE_SERVER}"
echo "syntax_check=passed"

restart_mode=""
if systemctl --user list-unit-files 2>/dev/null | grep -q "site-kb-server.service"; then
  systemctl --user restart site-kb-server.service
  restart_mode="systemd-user-site-kb-server"
else
  if pgrep -f "site_kb_server.py" >/dev/null 2>&1; then
    pkill -f "site_kb_server.py" || true
    sleep 2
  fi
  cd "${SITE_DIR}"
  nohup python3 "${SITE_SERVER}" >"${LOG_FILE}" 2>&1 &
  restart_mode="nohup"
fi
echo "restart_mode=${restart_mode}"

wait_ok="false"
for _ in $(seq 1 40); do
  if curl -sS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    wait_ok="true"
    break
  fi
  sleep 2
done

if [[ "${wait_ok}" != "true" ]]; then
  echo "error=base_health_not_ready"
  echo "log_tail=$(tail -n 40 "${LOG_FILE}" 2>/dev/null | tr '\n' ';')"
  exit 1
fi

weather_ok="false"
for _ in $(seq 1 20); do
  if curl -sS "http://127.0.0.1:${PORT}/api/weather/health" >/dev/null 2>&1; then
    weather_ok="true"
    break
  fi
  sleep 1
done

if [[ "${weather_ok}" != "true" ]]; then
  echo "error=weather_health_not_ready"
  echo "log_tail=$(tail -n 40 "${LOG_FILE}" 2>/dev/null | tr '\n' ';')"
  exit 1
fi

health_json="$(curl -sS "http://127.0.0.1:${PORT}/api/weather/health")"
compare_json="$(curl -sS -H "Content-Type: application/json" -d '{"city_a":"San Diego","city_b":"New York City","units":"metric"}' "http://127.0.0.1:${PORT}/api/weather/compare")"

echo "local_health=${health_json}"
echo "local_compare_excerpt=$(echo "${compare_json}" | head -c 240)"

public_url="$(curl -sS http://127.0.0.1:4040/api/tunnels | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("tunnels",[]); print(t[0].get("public_url","") if t else "")' || true)"
if [[ -n "${public_url}" ]]; then
  echo "public_base=${public_url}"
  pub_health="$(curl -sS "${public_url}/api/weather/health" || true)"
  echo "public_health=${pub_health}"
fi

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
