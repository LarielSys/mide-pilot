#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

CUSTOMIDE_COMPOSE="pilot_v1/customide/docker-compose.yml"
BACKEND_URL="http://127.0.0.1:5555"
PUBLIC_OLLAMA_BASE="https://jawed-lapel-dispersed.ngrok-free.dev"

log(){ echo "[MTASK-2041] $*"; }

# Keep backend patching idempotent before service restart.
python3 - <<'PY'
from pathlib import Path
import re

main_path = Path("pilot_v1/customide/backend/app/main.py")
runtime_path = Path("pilot_v1/customide/backend/app/routes/runtime.py")

main_text = main_path.read_text(encoding="utf-8")
import_match = re.search(r"from \.routes import ([^\n]+)", main_text)
if not import_match:
    raise SystemExit("main.py routes import line not found")
items = [x.strip() for x in import_match.group(1).split(",") if x.strip()]
if "git" not in items:
    items.insert(0, "git")
main_text = main_text[:import_match.start()] + ("from .routes import " + ", ".join(items)) + main_text[import_match.end():]
if "app.include_router(git.router)" not in main_text:
    marker = "app.include_router(config.router)"
    if marker in main_text:
        main_text = main_text.replace(marker, marker + "\napp.include_router(git.router)", 1)
    else:
        main_text += "\napp.include_router(git.router)\n"
main_path.write_text(main_text, encoding="utf-8")

runtime_text = runtime_path.read_text(encoding="utf-8")
if "def _resolve_git_root()" not in runtime_text:
    needle = "def _repo_root() -> Path:\n    return Path(__file__).resolve().parents[3]\n"
    insert = (
        "\n\ndef _resolve_git_root() -> Path:\n"
        "    candidates = [\n"
        "        Path(__file__).resolve().parents[3],\n"
        "        Path(__file__).resolve().parents[4],\n"
        "        Path(__file__).resolve().parents[5],\n"
        "    ]\n"
        "    for candidate in candidates:\n"
        "        rc, out = _run_git(candidate, [\"rev-parse\", \"--show-toplevel\"])\n"
        "        if rc == 0 and out:\n"
        "            return Path(out)\n"
        "    return _repo_root()\n"
    )
    if needle not in runtime_text:
        raise SystemExit("runtime.py _repo_root not found")
    runtime_text = runtime_text.replace(needle, needle + insert, 1)
runtime_text = runtime_text.replace(
    "def get_sync_health() -> dict:\n    repo_root = _repo_root()\n",
    "def get_sync_health() -> dict:\n    repo_root = _resolve_git_root()\n",
    1,
)
runtime_path.write_text(runtime_text, encoding="utf-8")
PY

log "Patched backend routing and sync-health root"

# Prefer container restart path, since prior retries showed protected PIDs.
if command -v docker >/dev/null 2>&1 && [[ -f "$CUSTOMIDE_COMPOSE" ]]; then
  log "Rebuilding/restarting customide backend/frontend containers"
  docker compose -f "$CUSTOMIDE_COMPOSE" up -d --build backend frontend || true
  docker restart mide-backend mide-frontend >/dev/null 2>&1 || true
fi

log "Waiting for local backend health"
for _ in $(seq 1 30); do
  if curl -fsS "$BACKEND_URL/health" >/tmp/mtask2041-health.json 2>/dev/null; then
    break
  fi
  sleep 2
done

curl -fsS "$BACKEND_URL/health" >/tmp/mtask2041-health.json
git_code=$(curl -s -o /tmp/mtask2041-git-status.json -w "%{http_code}" "$BACKEND_URL/api/git/status" || true)
if [[ "$git_code" != "200" ]]; then
  echo "local_api_git_status_http=$git_code"
  echo "--- local backend log tail ---"
  tail -n 150 /tmp/customide-backend.log || true
  exit 1
fi

curl -fsS "$BACKEND_URL/api/status/sync-health" >/tmp/mtask2041-sync-health.json

# Verify local Ollama is up on worker host.
local_tags_code=$(curl -s -o /tmp/mtask2041-local-tags.json -w "%{http_code}" "http://127.0.0.1:11434/api/tags" || true)
if [[ "$local_tags_code" != "200" ]]; then
  echo "local_ollama_tags_http=$local_tags_code"
  exit 1
fi

# Check public tunnel; if degraded, run known recovery script and retry.
public_tags_code=$(curl -s -o /tmp/mtask2041-public-tags.json -w "%{http_code}" -H "ngrok-skip-browser-warning: true" "$PUBLIC_OLLAMA_BASE/api/tags" || true)
if [[ "$public_tags_code" != "200" ]]; then
  log "Public tunnel unhealthy (HTTP $public_tags_code), attempting tunnel recovery"
  if [[ -f "pilot_v1/scripts/exec_mtask_2022_rotate_tunnel_and_publish.sh" ]]; then
    bash "pilot_v1/scripts/exec_mtask_2022_rotate_tunnel_and_publish.sh" >/tmp/mtask2041-tunnel-recover.log 2>&1 || true
  elif [[ -f "pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh" ]]; then
    bash "pilot_v1/scripts/exec_mtask_2026_chat_shim_publish.sh" >/tmp/mtask2041-tunnel-recover.log 2>&1 || true
  fi
  public_tags_code=$(curl -s -o /tmp/mtask2041-public-tags.json -w "%{http_code}" -H "ngrok-skip-browser-warning: true" "$PUBLIC_OLLAMA_BASE/api/tags" || true)
fi

if [[ "$public_tags_code" != "200" ]]; then
  echo "public_ollama_tags_http=$public_tags_code"
  echo "--- tunnel recover log tail ---"
  tail -n 200 /tmp/mtask2041-tunnel-recover.log || true
  exit 1
fi

python3 - <<'PY'
import json
from pathlib import Path

git_status = json.loads(Path('/tmp/mtask2041-git-status.json').read_text(encoding='utf-8'))
sync = json.loads(Path('/tmp/mtask2041-sync-health.json').read_text(encoding='utf-8'))
public_tags = json.loads(Path('/tmp/mtask2041-public-tags.json').read_text(encoding='utf-8'))

origin = (git_status.get('remotes') or {}).get('origin', '')
source = sync.get('sync_error_source', '')
models = [m.get('name', '') for m in (public_tags.get('models') or [])]

print(f"git_origin={origin}")
print(f"sync_error_source={source}")
print(f"public_models={','.join(models)}")

if not origin:
    raise SystemExit('origin remote missing from local /api/git/status')
if source == 'missing':
    raise SystemExit('sync-health source still missing')
for required in ('qwen2.5-coder:7b', 'qwen2.5vl:7b'):
    if required not in models:
        raise SystemExit(f'missing required model on public tunnel: {required}')
PY

log "Worker1 cockpit + website Ollama connections recovered and validated"
