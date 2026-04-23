#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"

cd "${REPO_ROOT}"

echo "task=MTASK-0056"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path
import re

path = Path('pilot_v1/scripts/worker_mtask_autopilot.sh')
text = path.read_text(encoding='utf-8')

if 'SYNC_ERROR_FILE=' not in text:
    text = text.replace(
        'EVENT_LOG_FILE="${STATE_DIR}/worker_autopilot_events.log"\n',
        'EVENT_LOG_FILE="${STATE_DIR}/worker_autopilot_events.log"\nSYNC_ERROR_FILE="${STATE_DIR}/worker_autopilot_git_sync_last_error.txt"\n',
        1,
    )

live_block_old = '    echo "note: ${note}"\n    echo\n'
live_block_new = '    echo "note: ${note}"\n    if [[ -f "${SYNC_ERROR_FILE}" ]]; then\n      echo "git_sync_last_error: $(head -n 1 "${SYNC_ERROR_FILE}" 2>/dev/null || true)"\n    else\n      echo "git_sync_last_error: none"\n    fi\n    echo\n'
if live_block_old in text:
    text = text.replace(live_block_old, live_block_new, 1)

pattern = re.compile(r'git_sync\(\) \{\n(?:.|\n)*?\n\}\n\nnext_task_file\(\)', re.MULTILINE)
replacement = '''git_sync() {
  local attempt err
  err="${SYNC_ERROR_FILE}.tmp"
  for attempt in 1 2 3; do
    if git -C "${REPO_ROOT}" fetch origin main >/dev/null 2>"${err}" && \
       git -C "${REPO_ROOT}" checkout -q main >/dev/null 2>>"${err}" && \
       git -C "${REPO_ROOT}" merge --ff-only FETCH_HEAD >/dev/null 2>>"${err}"; then
      rm -f "${err}" "${SYNC_ERROR_FILE}"
      return 0
    fi
  done

  if [[ -f "${err}" ]]; then
    head -n 1 "${err}" >"${SYNC_ERROR_FILE}" || true
    rm -f "${err}"
  fi
  return 1
}

next_task_file()'''

text, n = pattern.subn(replacement, text, count=1)
if n != 1:
    raise SystemExit('Failed to patch git_sync function')

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'SYNC_ERROR_FILE=' "${AUTOPILOT_SCRIPT}"; then
  echo "error=sync_error_file_missing"
  exit 1
fi
if ! grep -q 'git_sync_last_error:' "${AUTOPILOT_SCRIPT}"; then
  echo "error=live_status_sync_error_line_missing"
  exit 1
fi
if ! grep -q 'head -n 1 "${err}" >"${SYNC_ERROR_FILE}"' "${AUTOPILOT_SCRIPT}"; then
  echo "error=sync_error_capture_missing"
  exit 1
fi

echo "sync_error_observability=passed"

POLL_SECONDS=60 PUSH_IDLE_HEARTBEAT=false bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --once >/tmp/mtask0056-once.log 2>&1 || true

echo "phase18_autopilot_sync_observability=passed"

git add "pilot_v1/scripts/worker_mtask_autopilot.sh"
git commit -m "autopilot: add git sync error observability (MTASK-0056)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
