#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
CLONE_DOMAIN_ROOT="${HOME}/mide-pilot/clone/larielsystems/larielsystems.com"
PORT="8787"
URL="http://127.0.0.1:${PORT}/"
OPEN_SCRIPT="${HOME}/mide-pilot/pilot_v1/scripts/open_worker_target.sh"

if [[ ! -f "${OPEN_SCRIPT}" ]]; then
  echo "error=open_script_missing"
  echo "expected=${OPEN_SCRIPT}"
  exit 1
fi

if [[ ! -d "${CLONE_DOMAIN_ROOT}" ]]; then
  echo "error=clone_root_missing"
  echo "expected=${CLONE_DOMAIN_ROOT}"
  exit 1
fi

echo "task=TASK-0023"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "clone_domain_root=${CLONE_DOMAIN_ROOT}"
echo "localhost_url=${URL}"

python3 -m http.server "${PORT}" --directory "${CLONE_DOMAIN_ROOT}" >/tmp/mide_task_0023_http.log 2>&1 &
HTTP_PID=$!

cleanup() {
  if ps -p "${HTTP_PID}" >/dev/null 2>&1; then
    kill "${HTTP_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${OPEN_SCRIPT}" open-url "${URL}" --wait-http-seconds=30

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "browser_open_request=sent"
