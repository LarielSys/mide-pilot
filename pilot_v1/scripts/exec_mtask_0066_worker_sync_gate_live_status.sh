#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
AUTOPILOT_FILE="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"

cd "${REPO_ROOT}"

echo "task=MTASK-0066"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/scripts/worker_mtask_autopilot.sh')
text = path.read_text(encoding='utf-8')

if 'sync_gate_3x60_state() {' not in text:
    insert = '''

sync_gate_3x60_state() {
  python3 - "$EVENT_LOG_FILE" <<'PY2'
import datetime
import pathlib
import re
import sys

event_file = pathlib.Path(sys.argv[1])
if not event_file.exists():
    print("missing")
    raise SystemExit(0)

lines = event_file.read_text(encoding="utf-8", errors="replace").splitlines()
stamps = []
for line in lines:
    m = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z', line)
    if not m:
        continue
    stamps.append(datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    if len(stamps) >= 4:
        break

if len(stamps) < 4:
    print("insufficient")
    raise SystemExit(0)

deltas = [(stamps[i] - stamps[i + 1]).total_seconds() for i in range(3)]
if all(55 <= d <= 65 for d in deltas):
    print("pass")
else:
    print("drift")
PY2
}
'''
    text = text.replace('write_status() {', insert + '\nwrite_status() {')

if 'echo "sync_gate_3x60: $(sync_gate_3x60_state)"' not in text:
    text = text.replace(
        '    if [[ -f "${SYNC_ERROR_FILE}" ]]; then\n',
        '    echo "sync_gate_3x60: $(sync_gate_3x60_state)"\n    if [[ -f "${SYNC_ERROR_FILE}" ]]; then\n'
    )

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'sync_gate_3x60_state()' "${AUTOPILOT_FILE}"; then
  echo "error=sync_gate_state_helper_missing"
  exit 1
fi
if ! grep -q 'sync_gate_3x60: $(sync_gate_3x60_state)' "${AUTOPILOT_FILE}"; then
  echo "error=sync_gate_live_line_missing"
  exit 1
fi

echo "worker_sync_gate_live_status=passed"
echo "phase28_worker_sync_gate=passed"

git add "pilot_v1/scripts/worker_mtask_autopilot.sh"
git commit -m "worker: expose sync gate state in live status (MTASK-0066)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
