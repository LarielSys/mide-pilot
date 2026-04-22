#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
NGROK_PORT="${NGROK_PORT:-8091}"
NGROK_TUNNEL_NAME="${NGROK_TUNNEL_NAME:-site-kb}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_NAME="ngrok-site-kb.service"
SERVICE_PATH="${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
NGROK_BIN="$(command -v ngrok || true)"

if [[ -z "${NGROK_BIN}" ]]; then
  echo "error=ngrok_not_found"
  exit 1
fi

mkdir -p "${SYSTEMD_USER_DIR}"

echo "task=TASK-0025"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "ngrok_bin=${NGROK_BIN}"
echo "service_path=${SERVICE_PATH}"

echo "[Unit]" >"${SERVICE_PATH}"
echo "Description=ngrok tunnel for site_kb_server" >>"${SERVICE_PATH}"
echo "After=network-online.target" >>"${SERVICE_PATH}"
echo "Wants=network-online.target" >>"${SERVICE_PATH}"
echo >>"${SERVICE_PATH}"
echo "[Service]" >>"${SERVICE_PATH}"
echo "Type=simple" >>"${SERVICE_PATH}"
echo "ExecStart=${NGROK_BIN} http ${NGROK_PORT}" >>"${SERVICE_PATH}"
echo "Restart=always" >>"${SERVICE_PATH}"
echo "RestartSec=5" >>"${SERVICE_PATH}"
echo >>"${SERVICE_PATH}"
echo "[Install]" >>"${SERVICE_PATH}"
echo "WantedBy=default.target" >>"${SERVICE_PATH}"

systemctl --user daemon-reload
systemctl --user enable "${SERVICE_NAME}" >/dev/null
systemctl --user restart "${SERVICE_NAME}"

if command -v loginctl >/dev/null 2>&1; then
  if loginctl show-user "${USER}" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
    echo "linger_status=already_enabled"
  else
    if sudo -n loginctl enable-linger "${USER}" >/dev/null 2>&1; then
      echo "linger_status=enabled"
    else
      echo "linger_status=not_enabled_no_passwordless_sudo"
    fi
  fi
fi

sleep 4
systemctl_state="$(systemctl --user is-active "${SERVICE_NAME}" || true)"
echo "service_name=${SERVICE_NAME}"
echo "service_state=${systemctl_state}"

if [[ "${systemctl_state}" != "active" ]]; then
  echo "error=ngrok_service_not_active"
  systemctl --user status "${SERVICE_NAME}" --no-pager || true
  exit 1
fi

public_url=""
for _ in 1 2 3 4 5 6 7 8; do
  public_url="$(curl -sS http://127.0.0.1:4040/api/tunnels | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("tunnels",[]); print(t[0].get("public_url","") if t else "")' || true)"
  if [[ -n "${public_url}" ]]; then
    break
  fi
  sleep 2
done

echo "ngrok_tunnel_name=${NGROK_TUNNEL_NAME}"
echo "ngrok_port=${NGROK_PORT}"
echo "ngrok_public_url=${public_url}"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ -z "${public_url}" ]]; then
  echo "error=public_url_not_detected"
  exit 1
fi
