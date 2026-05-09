#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

TARGET_MODEL="qwen2.5-coder:14b"
OLLAMA_URL="http://127.0.0.1:11434"

log(){ echo "[MTASK-2031] $*"; }

log "Checking Ollama availability"
TAGS_HTTP="$(curl -s -o /tmp/mtask2031_tags.json -w '%{http_code}' "${OLLAMA_URL}/api/tags" || true)"
log "ollama_tags_http=${TAGS_HTTP}"
if [[ "${TAGS_HTTP}" != "200" ]]; then
  echo "Ollama tags endpoint unavailable" >&2
  exit 1
fi

if ! grep -q "\"name\":\"${TARGET_MODEL}\"" /tmp/mtask2031_tags.json; then
  log "Pulling ${TARGET_MODEL}"
  ollama pull "${TARGET_MODEL}"
else
  log "Model already present: ${TARGET_MODEL}"
fi

log "Validating /api/generate with ${TARGET_MODEL}"
GEN_HTTP="$(curl -s -o /tmp/mtask2031_generate.json -w '%{http_code}' -X POST "${OLLAMA_URL}/api/generate" -H 'Content-Type: application/json' -d '{"model":"qwen2.5-coder:14b","prompt":"Reply with exactly: online","stream":false}' || true)"
log "ollama_generate_http=${GEN_HTTP}"
if [[ "${GEN_HTTP}" != "200" ]]; then
  echo "Generate validation failed" >&2
  exit 1
fi

if [[ -f pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh ]]; then
  sed -i "s/^OLLAMA_MODEL='[^']*'/OLLAMA_MODEL='qwen2.5-coder:14b'/" pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh
  log "Updated MTASK-2026 shim default model to ${TARGET_MODEL}"
fi

python3 - <<'PY'
import json
from pathlib import Path

for path in [Path('pilot_v1/config/worker1_services.json'), Path('pilot_v1/state/worker1_services.json')]:
    if not path.exists():
        continue
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        continue
    services = data.get('services', {})
    ollama = services.get('ollama')
    if isinstance(ollama, dict):
        ollama['model_primary'] = 'qwen2.5-coder:14b'
        path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY

if [[ -x pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh || -f pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh ]]; then
  log "Running chat shim publish script for live validation"
  bash pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh || true
fi

log "MTASK-2031 completed: model set to ${TARGET_MODEL}"
