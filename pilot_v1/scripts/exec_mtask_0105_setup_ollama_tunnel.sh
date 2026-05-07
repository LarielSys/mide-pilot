#!/usr/bin/env bash
set -euo pipefail

echo task=MTASK-0105
echo objective=setup_persistent_ollama_ngrok_tunnel_for_website
echo timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="${REPO_ROOT}/pilot_v1/state/worker1_services.json"

# ── 1. Determine Ollama target port ──────────────────────────────────────────
# Check Docker first, fall back to native 11434
DOCKER_PORT=$(docker ps --format "{{.Ports}}" 2>/dev/null \
  | grep -oP '0\.0\.0\.0:\K\d+(?=->11434)' | head -1 || echo "")

if [[ -n "$DOCKER_PORT" ]]; then
  OLLAMA_LOCAL_PORT="$DOCKER_PORT"
  OLLAMA_MODE="docker"
  echo ollama_mode=docker
  echo ollama_docker_mapped_port="$DOCKER_PORT"
else
  # Verify native Ollama responds
  NATIVE_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:11434 2>/dev/null || echo "000")
  if [[ "$NATIVE_CHECK" == "200" ]]; then
    OLLAMA_LOCAL_PORT="11434"
    OLLAMA_MODE="native"
    echo ollama_mode=native
  else
    echo ollama_mode=unavailable
    echo ollama_port11434_status="$NATIVE_CHECK"
    echo "ERROR: Ollama not reachable on port 11434 and no Docker container found."
    echo snapshot=complete
    exit 1
  fi
fi

echo ollama_local_port="$OLLAMA_LOCAL_PORT"

# ── 2. Stop any existing ngrok processes ─────────────────────────────────────
echo "--- stopping_existing_ngrok ---"
pkill -f ngrok 2>/dev/null && echo ngrok_killed=yes || echo ngrok_killed=none
sleep 3

# Check for ngrok auth token (required for stable tunnels)
NGROK_TOKEN=$(cat "$HOME/.ngrok_token" 2>/dev/null || \
              ngrok config check 2>/dev/null | grep -i authtoken | awk '{print $2}' || echo "")
if [[ -n "$NGROK_TOKEN" ]]; then
  echo ngrok_token_found=yes
else
  echo ngrok_token_found=no
  echo "WARNING: No ngrok authtoken found. Tunnel will use anonymous free tier (limited)."
fi

# ── 3. Start ngrok tunnel for Ollama ─────────────────────────────────────────
echo "--- starting_ngrok ---"
nohup ngrok http "$OLLAMA_LOCAL_PORT" \
  --log=stdout \
  --log-format=json \
  > /tmp/ngrok_ollama.log 2>&1 &
NGROK_PID=$!
echo ngrok_started_pid="$NGROK_PID"

# Wait for ngrok to establish tunnel
sleep 8

# ── 4. Retrieve public URL from ngrok API ─────────────────────────────────────
echo "--- retrieving_tunnel_url ---"
NGROK_API=""
for attempt in 1 2 3; do
  NGROK_API=$(curl -s --max-time 5 http://localhost:4040/api/tunnels 2>/dev/null || echo "")
  if [[ -n "$NGROK_API" && "$NGROK_API" != *"error"* ]]; then
    break
  fi
  echo "attempt_${attempt}_api_not_ready: retrying in 5s..."
  sleep 5
done

PUBLIC_URL=$(echo "$NGROK_API" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for t in d.get('tunnels', []):
        if t.get('proto') == 'https':
            print(t['public_url'])
            break
except:
    pass
" 2>/dev/null || echo "")

if [[ -z "$PUBLIC_URL" ]]; then
  echo tunnel_status=FAILED_no_public_url
  echo ngrok_log_tail=$(tail -10 /tmp/ngrok_ollama.log 2>/dev/null || echo "no_log")
  echo snapshot=complete
  exit 1
fi

echo tunnel_public_url="$PUBLIC_URL"

# ── 5. Verify tunnel responds ─────────────────────────────────────────────────
echo "--- verifying_tunnel ---"
TUNNEL_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$PUBLIC_URL" 2>/dev/null || echo "000")
echo tunnel_http_root="$TUNNEL_HTTP"
# Test /api/tags endpoint
TAGS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${PUBLIC_URL}/api/tags" 2>/dev/null || echo "000")
echo tunnel_http_api_tags="$TAGS_HTTP"

if [[ "$TAGS_HTTP" == "200" ]]; then
  echo tunnel_ollama_api=OK
else
  echo tunnel_ollama_api=DEGRADED_http_"$TAGS_HTTP"
fi

# ── 6. Update worker1_services.json ──────────────────────────────────────────
echo "--- updating_state ---"
python3 - "$STATE_FILE" "$PUBLIC_URL" "$OLLAMA_MODE" "$OLLAMA_LOCAL_PORT" "$TAGS_HTTP" <<'PY'
import json, sys, pathlib, datetime

state_file, public_url, mode, local_port, api_http = sys.argv[1:6]
p = pathlib.Path(state_file)
data = json.loads(p.read_text()) if p.exists() else {}
data.setdefault("services", {})["ollama_tunnel"] = {
    "mode": mode,
    "local_port": int(local_port),
    "public_url": public_url,
    "generate_url": f"{public_url}/api/generate",
    "chat_url": f"{public_url}/api/chat",
    "tags_url": f"{public_url}/api/tags",
    "tunnel_api_http": api_http,
    "status": "UP" if api_http == "200" else f"DEGRADED_{api_http}",
}
data["tunnel_last_updated"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
data["tunnel_public_url"] = public_url
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"state_written={state_file}")
PY

echo state_updated=ok

# ── 7. Install systemd service for persistence ────────────────────────────────
echo "--- systemd_service ---"
NGROK_BIN=$(which ngrok 2>/dev/null || echo "/usr/local/bin/ngrok")
SERVICE_FILE="/etc/systemd/system/ngrok-ollama.service"

if sudo -n true 2>/dev/null; then
  if [[ ! -f "$SERVICE_FILE" ]]; then
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=ngrok tunnel for Ollama API (website chat)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NGROK_BIN} http ${OLLAMA_LOCAL_PORT} --log=stdout
Restart=always
RestartSec=15
User=${USER}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ngrok-ollama
    echo systemd_service=installed_and_enabled
  else
    sudo systemctl daemon-reload
    sudo systemctl enable ngrok-ollama 2>/dev/null || true
    echo systemd_service=already_exists_enabled
  fi
else
  echo systemd_service=skipped_no_sudo
fi

# ── 8. Commit and push ────────────────────────────────────────────────────────
git -C "$REPO_ROOT" add pilot_v1/state/worker1_services.json
git -C "$REPO_ROOT" commit -m "worker: MTASK-0105 ollama tunnel established $PUBLIC_URL" || true
git -C "$REPO_ROOT" push origin main || true

echo final_tunnel_url="$PUBLIC_URL"
echo snapshot=complete
