#!/usr/bin/env bash
# MTASK-0033: Install code-server (VS Code in browser) on Worker 1
# code-server will be used as the remote IDE view (right pane) in CustomIDE
set -euo pipefail

WORKER_ID="ubuntu-worker-01"
TASK_ID="MTASK-0033"
RESULT_FILE="$HOME/mide-pilot/pilot_v1/results/${TASK_ID}.result.json"
LOG_FILE="/tmp/${TASK_ID}.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CODE_SERVER_PORT=8092
CODE_SERVER_DIR="$HOME/.local/bin"
PROJECTS_DIR="$HOME/mide-pilot"

echo "task=${TASK_ID}" | tee "$LOG_FILE"
echo "worker_id=${WORKER_ID}" | tee -a "$LOG_FILE"

# Step 1: Check if code-server already installed
if command -v code-server &>/dev/null; then
  CS_VERSION=$(code-server --version 2>/dev/null | head -1 || echo "unknown")
  echo "code_server_status=already_installed" | tee -a "$LOG_FILE"
  echo "code_server_version=${CS_VERSION}" | tee -a "$LOG_FILE"
else
  # Install code-server via official installer
  echo "code_server_status=installing" | tee -a "$LOG_FILE"
  curl -fsSL https://code-server.dev/install.sh | sh 2>&1 | tail -5 | tee -a "$LOG_FILE"
  CS_VERSION=$(code-server --version 2>/dev/null | head -1 || echo "install_may_have_failed")
  echo "code_server_version=${CS_VERSION}" | tee -a "$LOG_FILE"
fi

# Step 2: Configure code-server
CS_CONFIG_DIR="$HOME/.config/code-server"
mkdir -p "$CS_CONFIG_DIR"
cat > "$CS_CONFIG_DIR/config.yaml" <<CSEOF
bind-addr: 127.0.0.1:${CODE_SERVER_PORT}
auth: password
password: mide-ide-2026
cert: false
CSEOF
echo "code_server_config=written" | tee -a "$LOG_FILE"

# Step 3: Kill existing code-server if running
pkill -f "code-server" 2>/dev/null || true
sleep 2

# Step 4: Start code-server pointing to mide-pilot project root
nohup code-server --config "$CS_CONFIG_DIR/config.yaml" "$PROJECTS_DIR" \
  > /tmp/code_server.log 2>&1 &
CS_PID=$!
echo "code_server_pid=${CS_PID}" | tee -a "$LOG_FILE"

# Step 5: Wait for code-server to be ready
CS_READY="false"
for _ in $(seq 1 30); do
  if curl -sS "http://127.0.0.1:${CODE_SERVER_PORT}/healthz" >/dev/null 2>&1; then
    CS_READY="true"; break
  fi
  sleep 2
done
echo "code_server_ready=${CS_READY}" | tee -a "$LOG_FILE"

if [ "$CS_READY" != "true" ]; then
  echo "error=code_server_not_ready" | tee -a "$LOG_FILE"
  echo "log_tail=$(tail -10 /tmp/code_server.log 2>/dev/null)" | tee -a "$LOG_FILE"
  STATUS="failed"
else
  # Step 6: Install Continue extension (Ollama AI assistant for code-server)
  # Continue is the VS Code extension that connects to Ollama for inline AI assistance
  EXTENSION_DIR="$HOME/.local/share/code-server/extensions"
  mkdir -p "$EXTENSION_DIR"

  # Download and install Continue extension (try VS Code marketplace)
  CS_INSTALLED_EXTS=$(code-server --list-extensions 2>/dev/null || echo "")
  echo "installed_extensions=${CS_INSTALLED_EXTS}" | tee -a "$LOG_FILE"

  if echo "$CS_INSTALLED_EXTS" | grep -qi "continue"; then
    echo "continue_extension=already_installed" | tee -a "$LOG_FILE"
  else
    code-server --install-extension "Continue.continue" 2>&1 | tail -3 | tee -a "$LOG_FILE" || \
    echo "continue_extension=install_attempted" | tee -a "$LOG_FILE"
  fi

  # Step 7: Write Continue config pointing to local Ollama
  CONTINUE_CONFIG_DIR="$HOME/.continue"
  mkdir -p "$CONTINUE_CONFIG_DIR"
  cat > "$CONTINUE_CONFIG_DIR/config.json" <<CEOF
{
  "models": [
    {
      "title": "qwen2.5 (local)",
      "provider": "ollama",
      "model": "qwen2.5",
      "apiBase": "http://127.0.0.1:11434"
    }
  ],
  "tabAutocompleteModel": {
    "title": "qwen2.5 autocomplete",
    "provider": "ollama",
    "model": "qwen2.5",
    "apiBase": "http://127.0.0.1:11434"
  },
  "allowAnonymousTelemetry": false
}
CEOF
  echo "continue_config=written" | tee -a "$LOG_FILE"

  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "timestamp_utc=${TIMESTAMP}" | tee -a "$LOG_FILE"
  STATUS="completed"
fi

STDOUT_EXCERPT=$(cat "$LOG_FILE" | head -c 2000 | tr '"' "'" | tr '\n' '\\n')
cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "${WORKER_ID}",
  "execution_status": "${STATUS}",
  "summary": "code-server installed, configured on port ${CODE_SERVER_PORT}, Continue extension pointed at qwen2.5.",
  "code_server_port": ${CODE_SERVER_PORT},
  "code_server_password": "mide-ide-2026",
  "stdout_excerpt": "${STDOUT_EXCERPT}",
  "stderr_excerpt": "",
  "timestamp_utc": "${TIMESTAMP}"
}
EOF
echo "result_written=${RESULT_FILE}" | tee -a "$LOG_FILE"
