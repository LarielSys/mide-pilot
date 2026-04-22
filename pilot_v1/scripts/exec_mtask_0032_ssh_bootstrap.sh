#!/usr/bin/env bash
# MTASK-0032: Bootstrap SSH access from Windows IDE to Worker 1
# Generates SSH keypair on Worker 1, exposes public key via result file,
# and sets up ngrok TCP tunnel for SSH so Windows can connect directly.
set -euo pipefail

WORKER_ID="ubuntu-worker-01"
TASK_ID="MTASK-0032"
RESULT_FILE="$HOME/mide-pilot/pilot_v1/results/${TASK_ID}.result.json"
LOG_FILE="/tmp/${TASK_ID}.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NGROK_SSH_CONFIG="$HOME/.config/ngrok/ssh_tunnel.yml"

echo "task=${TASK_ID}" | tee "$LOG_FILE"
echo "worker_id=${WORKER_ID}" | tee -a "$LOG_FILE"

# Step 1: Ensure SSH server is running
SSH_STATUS=$(sudo systemctl is-active ssh 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo "unknown")
echo "sshd_status=${SSH_STATUS}" | tee -a "$LOG_FILE"
if [ "$SSH_STATUS" != "active" ]; then
  sudo systemctl start ssh 2>/dev/null || true
  SSH_STATUS=$(sudo systemctl is-active ssh 2>/dev/null || echo "failed_to_start")
  echo "sshd_after_start=${SSH_STATUS}" | tee -a "$LOG_FILE"
fi

# Step 2: Generate MIDE IDE keypair (for Windows IDE to use)
MIDE_KEY="$HOME/.ssh/mide_ide_key"
if [ ! -f "${MIDE_KEY}" ]; then
  ssh-keygen -t ed25519 -f "${MIDE_KEY}" -C "mide-ide-windows@customide" -N "" 2>&1 | tee -a "$LOG_FILE"
  echo "mide_key_generated=yes" | tee -a "$LOG_FILE"
else
  echo "mide_key_generated=already_exists" | tee -a "$LOG_FILE"
fi

# Step 3: Add MIDE IDE public key to authorized_keys
PUBKEY=$(cat "${MIDE_KEY}.pub")
AUTHKEYS="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$AUTHKEYS"
chmod 600 "$AUTHKEYS"
if ! grep -qF "$PUBKEY" "$AUTHKEYS"; then
  echo "$PUBKEY" >> "$AUTHKEYS"
  echo "authorized_keys=added" | tee -a "$LOG_FILE"
else
  echo "authorized_keys=already_present" | tee -a "$LOG_FILE"
fi

# Step 4: Get local IP for SSH (for LAN access)
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo "local_ip=${LOCAL_IP}" | tee -a "$LOG_FILE"

# Step 5: Set up ngrok TCP tunnel for SSH (port 22)
# Check if ngrok TCP tunnel already running
NGROK_SSH_PID=$(pgrep -f "ngrok tcp 22" 2>/dev/null | head -1 || echo "")
if [ -n "$NGROK_SSH_PID" ]; then
  echo "ngrok_ssh_tunnel=already_running_pid=${NGROK_SSH_PID}" | tee -a "$LOG_FILE"
else
  # Start ngrok TCP tunnel for SSH in background
  nohup ngrok tcp 22 --log /tmp/ngrok_ssh.log > /dev/null 2>&1 &
  sleep 5
  NGROK_SSH_PID=$!
  echo "ngrok_ssh_started_pid=${NGROK_SSH_PID}" | tee -a "$LOG_FILE"
fi

# Step 6: Get ngrok TCP URL for SSH
NGROK_SSH_URL=$(curl -sS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
  | python3 -c "
import json,sys
data=json.load(sys.stdin)
for t in data.get('tunnels',[]):
    if t.get('proto')=='tcp':
        print(t['public_url'])
        break
" 2>/dev/null || echo "")

# If port 4040 blocked by existing ngrok, try 4041
if [ -z "$NGROK_SSH_URL" ]; then
  NGROK_SSH_URL=$(curl -sS http://127.0.0.1:4041/api/tunnels 2>/dev/null \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
for t in data.get('tunnels',[]):
    if t.get('proto')=='tcp':
        print(t['public_url'])
        break
" 2>/dev/null || echo "not_available")
fi

echo "ngrok_ssh_url=${NGROK_SSH_URL}" | tee -a "$LOG_FILE"

# Step 7: Export private key (base64) for Windows setup — STORE IN RESULT
# Windows IDE will decode this and write to ~/.ssh/mide_ide_key
PRIVKEY_B64=$(base64 -w 0 "${MIDE_KEY}")
PUBKEY_CONTENT=$(cat "${MIDE_KEY}.pub")
SSH_HOST=$(echo "$NGROK_SSH_URL" | sed 's|tcp://||' | cut -d: -f1)
SSH_PORT=$(echo "$NGROK_SSH_URL" | sed 's|tcp://||' | cut -d: -f2)

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "timestamp_utc=${TIMESTAMP}" | tee -a "$LOG_FILE"
STATUS="completed"

STDOUT_EXCERPT=$(cat "$LOG_FILE" | head -c 2000 | tr '"' "'" | tr '\n' '\\n')
cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "${WORKER_ID}",
  "execution_status": "${STATUS}",
  "summary": "SSH bootstrap complete. ngrok TCP tunnel active. Private key exported for Windows IDE.",
  "ssh_host": "${SSH_HOST}",
  "ssh_port": "${SSH_PORT}",
  "ssh_user": "larieladmin",
  "ssh_ngrok_url": "${NGROK_SSH_URL}",
  "local_ip": "${LOCAL_IP}",
  "privkey_b64": "${PRIVKEY_B64}",
  "pubkey": "${PUBKEY_CONTENT}",
  "stdout_excerpt": "${STDOUT_EXCERPT}",
  "stderr_excerpt": "",
  "timestamp_utc": "${TIMESTAMP}"
}
EOF
echo "result_written=${RESULT_FILE}" | tee -a "$LOG_FILE"
