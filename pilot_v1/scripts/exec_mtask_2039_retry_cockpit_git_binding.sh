#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

STACK_SCRIPT="pilot_v1/customide/scripts/start_local_stack.sh"
BACKEND_URL="http://127.0.0.1:5555"

log(){ echo "[MTASK-2039] $*"; }

python3 - <<'PY'
from pathlib import Path
import re

main_path = Path("pilot_v1/customide/backend/app/main.py")
runtime_path = Path("pilot_v1/customide/backend/app/routes/runtime.py")

# Patch main.py import list and include_router list without relying on exact original text.
main_text = main_path.read_text(encoding="utf-8")

import_match = re.search(r"from \.routes import ([^\n]+)", main_text)
if not import_match:
    raise SystemExit("main.py routes import line not found")

route_items = [item.strip() for item in import_match.group(1).split(",") if item.strip()]
if "git" not in route_items:
    route_items.insert(0, "git")

new_import_line = "from .routes import " + ", ".join(route_items)
main_text = main_text[:import_match.start()] + new_import_line + main_text[import_match.end():]

if "app.include_router(git.router)" not in main_text:
    marker = "app.include_router(config.router)"
    if marker in main_text:
        main_text = main_text.replace(marker, marker + "\napp.include_router(git.router)", 1)
    else:
        # Fallback: append at end of include_router block
        main_text += "\napp.include_router(git.router)\n"

main_path.write_text(main_text, encoding="utf-8")

# Patch runtime.py with a resilient git-root resolver and use it in sync-health.
runtime_text = runtime_path.read_text(encoding="utf-8")

if "def _resolve_git_root()" not in runtime_text:
    repo_fn = "def _repo_root() -> Path:\n    return Path(__file__).resolve().parents[3]\n"
    resolver_fn = (
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
    if repo_fn in runtime_text:
        runtime_text = runtime_text.replace(repo_fn, repo_fn + resolver_fn, 1)
    else:
        raise SystemExit("runtime.py _repo_root function not found")

runtime_text = runtime_text.replace(
    "def get_sync_health() -> dict:\n    repo_root = _repo_root()\n",
    "def get_sync_health() -> dict:\n    repo_root = _resolve_git_root()\n",
    1,
)

runtime_path.write_text(runtime_text, encoding="utf-8")
PY

log "Applied robust backend patch for git route + sync-health root"

if [[ -f "$STACK_SCRIPT" ]]; then
  log "Restarting CustomIDE stack"
  bash "$STACK_SCRIPT" >/tmp/mtask2039-start-local-stack.log 2>&1 || true
fi

log "Waiting for backend health"
for _ in $(seq 1 20); do
  if curl -fsS "$BACKEND_URL/health" >/tmp/mtask2039-health.json 2>/dev/null; then
    break
  fi
  sleep 2
done

curl -fsS "$BACKEND_URL/health" >/tmp/mtask2039-health.json
curl -fsS "$BACKEND_URL/api/git/status" >/tmp/mtask2039-git-status.json
curl -fsS "$BACKEND_URL/api/status/sync-health" >/tmp/mtask2039-sync-health.json

python3 - <<'PY'
import json
from pathlib import Path

git_status = json.loads(Path('/tmp/mtask2039-git-status.json').read_text(encoding='utf-8'))
sync = json.loads(Path('/tmp/mtask2039-sync-health.json').read_text(encoding='utf-8'))

origin = (git_status.get('remotes') or {}).get('origin', '')
source = sync.get('sync_error_source', '')

print(f"git_repo_root={git_status.get('repo_root','')}")
print(f"git_origin={origin}")
print(f"git_upstream={git_status.get('upstream','')}")
print(f"sync_error_source={source}")

if not origin:
    raise SystemExit('origin remote missing from /api/git/status')
if source == 'missing':
    raise SystemExit('sync-health still reports source=missing')
PY

log "Cockpit git binding repair validated"
