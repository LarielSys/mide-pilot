#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-0097"
CODE_SERVER_PORT=8092
CS_PASSWORD="mide-ide-2026"
PROJECT_ROOT="/home/larieladmin/mide-pilot"
CS_CONFIG_DIR="$HOME/.config/code-server"
LOG_FILE="/tmp/${TASK_ID}.log"

echo "task=${TASK_ID}"
echo "objective=install_and_start_code_server"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Step 1: Install via standalone method
if command -v code-server &>/dev/null; then
  CS_VERSION=$(code-server --version 2>/dev/null | head -1 || echo "unknown")
  echo "code_server_already_installed=${CS_VERSION}"
else
  echo "code_server_status=installing"
  curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone 2>&1 | tail -10 | tee "$LOG_FILE"
  # Add to PATH for this session
  export PATH="$HOME/.local/bin:$PATH"
  CS_VERSION=$(code-server --version 2>/dev/null | head -1 || echo "install_may_have_failed")
  echo "code_server_installed_version=${CS_VERSION}"
fi

# Ensure PATH includes standalone install location
export PATH="$HOME/.local/bin:$PATH"

if ! command -v code-server &>/dev/null; then
  echo "code_server_status=FAIL_BINARY_NOT_FOUND_AFTER_INSTALL"
  exit 1
fi

# Step 2: Write config
mkdir -p "${CS_CONFIG_DIR}"
cat > "${CS_CONFIG_DIR}/config.yaml" <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: ${CS_PASSWORD}
cert: false
EOF
echo "config_written=${CS_CONFIG_DIR}/config.yaml"

# Step 3: Kill any stale process
pkill -f "code-server" 2>/dev/null && echo "killed_existing=true" || echo "killed_existing=none"
sleep 2

# Step 4: Start detached
nohup code-server --config "${CS_CONFIG_DIR}/config.yaml" "${PROJECT_ROOT}" \
  > /tmp/code_server_${TASK_ID}.log 2>&1 &
CS_PID=$!
echo "code_server_pid=${CS_PID}"

# Step 5: Wait for ready (up to 60s)
CS_READY="false"
for i in $(seq 1 15); do
  sleep 4
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${CODE_SERVER_PORT} 2>/dev/null || echo "000")
  echo "health_check_${i}=${HTTP}"
  if [[ "$HTTP" == "200" || "$HTTP" == "302" || "$HTTP" == "401" ]]; then
    CS_READY="true"
    break
  fi
done

echo "code_server_ready=${CS_READY}"

if [[ "$CS_READY" == "true" ]]; then
  echo "code_server_status=UP"
else
  echo "code_server_status=FAIL"
  echo "log_tail=$(tail -15 /tmp/code_server_${TASK_ID}.log 2>/dev/null || echo none)"
  exit 1
fi

echo "install_and_start=complete"
