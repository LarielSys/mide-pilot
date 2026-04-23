#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
APP_FILE="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"

cd "${REPO_ROOT}"

echo "task=MTASK-0068"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/customide/frontend/js/app.js')
text = path.read_text(encoding='utf-8')

if 'let lastGateStatus = "unknown";' not in text:
    text = text.replace(
        '  const syncDebugPanelEl = document.getElementById("syncDebugPanel");\n',
        '  const syncDebugPanelEl = document.getElementById("syncDebugPanel");\n  let lastGateStatus = "unknown";\n'
    )

text = text.replace(
    '    const value = (data && data.sync_error) || "unknown";\n    syncBadgeEl.textContent = "Sync: " + value;\n',
    '    const value = (data && data.sync_error) || "unknown";\n    syncBadgeEl.textContent = "Sync: " + value + " | gate: " + lastGateStatus;\n'
)

if 'lastGateStatus = (data && data.gate_3x60_pass)' not in text:
    text = text.replace(
        '    const status = (data && data.status) || "unknown";\n',
        '    const status = (data && data.status) || "unknown";\n    lastGateStatus = (data && data.gate_3x60_pass) ? "pass" : status;\n'
    )

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'gate: ' "${APP_FILE}"; then
  echo "error=sync_badge_gate_text_missing"
  exit 1
fi
if ! grep -q 'lastGateStatus' "${APP_FILE}"; then
  echo "error=gate_state_variable_missing"
  exit 1
fi

echo "frontend_sync_badge_gate=passed"
echo "phase30_sync_badge_gate=passed"

git add "pilot_v1/customide/frontend/js/app.js"
git commit -m "customide-frontend: include gate status in sync badge (MTASK-0068)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"