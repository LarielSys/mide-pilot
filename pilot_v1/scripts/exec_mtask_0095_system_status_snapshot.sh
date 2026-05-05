#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/pilot_v1/config/worker1_services.json"

echo "task=MTASK-0095"
echo "objective=system_status_snapshot_post_reconnect"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "hostname=$(hostname)"

echo "=== SERVICES ==="

# CustomIDE backend
BACKEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5555/health 2>/dev/null || echo "unreachable")
echo "customide_backend_port5555=${BACKEND_STATUS}"

# CustomIDE frontend
FRONTEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5570 2>/dev/null || echo "unreachable")
echo "customide_frontend_port5570=${FRONTEND_STATUS}"

# Ollama
OLLAMA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:11434/api/tags 2>/dev/null || echo "unreachable")
echo "ollama_port11434=${OLLAMA_STATUS}"

# code-server
CODESERVER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8092 2>/dev/null || echo "unreachable")
echo "codeserver_port8092=${CODESERVER_STATUS}"

# ngrok
NGROK_STATUS=$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); tunnels=[t['public_url'] for t in d.get('tunnels',[])]; print('tunnels='+str(tunnels))" 2>/dev/null || echo "ngrok=unreachable")
echo "${NGROK_STATUS}"

echo "=== PROCESSES ==="
ps aux --no-headers 2>/dev/null | grep -E "ollama|uvicorn|code-server|ngrok|autopilot" | grep -v grep | awk '{print $11}' | sort -u || echo "ps_check_done"

echo "=== WORKER1 CONFIG ==="
if [[ -f "$CONFIG_FILE" ]]; then
  cat "$CONFIG_FILE"
else
  echo "worker1_services_config=not_found"
fi

echo "=== DISK ==="
df -h / 2>/dev/null | tail -1

echo "status_snapshot=complete"
