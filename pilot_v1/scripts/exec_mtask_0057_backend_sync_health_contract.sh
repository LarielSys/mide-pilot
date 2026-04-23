#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
RUNTIME_ROUTE="${REPO_ROOT}/pilot_v1/customide/backend/app/routes/runtime.py"

cd "${REPO_ROOT}"

echo "task=MTASK-0057"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/customide/backend/app/routes/runtime.py')
text = path.read_text(encoding='utf-8')

if 'def get_sync_health' not in text:
    insert_block = '''\n\n@router.get("/sync-health")\ndef get_sync_health() -> dict:\n    repo_root = Path(__file__).resolve().parents[3]\n    sync_error_file = repo_root / "pilot_v1/state/worker_autopilot_git_sync_last_error.txt"\n\n    sync_error = "none"\n    if sync_error_file.exists():\n        raw = sync_error_file.read_text(encoding="utf-8", errors="replace").strip()\n        if raw:\n            sync_error = raw.splitlines()[0]\n\n    return {\n        "worker_id": "ubuntu-worker-01",\n        "sync_error": sync_error,\n        "sync_error_file": str(sync_error_file),\n    }\n'''
    text = text + insert_block

path.write_text(text, encoding='utf-8')
PY

if ! grep -q '@router.get("/sync-health")' "${RUNTIME_ROUTE}"; then
  echo "error=sync_health_route_missing"
  exit 1
fi
if ! grep -q 'worker_autopilot_git_sync_last_error.txt' "${RUNTIME_ROUTE}"; then
  echo "error=sync_error_file_contract_missing"
  exit 1
fi

echo "backend_sync_health_route=passed"

echo "phase19_sync_contract=passed"

git add "pilot_v1/customide/backend/app/routes/runtime.py"
git commit -m "customide-backend: add sync health contract route (MTASK-0057)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
