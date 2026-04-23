#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
INDEX_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/index.html"
APP_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"

cd "${REPO_ROOT}"

echo "task=MTASK-0064"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

index_path = Path('pilot_v1/customide/frontend/index.html')
app_path = Path('pilot_v1/customide/frontend/js/app.js')

index_text = index_path.read_text(encoding='utf-8')
if 'id="syncCadencePanel"' not in index_text:
    index_text = index_text.replace(
        '<pre id="syncDebugPanel">Sync debug: waiting...</pre>\n',
        '<pre id="syncDebugPanel">Sync debug: waiting...</pre>\n      <pre id="syncCadencePanel">Sync cadence: waiting...</pre>\n'
    )
    index_path.write_text(index_text, encoding='utf-8')

app_text = app_path.read_text(encoding='utf-8')
if 'const syncCadencePanelEl = document.getElementById("syncCadencePanel");' not in app_text:
    app_text = app_text.replace(
        '  const syncDebugPanelEl = document.getElementById("syncDebugPanel");\n',
        '  const syncDebugPanelEl = document.getElementById("syncDebugPanel");\n  const syncCadencePanelEl = document.getElementById("syncCadencePanel");\n'
    )

if 'function renderSyncCadence(data) {' not in app_text:
    app_text = app_text.replace(
        '  function renderSyncBadge(data) {\n',
        '''  function renderSyncCadence(data) {
    if (!syncCadencePanelEl) return;
    const deltas = (data && data.deltas_seconds) ? data.deltas_seconds.join(", ") : "n/a";
    const gate = (data && data.gate_3x60_pass) ? "pass" : "pending";
    const status = (data && data.status) || "unknown";
    syncCadencePanelEl.textContent = "Sync cadence\\n- deltas_seconds: " + deltas + "\\n- gate_3x60_pass: " + gate + "\\n- status: " + status;
  }

  function renderSyncBadge(data) {
'''
    )

app_path.write_text(app_text, encoding='utf-8')
PY

if ! grep -q 'id="syncCadencePanel"' "${INDEX_FILE}"; then
  echo "error=sync_cadence_panel_missing"
  exit 1
fi
if ! grep -q 'function renderSyncCadence(data)' "${APP_FILE}"; then
  echo "error=render_sync_cadence_missing"
  exit 1
fi
if ! grep -q 'gate_3x60_pass' "${APP_FILE}"; then
  echo "error=sync_cadence_gate_missing"
  exit 1
fi

echo "frontend_sync_cadence_panel=passed"
echo "phase26_sync_cadence_ui=passed"

git add "pilot_v1/customide/frontend/index.html" "pilot_v1/customide/frontend/js/app.js"
git commit -m "customide-frontend: add sync cadence panel (MTASK-0064)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
