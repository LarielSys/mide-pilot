#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
INDEX_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/index.html"
APP_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"

cd "${REPO_ROOT}"

echo "task=MTASK-0060"
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
if 'id="syncDebugPanel"' not in index_text:
    marker = '      <div id="dashboard" class="dashboard"></div>\n'
    insert = marker + '      <pre id="syncDebugPanel">Sync debug: waiting...</pre>\n'
    index_text = index_text.replace(marker, insert)
    index_path.write_text(index_text, encoding='utf-8')

app_text = app_path.read_text(encoding='utf-8')
if 'const syncDebugPanelEl' not in app_text:
    app_text = app_text.replace(
        '  const llmBadgeEl = document.getElementById("llmHealthBadge");\n  const syncBadgeEl = document.getElementById("syncHealthBadge");\n',
        '  const llmBadgeEl = document.getElementById("llmHealthBadge");\n  const syncBadgeEl = document.getElementById("syncHealthBadge");\n  const syncDebugPanelEl = document.getElementById("syncDebugPanel");\n'
    )

    app_text = app_text.replace(
        '  function renderSyncBadge(data) {\n',
        '  function renderSyncBadge(data) {\n'
        '    if (syncDebugPanelEl) {\n'
        '      const syncError = (data && data.sync_error) || "unknown";\n'
        '      const syncFile = (data && data.sync_error_file) || "n/a";\n'
        '      syncDebugPanelEl.textContent = "Sync debug\\n- sync_error: " + syncError + "\\n- sync_error_file: " + syncFile;\n'
        '    }\n'
    )

    app_path.write_text(app_text, encoding='utf-8')
PY

if ! grep -q 'id="syncDebugPanel"' "${INDEX_FILE}"; then
  echo "error=sync_debug_panel_missing"
  exit 1
fi
if ! grep -q 'sync_error_file' "${APP_FILE}"; then
  echo "error=sync_error_file_not_rendered"
  exit 1
fi
if ! grep -q 'Sync debug' "${APP_FILE}"; then
  echo "error=sync_debug_text_missing"
  exit 1
fi

echo "frontend_sync_debug_panel=passed"
echo "phase22_sync_debug_ui=passed"

git add "pilot_v1/customide/frontend/index.html" "pilot_v1/customide/frontend/js/app.js"
git commit -m "customide-frontend: add sync debug panel (MTASK-0060)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
