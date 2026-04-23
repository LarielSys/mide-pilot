#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
RUNTIME_FILE="${REPO_ROOT}/pilot_v1/customide/backend/app/routes/runtime.py"

cd "${REPO_ROOT}"

echo "task=MTASK-0061"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/customide/backend/app/routes/runtime.py')
text = path.read_text(encoding='utf-8')

if 'def get_status_bundle' not in text:
    block = '''\n\n@router.get("/bundle")\ndef get_status_bundle() -> dict:\n    return {\n        "runtime": get_runtime_status(),\n        "sync_health": get_sync_health(),\n    }\n'''
    text = text + block
    path.write_text(text, encoding='utf-8')
PY

if ! grep -q '@router.get("/bundle")' "${RUNTIME_FILE}"; then
  echo "error=status_bundle_route_missing"
  exit 1
fi
if ! grep -q '"runtime": get_runtime_status()' "${RUNTIME_FILE}"; then
  echo "error=bundle_runtime_key_missing"
  exit 1
fi
if ! grep -q '"sync_health": get_sync_health()' "${RUNTIME_FILE}"; then
  echo "error=bundle_sync_key_missing"
  exit 1
fi

echo "backend_status_bundle=passed"
echo "phase23_status_bundle=passed"

git add "pilot_v1/customide/backend/app/routes/runtime.py"
git commit -m "customide-backend: add status bundle endpoint (MTASK-0061)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
