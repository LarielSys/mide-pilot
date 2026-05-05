#!/usr/bin/env bash
set -euo pipefail

CODE_SERVER_PORT=8092
CS_PASSWORD="mide-ide-2026"
PROJECT_ROOT="/home/larieladmin/mide-pilot"
CS_CONFIG_DIR="$HOME/.config/code-server"
CS_CONFIG_FILE="${CS_CONFIG_DIR}/config.yaml"
LOG_FILE="/tmp/code-server-mtask0096.log"

echo "task=MTASK-0096"
echo "objective=restart_code_server"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Check if code-server is installed
if ! command -v code-server &>/dev/null; then
  echo "code_server_installed=false"
  echo "status=FAIL_NOT_INSTALLED"
  exit 1
fi

CS_VERSION=$(code-server --version 2>/dev/null | head -1 || echo "unknown")
echo "code_server_installed=true"
echo "code_server_version=${CS_VERSION}"

# Kill any existing stale process
pkill -f "code-server" 2>/dev/null && echo "killed_existing=true" || echo "killed_existing=none"
sleep 2

# Ensure config dir and config file
mkdir -p "${CS_CONFIG_DIR}"
cat > "${CS_CONFIG_FILE}" <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: ${CS_PASSWORD}
cert: false
EOF
echo "config_written=${CS_CONFIG_FILE}"

# Start code-server detached
nohup code-server --config "${CS_CONFIG_FILE}" "${PROJECT_ROOT}" \
  > "${LOG_FILE}" 2>&1 &
CS_PID=$!
echo "code_server_pid=${CS_PID}"
sleep 4

# Verify it came up
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${CODE_SERVER_PORT} 2>/dev/null || echo "000")
echo "code_server_port${CODE_SERVER_PORT}=${HTTP_STATUS}"

if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "302" || "$HTTP_STATUS" == "401" ]]; then
  echo "code_server_status=UP"
else
  echo "code_server_status=FAIL_HTTP_${HTTP_STATUS}"
  echo "last_log_lines=$(tail -10 ${LOG_FILE} 2>/dev/null || echo none)"
fi

echo "restart=complete"
