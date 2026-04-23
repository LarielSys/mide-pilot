#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
INDEX_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/index.html"
APP_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"

cd "${REPO_ROOT}"

echo "task=MTASK-0059"
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
if 'id="syncHealthBadge"' not in index_text:
    marker = '    <div class="status" id="llmHealthBadge">LLM: checking...</div>\n'
    insert = marker + '    <div class="status" id="syncHealthBadge">Sync: checking...</div>\n'
    index_text = index_text.replace(marker, insert)
    index_path.write_text(index_text, encoding='utf-8')

app_text = app_path.read_text(encoding='utf-8')
if 'function renderSyncBadge' not in app_text:
    app_text = app_text.replace(
        '  const llmBadgeEl = document.getElementById("llmHealthBadge");\n',
        '  const llmBadgeEl = document.getElementById("llmHealthBadge");\n  const syncBadgeEl = document.getElementById("syncHealthBadge");\n'
    )

    app_text = app_text.replace(
        '  async function refreshLlmHealth() {\n',
        '  function renderSyncBadge(data) {\n    if (!syncBadgeEl) return;\n    const value = (data && data.sync_error) || "unknown";\n    syncBadgeEl.textContent = "Sync: " + value;\n  }\n\n  async function refreshSyncHealth() {\n    const res = await fetch(cfg.backendBaseUrl + "/api/status/sync-health");\n    if (!res.ok) throw new Error("sync health failed");\n    const data = await res.json();\n    renderSyncBadge(data);\n    return data;\n  }\n\n  async function refreshLlmHealth() {\n'
    )

    app_text = app_text.replace(
        '      await refreshLlmHealth();\n',
        '      await refreshLlmHealth();\n      await refreshSyncHealth();\n'
    )

    app_text = app_text.replace(
        '      await refreshLlmHealth();\n',
        '      await refreshLlmHealth();\n      await refreshSyncHealth();\n'
    )

    app_text = app_text.replace(
        '      await refreshLlmHealth();\n',
        '      await refreshLlmHealth();\n      await refreshSyncHealth();\n'
    )

    app_text = app_text.replace(
        '      await refreshLlmHealth();\n',
        '      await refreshLlmHealth();\n      await refreshSyncHealth();\n'
    )

    app_text = app_text.replace(
        '      await refreshLlmHealth();\n',
        '      await refreshLlmHealth();\n      await refreshSyncHealth();\n'
    )

    app_text = app_text.replace(
        '      await refreshLlmHealth();\n',
        '      await refreshLlmHealth();\n      await refreshSyncHealth();\n'
    )

    app_path.write_text(app_text, encoding='utf-8')
PY

if ! grep -q 'id="syncHealthBadge"' "${INDEX_FILE}"; then
  echo "error=sync_badge_missing"
  exit 1
fi
if ! grep -q '/api/status/sync-health' "${APP_FILE}"; then
  echo "error=sync_health_endpoint_not_called"
  exit 1
fi
if ! grep -q 'Sync: ' "${APP_FILE}"; then
  echo "error=sync_badge_render_missing"
  exit 1
fi

echo "frontend_sync_badge=passed"
echo "phase21_sync_health_ui=passed"

git add "pilot_v1/customide/frontend/index.html" "pilot_v1/customide/frontend/js/app.js"
git commit -m "customide-frontend: add sync health badge (MTASK-0059)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
