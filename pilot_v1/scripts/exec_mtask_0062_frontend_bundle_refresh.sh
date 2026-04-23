#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
APP_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"

cd "${REPO_ROOT}"

echo "task=MTASK-0062"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/customide/frontend/js/app.js')
text = path.read_text(encoding='utf-8')

if 'async function fetchStatusBundle()' not in text:
    insert_after = '  async function refreshSyncHealth() {\n'
    block = '''  async function fetchStatusBundle() {
    const res = await fetch(cfg.backendBaseUrl + "/api/status/bundle");
    if (!res.ok) throw new Error("status bundle failed");
    return await res.json();
  }

'''
    text = text.replace(insert_after, block + insert_after)

if 'await fetchStatusBundle();' not in text:
    text = text.replace(
        '      await fetchRuntimeStatus();\n      await checkBackend();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n',
        '      const bundle = await fetchStatusBundle();\n      if (bundle && bundle.runtime) renderDashboard(bundle.runtime);\n      if (bundle && bundle.runtime && bundle.runtime.worker && bundle.runtime.worker.remote_url) {\n        remoteFrame.src = bundle.runtime.worker.remote_url;\n      }\n      if (bundle && bundle.sync_health) renderSyncBadge(bundle.sync_health);\n      await checkBackend();\n      await refreshLlmHealth();\n'
    )

    text = text.replace(
        '      await fetchRuntimeStatus();\n      await checkBackend();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n',
        '      const bundle = await fetchStatusBundle();\n      if (bundle && bundle.runtime) renderDashboard(bundle.runtime);\n      if (bundle && bundle.runtime && bundle.runtime.worker && bundle.runtime.worker.remote_url) {\n        remoteFrame.src = bundle.runtime.worker.remote_url;\n      }\n      if (bundle && bundle.sync_health) renderSyncBadge(bundle.sync_health);\n      await checkBackend();\n      await refreshLlmHealth();\n'
    )

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'async function fetchStatusBundle()' "${APP_FILE}"; then
  echo "error=bundle_fetch_function_missing"
  exit 1
fi
if ! grep -q '/api/status/bundle' "${APP_FILE}"; then
  echo "error=bundle_endpoint_missing"
  exit 1
fi
if ! grep -q 'bundle.sync_health' "${APP_FILE}"; then
  echo "error=bundle_sync_health_usage_missing"
  exit 1
fi
if ! grep -q 'bundle.runtime' "${APP_FILE}"; then
  echo "error=bundle_runtime_usage_missing"
  exit 1
fi

echo "frontend_bundle_refresh=passed"
echo "phase24_bundle_contract=passed"

git add "pilot_v1/customide/frontend/js/app.js"
git commit -m "customide-frontend: consume status bundle for refresh (MTASK-0062)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
