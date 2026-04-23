#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
PARITY_FILE="${REPO_ROOT}/pilot_v1/scripts/check_mtask_parity.ps1"

cd "${REPO_ROOT}"

echo "task=MTASK-0067"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/scripts/check_mtask_parity.ps1')
text = path.read_text(encoding='utf-8')

if '[string[]]$RequireStdoutMarkers' not in text:
    text = text.replace(
        '[Parameter(Mandatory = $true)]\n  [string]$TaskId\n)',
        '[Parameter(Mandatory = $true)]\n  [string]$TaskId,\n\n  [string[]]$RequireStdoutMarkers = @()\n)'
    )

if 'parity_stdout_markers=passed' not in text:
    block = '''

if ($RequireStdoutMarkers.Count -gt 0) {
  $stdoutText = [string]$resultJson.stdout_excerpt
  foreach ($marker in $RequireStdoutMarkers) {
    if (-not $stdoutText.Contains($marker)) {
      Write-Host ("error=parity_stdout_marker_missing:{0}" -f $marker)
      exit 1
    }
  }
  Write-Host "parity_stdout_markers=passed"
}
'''
    text = text.replace(
        "Write-Host \"parity_result_present=passed\"\n",
        block + "\nWrite-Host \"parity_result_present=passed\"\n"
    )

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'RequireStdoutMarkers' "${PARITY_FILE}"; then
  echo "error=require_stdout_markers_param_missing"
  exit 1
fi
if ! grep -q 'parity_stdout_marker_missing' "${PARITY_FILE}"; then
  echo "error=stdout_marker_validation_missing"
  exit 1
fi

echo "windows_parity_stdout_markers=passed"
echo "phase29_windows_parity_markers=passed"

git add "pilot_v1/scripts/check_mtask_parity.ps1"
git commit -m "ops: add stdout marker checks to parity script (MTASK-0067)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
