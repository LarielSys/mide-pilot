#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"

cd "${REPO_ROOT}"

echo "task=MTASK-0055"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

# Robust sync for executor itself.
git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path
import re

path = Path('pilot_v1/scripts/worker_mtask_autopilot.sh')
text = path.read_text(encoding='utf-8')

pattern = re.compile(
    r"git_sync\(\) \{\n(?:.|\n)*?\n\}\n\nnext_task_file\(\)",
    re.MULTILINE,
)

replacement = '''git_sync() {
  local attempt
  for attempt in 1 2 3; do
    if git -C "${REPO_ROOT}" fetch origin main >/dev/null 2>&1 && \
       git -C "${REPO_ROOT}" checkout -q main >/dev/null 2>&1 && \
       git -C "${REPO_ROOT}" merge --ff-only FETCH_HEAD >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

next_task_file()'''

new_text, n = pattern.subn(replacement, text, count=1)
if n != 1:
    raise SystemExit('Failed to patch git_sync function')

path.write_text(new_text, encoding='utf-8')
PY

if ! grep -q 'for attempt in 1 2 3' "${AUTOPILOT_SCRIPT}"; then
  echo "error=git_sync_retry_loop_missing"
  exit 1
fi
if ! grep -q 'merge --ff-only FETCH_HEAD' "${AUTOPILOT_SCRIPT}"; then
  echo "error=git_sync_ff_merge_missing"
  exit 1
fi

echo "git_sync_retry_logic=passed"

POLL_SECONDS=60 PUSH_IDLE_HEARTBEAT=false bash "${AUTOPILOT_SCRIPT}" --worker-id="${WORKER_ID}" --once >/tmp/mtask0055-once.log 2>&1 || {
  echo "error=autopilot_oneshot_failed"
  tail -n 80 /tmp/mtask0055-once.log || true
  exit 1
}

echo "git_sync_smoke=passed"

git add "pilot_v1/scripts/worker_mtask_autopilot.sh"
git commit -m "autopilot: harden git sync with retry ff-merge loop (MTASK-0055)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
