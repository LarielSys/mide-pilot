#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

MAIN_FILE="pilot_v1/customide/backend/app/main.py"
RUNTIME_FILE="pilot_v1/customide/backend/app/routes/runtime.py"
STACK_SCRIPT="pilot_v1/customide/scripts/start_local_stack.sh"
BACKEND_URL="http://127.0.0.1:5555"

log(){ echo "[MTASK-2038] $*"; }
err(){ echo "[MTASK-2038 ERROR] $*" >&2; }

python3 - <<'PY'
from pathlib import Path

main_path = Path("pilot_v1/customide/backend/app/main.py")
text = main_path.read_text(encoding="utf-8")
old_import = "from .routes import config, execute, health, messenger, mtask, ollama_proxy, runtime, shared_llm\n"
new_import = "from .routes import config, execute, git, health, messenger, mtask, ollama_proxy, runtime, shared_llm\n"
if old_import in text and new_import not in text:
    text = text.replace(old_import, new_import)

if "app.include_router(git.router)" not in text:
    marker = "app.include_router(config.router)\n"
    if marker not in text:
        raise SystemExit("main.py include_router marker not found")
    text = text.replace(marker, marker + "app.include_router(git.router)\n")

main_path.write_text(text, encoding="utf-8")

runtime_path = Path("pilot_v1/customide/backend/app/routes/runtime.py")
text = runtime_path.read_text(encoding="utf-8")

if "def _resolve_git_root() -> Path:" not in text:
    insert_after = "def _repo_root() -> Path:\n    return Path(__file__).resolve().parents[3]\n\n\n"
    replacement = insert_after + (
        "def _resolve_git_root() -> Path:\n"
        "    candidates = [\n"
        "        Path(__file__).resolve().parents[3],\n"
        "        Path(__file__).resolve().parents[4],\n"
        "        Path(__file__).resolve().parents[5],\n"
        "    ]\n"
        "    for candidate in candidates:\n"
        "        rc, out = _run_git(candidate, [\"rev-parse\", \"--show-toplevel\"])\n"
        "        if rc == 0 and out:\n"
        "            return Path(out)\n"
        "    return _repo_root()\n\n\n"
    )
    if insert_after not in text:
        raise SystemExit("runtime.py repo_root marker not found")
    text = text.replace(insert_after, replacement)

old = "def get_sync_health() -> dict:\n    repo_root = _repo_root()\n"
new = "def get_sync_health() -> dict:\n    repo_root = _resolve_git_root()\n"
if old in text:
    text = text.replace(old, new)

runtime_path.write_text(text, encoding="utf-8")
PY

log "Patched CustomIDE backend wiring for git route and sync-health repo root"

if [[ -f "$STACK_SCRIPT" ]]; then
  log "Restarting CustomIDE stack"
  bash "$STACK_SCRIPT" >/tmp/mtask2038-start-local-stack.log 2>&1 || true
fi

log "Waiting for backend health"
for _ in $(seq 1 15); do
  if curl -fsS "$BACKEND_URL/health" >/tmp/mtask2038-health.json 2>/dev/null; then
    break
  fi
  sleep 2
done

curl -fsS "$BACKEND_URL/health" >/tmp/mtask2038-health.json
curl -fsS "$BACKEND_URL/api/git/status" >/tmp/mtask2038-git-status.json
curl -fsS "$BACKEND_URL/api/status/sync-health" >/tmp/mtask2038-sync-health.json

python3 - <<'PY'
import json
from pathlib import Path
import sys

git_status = json.loads(Path('/tmp/mtask2038-git-status.json').read_text(encoding='utf-8'))
sync = json.loads(Path('/tmp/mtask2038-sync-health.json').read_text(encoding='utf-8'))

remotes = git_status.get('remotes') or {}
origin = remotes.get('origin', '')
source = sync.get('sync_error_source', '')

print(f"git_repo_root={git_status.get('repo_root','')}")
print(f"git_origin={origin}")
print(f"git_upstream={git_status.get('upstream','')}")
print(f"sync_error_source={source}")
print(f"sync_branch={sync.get('branch','')}")
print(f"sync_origin_head={sync.get('origin_head_short','')}")

if not origin:
    raise SystemExit('origin remote missing from /api/git/status')
if source == 'missing':
    raise SystemExit('sync-health still reports source=missing')
PY

log "Cockpit git binding repaired and validated"