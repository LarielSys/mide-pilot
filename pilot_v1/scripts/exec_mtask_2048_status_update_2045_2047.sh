#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-2048"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULT_DIR="${REPO_ROOT}/pilot_v1/results"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
RESULT_FILE="${RESULT_DIR}/${TASK_ID}.result.json"
RESULT_2045="${RESULT_DIR}/MTASK-2045.result.json"
RESULT_2047="${RESULT_DIR}/MTASK-2047.result.json"
SERVICES_FILE="${STATE_DIR}/worker1_services.json"
AUTOPILOT_LOG="${STATE_DIR}/worker_mtask_autopilot.log"

mkdir -p "${RESULT_DIR}" "${STATE_DIR}"

python3 - "${RESULT_FILE}" "${RESULT_2045}" "${RESULT_2047}" "${SERVICES_FILE}" "${AUTOPILOT_LOG}" <<'PY'
import datetime
import json
import os
import pathlib
import re
import sys

result_file, path_2045, path_2047, services_file, autopilot_log = sys.argv[1:6]


def utc_now():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    p = pathlib.Path(path)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"_parse_error": True}


def file_mtime_utc(path):
    p = pathlib.Path(path)
    if not p.exists():
        return ""
    ts = datetime.datetime.utcfromtimestamp(p.stat().st_mtime)
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def target_status(task_id, path):
    data = load_json(path)
    if data is None:
        return {
            "task_id": task_id,
            "result_present": False,
            "execution_status": "missing",
            "summary": "Result file not found on worker.",
            "result_updated_utc": "",
        }
    if data.get("_parse_error"):
        return {
            "task_id": task_id,
            "result_present": True,
            "execution_status": "invalid_json",
            "summary": "Result file exists but could not be parsed.",
            "result_updated_utc": file_mtime_utc(path),
        }
    return {
        "task_id": task_id,
        "result_present": True,
        "execution_status": str(data.get("execution_status", "unknown")),
        "summary": str(data.get("summary", "")),
        "result_updated_utc": file_mtime_utc(path),
    }


def read_autopilot_evidence(path):
    p = pathlib.Path(path)
    if not p.exists():
        return []
    lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
    needle = re.compile(r"MTASK-(2045|2047)")
    matches = [line for line in lines if needle.search(line)]
    return matches[-20:]


status_2045 = target_status("MTASK-2045", path_2045)
status_2047 = target_status("MTASK-2047", path_2047)
services = load_json(services_file)

if services is None:
    services_note = "worker1_services.json missing"
elif services.get("_parse_error"):
    services_note = "worker1_services.json parse_error"
else:
    services_note = "worker1_services.json present"

if not status_2045["result_present"] and not status_2047["result_present"]:
    overall = "failed"
    summary = "Status request completed, but neither MTASK-2045 nor MTASK-2047 result file is present."
else:
    overall = "completed"
    summary = (
        f"Status update collected: MTASK-2045={status_2045['execution_status']}, "
        f"MTASK-2047={status_2047['execution_status']}."
    )

payload = {
    "task_id": "MTASK-2048",
    "worker_id": "ubuntu-worker-01",
    "execution_status": overall,
    "summary": summary,
    "targets": {
        "MTASK-2045": status_2045,
        "MTASK-2047": status_2047,
    },
    "worker_services_note": services_note,
    "autopilot_log_mentions": read_autopilot_evidence(autopilot_log),
    "timestamp_utc": utc_now(),
}

pathlib.Path(result_file).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

cd "${REPO_ROOT}"
git add "${RESULT_FILE}" || true

echo "[${TASK_ID}] status_update_written=${RESULT_FILE}"
exit 0