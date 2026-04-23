#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
AUTOPILOT_FILE="${REPO_ROOT}/pilot_v1/scripts/worker_mtask_autopilot.sh"

cd "${REPO_ROOT}"

echo "task=MTASK-0069"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/scripts/worker_mtask_autopilot.sh')
text = path.read_text(encoding='utf-8')

if 'WORKER_LOG_TZ=' not in text:
    text = text.replace(
        'WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"\n',
        'WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"\nWORKER_LOG_TZ="${WORKER_LOG_TZ:-America/New_York}"\n'
    )

if 'now_local_ts()' not in text:
    text = text.replace(
        'now_epoch() {\n  date -u +"%s"\n}\n\n\n\n',
        'now_epoch() {\n  date -u +"%s"\n}\n\nnow_local_ts() {\n  TZ="${WORKER_LOG_TZ}" date +"%Y-%m-%dT%H:%M:%S%:z"\n}\n\n\n'
    )

text = text.replace(
    """for line in lines:
    m = re.match(r'^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})Z', line)
    if not m:
        continue
    stamps.append(datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    if len(stamps) >= 4:
        break
""",
    """for line in lines:
    token = line.split(" | ", 1)[0].strip()
    if not token:
        continue
    token_iso = token.replace("Z", "+00:00")
    try:
        parsed = datetime.datetime.fromisoformat(token_iso)
    except ValueError:
        continue
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    stamps.append(parsed.astimezone(datetime.timezone.utc))
    if len(stamps) >= 4:
        break
"""
)

text = text.replace(
    '  local ts\n  ts="$(now_utc)"\n\n  local event_line\n  event_line="${ts} | mode=${mode} | last_task=${last_task} | note=${note}"\n',
    '  local ts ts_local\n  ts="$(now_utc)"\n  ts_local="$(now_local_ts)"\n\n  local event_line\n  event_line="${ts_local} | mode=${mode} | last_task=${last_task} | note=${note}"\n'
)

if '"last_run_local": "${ts_local}"' not in text:
    text = text.replace(
        '  "last_run_utc": "${ts}",\n',
        '  "last_run_utc": "${ts}",\n  "last_run_local": "${ts_local}",\n  "log_timezone": "${WORKER_LOG_TZ}",\n'
    )

if 'echo "updated_local: ${ts_local}"' not in text:
    text = text.replace(
        '    echo "updated_utc: ${ts}"\n',
        '    echo "updated_utc: ${ts}"\n    echo "updated_local: ${ts_local}"\n    echo "log_timezone: ${WORKER_LOG_TZ}"\n'
    )

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'WORKER_LOG_TZ="${WORKER_LOG_TZ:-America/New_York}"' "${AUTOPILOT_FILE}"; then
  echo "error=worker_log_timezone_var_missing"
  exit 1
fi
if ! grep -q '^now_local_ts() {' "${AUTOPILOT_FILE}"; then
  echo "error=now_local_ts_missing"
  exit 1
fi
if ! grep -q 'Task picked up; starting executor' "${AUTOPILOT_FILE}"; then
  echo "error=autopilot_pickup_log_missing"
  exit 1
fi
if ! grep -q 'event_line="${ts_local} | mode=' "${AUTOPILOT_FILE}"; then
  echo "error=event_line_not_local_timezone"
  exit 1
fi
if ! grep -q '"last_run_local": "${ts_local}"' "${AUTOPILOT_FILE}"; then
  echo "error=status_local_timestamp_missing"
  exit 1
fi
if ! grep -q 'updated_local: ${ts_local}' "${AUTOPILOT_FILE}"; then
  echo "error=live_status_local_timestamp_missing"
  exit 1
fi
if ! grep -q 'datetime.datetime.fromisoformat' "${AUTOPILOT_FILE}"; then
  echo "error=sync_gate_parser_not_timezone_aware"
  exit 1
fi

echo "worker_log_timezone_eastern=passed"
echo "phase31_worker_log_timezone=passed"

git add "pilot_v1/scripts/worker_mtask_autopilot.sh"
git commit -m "worker: use America/New_York timestamps in autopilot logs (MTASK-0069)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
