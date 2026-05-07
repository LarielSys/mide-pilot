#!/usr/bin/env bash
set -euo pipefail

echo task=MTASK-0104
echo objective=diagnose_ngrok_and_ollama_tunnel_status
echo timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── 1. Native Ollama ──────────────────────────────────────────────────────────
echo "--- native_ollama ---"
OLLAMA_HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:11434 2>/dev/null || echo "000")
echo native_ollama_port11434=$OLLAMA_HTTP
OLLAMA_MODELS=$(curl -s http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c \
  "import json,sys; d=json.load(sys.stdin); [print('  model:',m['name']) for m in d.get('models',[])]" \
  2>/dev/null || echo "  models_unavailable")
echo "$OLLAMA_MODELS"

# ── 2. Docker Ollama ──────────────────────────────────────────────────────────
echo "--- docker_ollama ---"
DOCKER_OLLAMA=$(docker ps --filter name=ollama --format "name={{.Names}} status={{.Status}} ports={{.Ports}}" \
  2>/dev/null || echo "docker_not_available_or_no_ollama_container")
echo docker_ollama_containers=$DOCKER_OLLAMA
# Any container exposing 11434
ALL_DOCKER=$(docker ps --format "{{.Names}}\t{{.Ports}}" 2>/dev/null | grep 11434 || echo "none")
echo docker_11434_bindings=$ALL_DOCKER

# ── 3. Active ngrok tunnels ───────────────────────────────────────────────────
echo "--- ngrok_tunnels ---"
NGROK_API=$(curl -s --max-time 5 http://localhost:4040/api/tunnels 2>/dev/null || echo '{"error":"ngrok_api_unreachable"}')
echo ngrok_api_raw=$NGROK_API
echo "$NGROK_API" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    tunnels = d.get('tunnels', [])
    if tunnels:
        for t in tunnels:
            addr = t.get('config', {}).get('addr', 'unknown')
            print(f'  active_tunnel: {t[\"name\"]} public={t[\"public_url\"]} local={addr}')
    else:
        print('  no_active_tunnels')
except Exception as e:
    print(f'  parse_error={e}')
" 2>/dev/null || echo "  ngrok_parse_failed"

# ── 4. ngrok process + config ─────────────────────────────────────────────────
echo "--- ngrok_process ---"
NGROK_PROC=$(pgrep -a ngrok 2>/dev/null | head -5 || echo "not_running")
echo ngrok_process=$NGROK_PROC

echo "--- ngrok_config ---"
for cfg in "$HOME/.config/ngrok/ngrok.yml" "$HOME/ngrok.yml" "/etc/ngrok.yml"; do
  if [[ -f "$cfg" ]]; then
    echo ngrok_config_file=$cfg
    cat "$cfg"
    break
  fi
done

# ── 5. itheia-llm proxy (port 8082) ──────────────────────────────────────────
echo "--- itheia_llm ---"
ITHEIA_HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8082 2>/dev/null || echo "000")
echo itheia_llm_port8082=$ITHEIA_HTTP

# ── 6. Existing ngrok service ─────────────────────────────────────────────────
echo "--- ngrok_systemd ---"
NGROK_SVC=$(systemctl is-active ngrok 2>/dev/null || \
            systemctl is-active ngrok-ollama 2>/dev/null || echo "no_ngrok_service")
echo ngrok_systemd_status=$NGROK_SVC

# ── 7. Write diagnosis to state ───────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$REPO_ROOT/pilot_v1/state/worker1_services.json" "$OLLAMA_HTTP" "$DOCKER_OLLAMA" "$NGROK_API" <<'PY'
import json, sys, pathlib, datetime

state_file, ollama_http, docker_ollama, ngrok_api_raw = sys.argv[1:5]
p = pathlib.Path(state_file)
data = json.loads(p.read_text()) if p.exists() else {}
data.setdefault("diagnostics", {})["mtask_0104"] = {
    "timestamp_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "native_ollama_http": ollama_http,
    "docker_ollama": docker_ollama,
    "ngrok_api_snapshot": ngrok_api_raw[:500],
}
p.write_text(json.dumps(data, indent=2) + "\n")
print("state_updated=ok")
PY

git -C "$REPO_ROOT" add pilot_v1/state/worker1_services.json
git -C "$REPO_ROOT" commit -m "worker: MTASK-0104 tunnel diagnosis" || true
git -C "$REPO_ROOT" push origin main || true

echo snapshot=complete
