#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BACKEND_URL="http://127.0.0.1:5555"
PUBLIC_BASE="https://jawed-lapel-dispersed.ngrok-free.dev"

log(){ echo "[MTASK-2042] $*"; }

log "Running tunnel setup via MTASK-0105"
bash "pilot_v1/scripts/exec_mtask_0105_setup_ollama_tunnel.sh" >/tmp/mtask2042-0105.log 2>&1 || true

log "Running tunnel verification via MTASK-0106"
bash "pilot_v1/scripts/exec_mtask_0106_verify_ollama_tunnel.sh" >/tmp/mtask2042-0106.log 2>&1 || true

# Local cockpit backend validation
health_code=$(curl -s -o /tmp/mtask2042-health.json -w "%{http_code}" "$BACKEND_URL/health" || true)
git_code=$(curl -s -o /tmp/mtask2042-git-status.json -w "%{http_code}" "$BACKEND_URL/api/git/status" || true)

# Public Ollama tunnel validation
tags_code=$(curl -s -o /tmp/mtask2042-tags.json -w "%{http_code}" -H "ngrok-skip-browser-warning: true" "$PUBLIC_BASE/api/tags" || true)
gen_code=$(curl -s -o /tmp/mtask2042-generate.json -w "%{http_code}" -H "Content-Type: application/json" -H "ngrok-skip-browser-warning: true" -X POST "$PUBLIC_BASE/api/generate" -d '{"model":"qwen2.5-coder:7b","prompt":"Reply with only TUNNEL_OK","stream":false}' || true)

echo "local_health_http=$health_code"
echo "local_git_status_http=$git_code"
echo "public_tags_http=$tags_code"
echo "public_generate_http=$gen_code"

if [[ "$health_code" != "200" || "$git_code" != "200" || "$tags_code" != "200" || "$gen_code" != "200" ]]; then
  echo "--- MTASK-0105 log tail ---"
  tail -n 200 /tmp/mtask2042-0105.log || true
  echo "--- MTASK-0106 log tail ---"
  tail -n 200 /tmp/mtask2042-0106.log || true
  exit 1
fi

python3 - <<'PY'
import json
from pathlib import Path

tags = json.loads(Path('/tmp/mtask2042-tags.json').read_text(encoding='utf-8'))
models = [m.get('name', '') for m in (tags.get('models') or [])]
print('public_models=' + ','.join(models))
for required in ('qwen2.5-coder:7b', 'qwen2.5vl:7b'):
    if required not in models:
        raise SystemExit(f'missing required model: {required}')
PY

log "Tunnel and cockpit validation passed"
