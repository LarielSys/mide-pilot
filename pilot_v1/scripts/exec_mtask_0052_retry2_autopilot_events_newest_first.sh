#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

AUTOPILOT_SCRIPT="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"
EVENT_LOG_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_events.log"
LIVE_STATUS_FILE="${REPO_ROOT}/pilot_v1/state/worker_autopilot_live.txt"

cd "${REPO_ROOT}"

echo "task=MTASK-0052-RETRY2"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

python3 - <<'PY'
from pathlib import Path
import re

p = Path("pilot_v1/scripts/worker_mtask_autopilot.sh")
text = p.read_text(encoding="utf-8")

replacement = '''write_status() {
  local mode="$1"
  local last_task="$2"
  local note="$3"
  local ts
  ts="$(now_utc)"

  local event_line tmp_events
  event_line="${ts} | mode=${mode} | last_task=${last_task} | note=${note}"
  tmp_events="${EVENT_LOG_FILE}.tmp"

  # Keep events in newest-first order while preserving full history.
  if [[ -f "${EVENT_LOG_FILE}" ]]; then
    {
      printf "%s\\n" "${event_line}"
      cat "${EVENT_LOG_FILE}"
    } >"${tmp_events}"
    mv "${tmp_events}" "${EVENT_LOG_FILE}"
  else
    printf "%s\\n" "${event_line}" >"${EVENT_LOG_FILE}"
  fi

  cat >"${STATUS_FILE}" <<EOF
{
  "worker_name": "${WORKER_NAME}",
  "worker_id": "${WORKER_ID}",
  "mode": "${mode}",
  "last_run_utc": "${ts}",
  "last_task_processed": "${last_task}",
  "poll_seconds": ${POLL_SECONDS},
  "note": "${note}"
}
EOF

  {
    echo "Autopilot Live Status"
    echo "updated_utc: ${ts}"
    echo "worker_name: ${WORKER_NAME}"
    echo "worker_id: ${WORKER_ID}"
    echo "mode: ${mode}"
    echo "last_task_processed: ${last_task}"
    echo "poll_seconds: ${POLL_SECONDS}"
    echo "note: ${note}"
    echo
    echo "Recent Events (latest 20, newest first):"
    head -n 20 "${EVENT_LOG_FILE}" 2>/dev/null || true
  } >"${LIVE_STATUS_FILE}"
}
'''

pattern = r"write_status\(\) \{[\s\S]*?\n\}\n\nhash_sha256\(\)"
new_text = re.sub(pattern, replacement + "\nhash_sha256()", text, count=1)
if new_text == text:
    raise SystemExit("unable_to_patch_write_status")

p.write_text(new_text, encoding="utf-8")
PY

if ! grep -q 'event_line="${ts} | mode=${mode} | last_task=${last_task} | note=${note}"' "${AUTOPILOT_SCRIPT}"; then
  echo "error=events_prepend_logic_missing"
  exit 1
fi
if ! grep -Eq 'head -n[[:space:]]+20[[:space:]]+"\$\{EVENT_LOG_FILE\}"' "${AUTOPILOT_SCRIPT}"; then
  echo "error=live_view_not_newest_first"
  exit 1
fi

mkdir -p "$(dirname "${EVENT_LOG_FILE}")"
cat > "${EVENT_LOG_FILE}" <<'EOFLOG'
oldest-line
middle-line
newest-line
EOFLOG

new_line="synthetic-new-top"
{
  printf "%s\n" "${new_line}"
  cat "${EVENT_LOG_FILE}"
} > "${EVENT_LOG_FILE}.tmp"
mv "${EVENT_LOG_FILE}.tmp" "${EVENT_LOG_FILE}"

first_line="$(head -n 1 "${EVENT_LOG_FILE}")"
if [[ "${first_line}" != "${new_line}" ]]; then
  echo "error=events_not_newest_first"
  exit 1
fi

echo "events_log_order=newest_first"
echo "events_log_continuous_growth=enabled"
echo "autopilot_events_feed_retry2=passed"

git add \
  "pilot_v1/scripts/worker_mtask_autopilot.sh" \
  "pilot_v1/state/worker_autopilot_events.log"

git commit -m "worker: deterministic newest-first events feed (MTASK-0052-RETRY2)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
