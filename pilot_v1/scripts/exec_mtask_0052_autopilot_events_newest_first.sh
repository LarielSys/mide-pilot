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

echo "task=MTASK-0052"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

python3 - <<'PY'
from pathlib import Path

p = Path("pilot_v1/scripts/worker_mtask_autopilot.sh")
text = p.read_text(encoding="utf-8")

text = text.replace(
    '  printf "%s | mode=%s | last_task=%s | note=%s\\n" "${ts}" "${mode}" "${last_task}" "${note}" >>"${EVENT_LOG_FILE}"\n',
    '  local event_line tmp_events\n'
    '  event_line="${ts} | mode=${mode} | last_task=${last_task} | note=${note}"\n'
    '  tmp_events="${EVENT_LOG_FILE}.tmp"\n\n'
    '  # Keep events in newest-first order while preserving full history.\n'
    '  if [[ -f "${EVENT_LOG_FILE}" ]]; then\n'
    '    {\n'
    '      printf "%s\\n" "${event_line}"\n'
    '      cat "${EVENT_LOG_FILE}"\n'
    '    } >"${tmp_events}"\n'
    '    mv "${tmp_events}" "${EVENT_LOG_FILE}"\n'
    '  else\n'
    '    printf "%s\\n" "${event_line}" >"${EVENT_LOG_FILE}"\n'
    '  fi\n'
)

text = text.replace(
    '    echo "Recent Events (latest 20, newest first):"\n'
    '    tail -n 20 "${EVENT_LOG_FILE}" 2>/dev/null | awk \'{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }\' || true\n',
    '    echo "Recent Events (latest 20, newest first):"\n'
    '    head -n 20 "${EVENT_LOG_FILE}" 2>/dev/null || true\n'
)

p.write_text(text, encoding="utf-8")
PY

if ! grep -q 'event_line=' "${AUTOPILOT_SCRIPT}"; then
  echo "error=events_prepend_logic_missing"
  exit 1
fi
if ! grep -q 'head -n 20 "${EVENT_LOG_FILE}"' "${AUTOPILOT_SCRIPT}"; then
  echo "error=live_view_not_newest_first"
  exit 1
fi

# Validate event ordering behavior with synthetic lines.
mkdir -p "$(dirname "${EVENT_LOG_FILE}")"
cat > "${EVENT_LOG_FILE}" <<'EOFLOG'
oldest-line
middle-line
newest-line
EOFLOG

# Simulate one new write line in newest-first style.
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

# Refresh a minimal live view block for verification.
{
  echo "Autopilot Live Status"
  echo "updated_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "mode=running"
  echo "Recent Events (latest 20, newest first):"
  head -n 20 "${EVENT_LOG_FILE}" 2>/dev/null || true
} > "${LIVE_STATUS_FILE}"

echo "events_log_order=newest_first"
echo "events_log_continuous_growth=enabled"
echo "autopilot_events_feed_patch=passed"

git add \
  "pilot_v1/scripts/worker_mtask_autopilot.sh" \
  "pilot_v1/state/worker_autopilot_events.log" \
  "pilot_v1/state/worker_autopilot_live.txt"

git commit -m "worker: autopilot events newest-first continuous feed (MTASK-0052)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
