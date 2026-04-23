#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
APP_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"

cd "${REPO_ROOT}"

echo "task=MTASK-0065"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/customide/frontend/js/app.js')
text = path.read_text(encoding='utf-8')

if 'async function fetchStatusBundle() {' not in text:
    text = text.replace(
        '  async function refreshSyncHealth() {\n',
        '''  async function fetchStatusBundle() {
    const res = await fetch(cfg.backendBaseUrl + "/api/status/bundle");
    if (!res.ok) throw new Error("status bundle failed");
    return await res.json();
  }

  async function refreshSyncHealth() {
'''
    )

if 'async function refreshFromBundle() {' not in text:
    text = text.replace(
        '  async function refreshLlmHealth() {\n',
        '''  async function refreshFromBundle() {
    const bundle = await fetchStatusBundle();
    if (bundle && bundle.runtime) renderDashboard(bundle.runtime);
    if (bundle && bundle.runtime && bundle.runtime.worker && bundle.runtime.worker.remote_url) {
      remoteFrame.src = bundle.runtime.worker.remote_url;
    }
    if (bundle && bundle.sync_health) renderSyncBadge(bundle.sync_health);
    if (bundle && bundle.sync_cadence) renderSyncCadence(bundle.sync_cadence);
    return bundle;
  }

  async function refreshLlmHealth() {
'''
    )

replacements = {
    '      await fetchRuntimeStatus();\n      await checkBackend();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n': '      await refreshFromBundle();\n      await checkBackend();\n      await refreshLlmHealth();\n',
    '      await runLocal();\n      await checkBackend();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n': '      await runLocal();\n      await refreshFromBundle();\n      await checkBackend();\n      await refreshLlmHealth();\n',
    '      await runRemote();\n      await checkBackend();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n': '      await runRemote();\n      await refreshFromBundle();\n      await checkBackend();\n      await refreshLlmHealth();\n',
    '      await askSharedLlm("local-ide");\n      await checkBackend();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n': '      await askSharedLlm("local-ide");\n      await refreshFromBundle();\n      await checkBackend();\n      await refreshLlmHealth();\n',
    '      await askSharedLlm("remote-ide");\n      await checkBackend();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n': '      await askSharedLlm("remote-ide");\n      await refreshFromBundle();\n      await checkBackend();\n      await refreshLlmHealth();\n',
    '      await fetchRuntimeStatus();\n      await refreshLlmHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n      await refreshSyncHealth();\n': '      await refreshFromBundle();\n      await refreshLlmHealth();\n',
}

for old, new in replacements.items():
    text = text.replace(old, new)

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'async function refreshFromBundle()' "${APP_FILE}"; then
  echo "error=refresh_from_bundle_missing"
  exit 1
fi
if ! grep -q '/api/status/bundle' "${APP_FILE}"; then
  echo "error=bundle_endpoint_missing"
  exit 1
fi

SYNC_CALLS=$(grep -o 'await refreshSyncHealth();' "${APP_FILE}" | wc -l | tr -d ' ')
if [[ "${SYNC_CALLS}" -gt 1 ]]; then
  echo "error=sync_health_duplicate_calls_remaining:${SYNC_CALLS}"
  exit 1
fi

echo "frontend_bundle_refresh_cleanup=passed"
echo "phase27_bundle_refresh_cleanup=passed"

git add "pilot_v1/customide/frontend/js/app.js"
git commit -m "customide-frontend: cleanup bundle refresh loop (MTASK-0065)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
