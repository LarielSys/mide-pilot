#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TASK_DIR="${REPO_ROOT}/pilot_v1/tasks"
RESULT_DIR="${REPO_ROOT}/pilot_v1/results"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
RUNTIME_DIR="${HOME}/.config/mide"
LOCK_FILE="${RUNTIME_DIR}/worker_mtask_autopilot.lock"
STATUS_FILE="${STATE_DIR}/worker_autopilot_status.json"
HEARTBEAT_FILE="${STATE_DIR}/worker_autopilot_heartbeat_epoch.txt"
LIVE_STATUS_FILE="${STATE_DIR}/worker_autopilot_live.txt"
EVENT_LOG_FILE="${STATE_DIR}/worker_autopilot_events.log"
SYNC_ERROR_FILE="${STATE_DIR}/worker_autopilot_git_sync_last_error.txt"
POLL_SECONDS="${POLL_SECONDS:-60}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
ADMIN_PASSWORD_SHA256="${ADMIN_PASSWORD_SHA256:-}"
ADMIN_OVERRIDE_PASSWORD="${ADMIN_OVERRIDE_PASSWORD:-}"
PUSH_IDLE_HEARTBEAT="${PUSH_IDLE_HEARTBEAT:-true}"
DRY_RUN="false"
ONESHOT="false"
FORCE_TASK_ID=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN="true"
      ;;
    --once)
      ONESHOT="true"
      ;;
    --worker-id=*)
      WORKER_ID="${arg#*=}"
      ;;
    --poll-seconds=*)
      POLL_SECONDS="${arg#*=}"
      ;;
    --force-task=*)
      FORCE_TASK_ID="${arg#*=}"
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

mkdir -p "${STATE_DIR}" "${RESULT_DIR}" "${RUNTIME_DIR}"

cleanup() {
  rm -f "${LOCK_FILE}"
}

trap cleanup EXIT

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

now_epoch() {
  date -u +"%s"
}

write_status() {
  local mode="$1"
  local last_task="$2"
  local note="$3"
  local ts
  ts="$(now_utc)"

  local event_line
  event_line="${ts} | mode=${mode} | last_task=${last_task} | note=${note}"
  printf "%s\n" "${event_line}" >>"${EVENT_LOG_FILE}"

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
    if [[ -f "${SYNC_ERROR_FILE}" ]]; then
      echo "git_sync_last_error: $(head -n 1 "${SYNC_ERROR_FILE}" 2>/dev/null || true)"
    else
      echo "git_sync_last_error: none"
    fi
    echo
    echo "Recent Events (latest 20, newest first):"
    tail -n 20 "${EVENT_LOG_FILE}" 2>/dev/null | tac || true
  } >"${LIVE_STATUS_FILE}"
}

hash_sha256() {
  local input="$1"
  python3 - "$input" <<'PY'
import hashlib
import sys

text = sys.argv[1]
print(hashlib.sha256(text.encode("utf-8")).hexdigest())
PY
}

admin_override_authorized() {
  if [[ -z "${ADMIN_PASSWORD_SHA256}" || -z "${ADMIN_OVERRIDE_PASSWORD}" ]]; then
    return 1
  fi
  [[ "$(hash_sha256 "${ADMIN_OVERRIDE_PASSWORD}")" == "${ADMIN_PASSWORD_SHA256}" ]]
}

queue_summary() {
  python3 - "$TASK_DIR" "$RESULT_DIR" "$WORKER_ID" <<'PY'
import glob
import json
import os
import sys

task_dir, result_dir, worker_id = sys.argv[1:4]
approved_total = 0
eligible = 0
mismatch = 0

for pattern in ("TASK-*.json", "MTASK-*.json"):
  for path in glob.glob(os.path.join(task_dir, pattern)):
    try:
      with open(path, "r", encoding="utf-8") as f:
        task = json.load(f)
    except Exception:
      continue

    if task.get("status") != "approved_to_execute":
      continue

    approved_total += 1
    task_id = task.get("task_id", "")
    if not task_id:
      continue

    result_path = os.path.join(result_dir, f"{task_id}.result.json")
    if os.path.exists(result_path):
      continue

    task_worker = task.get("required_worker_id") or task.get("assigned_to")
    if task_worker == worker_id:
      eligible += 1
    else:
      mismatch += 1

print(f"{approved_total}|{eligible}|{mismatch}")
PY
}

commit_and_push_status_heartbeat() {
  local ts
  ts="$(now_epoch)"
  echo "${ts}" >"${HEARTBEAT_FILE}"

  git -C "${REPO_ROOT}" add "pilot_v1/state/worker_autopilot_status.json" "pilot_v1/state/worker_autopilot_live.txt" "pilot_v1/state/worker_autopilot_events.log" "pilot_v1/state/worker_autopilot_heartbeat_epoch.txt" || true
  git -C "${REPO_ROOT}" commit -m "worker: autopilot heartbeat ${WORKER_ID} ${ts}" >/dev/null || true
  git -C "${REPO_ROOT}" push origin main >/dev/null || {
    echo "[autopilot] Warning: heartbeat push failed; will retry next cycle." >&2
  }
}

git_sync() {
  local attempt err sync_ok
  err="${SYNC_ERROR_FILE}.tmp"

  for attempt in 1 2 3; do
    sync_ok="false"

    if git -C "${REPO_ROOT}" fetch origin main >/dev/null 2>"${err}" && \
       git -C "${REPO_ROOT}" checkout -q main >/dev/null 2>>"${err}" && \
       git -C "${REPO_ROOT}" merge --ff-only FETCH_HEAD >/dev/null 2>>"${err}"; then
      sync_ok="true"
    else
      # Fallback path: preserve local changes while rebasing to remote tip.
      if git -C "${REPO_ROOT}" checkout -q main >/dev/null 2>>"${err}" && \
         git -C "${REPO_ROOT}" pull --rebase --autostash origin main >/dev/null 2>>"${err}"; then
        sync_ok="true"
      fi
    fi

    if [[ "${sync_ok}" == "true" ]]; then
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

next_task_file() {
  python3 - "$TASK_DIR" "$RESULT_DIR" "$WORKER_ID" <<'PY'
import glob
import json
import os
import sys

task_dir, result_dir, worker_id = sys.argv[1:4]

candidates = []
for pattern in ("TASK-*.json", "MTASK-*.json"):
  for path in glob.glob(os.path.join(task_dir, pattern)):
    try:
      with open(path, "r", encoding="utf-8") as f:
        task = json.load(f)
    except Exception:
      continue

    task_id = task.get("task_id", "")
    if not task_id:
      continue
    task_worker = task.get("required_worker_id") or task.get("assigned_to")
    if task_worker != worker_id:
      continue
    if task.get("status") != "approved_to_execute":
      continue

    result_path = os.path.join(result_dir, f"{task_id}.result.json")
    if os.path.exists(result_path):
      continue

    candidates.append((task_id, path))

candidates.sort(key=lambda x: x[0])
if candidates:
    print(candidates[0][1])
PY
}

force_task_file() {
  if [[ -z "${FORCE_TASK_ID}" ]]; then
    return 0
  fi

  local task_file="${TASK_DIR}/${FORCE_TASK_ID}.json"
  if [[ ! -f "${task_file}" ]]; then
    echo "[autopilot] Forced task not found: ${FORCE_TASK_ID}" >&2
    return 1
  fi

  echo "${task_file}"
}

task_field() {
  local task_file="$1"
  local field_name="$2"
  python3 - "$task_file" "$field_name" <<'PY'
import json
import sys

path, field = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data.get(field, "")
if value is None:
    value = ""
print(value)
PY
}

write_result_json() {
  local result_file="$1"
  local task_id="$2"
  local status="$3"
  local summary="$4"
  local stdout_file="$5"
  local stderr_file="$6"

  python3 - "$result_file" "$task_id" "$status" "$summary" "$stdout_file" "$stderr_file" "$WORKER_ID" <<'PY'
import datetime
import json
import pathlib
import sys

result_file, task_id, status, summary, stdout_file, stderr_file, worker_id = sys.argv[1:8]

def load_excerpt(path):
    p = pathlib.Path(path)
    if not p.exists():
        return ""
    text = p.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    max_lines = 120
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
    return "\n".join(lines)

payload = {
    "task_id": task_id,
    "worker_id": worker_id,
    "execution_status": status,
    "summary": summary,
    "stdout_excerpt": load_excerpt(stdout_file),
    "stderr_excerpt": load_excerpt(stderr_file),
    "timestamp_utc": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
}

pathlib.Path(result_file).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

commit_and_push_result() {
  local task_id="$1"
  git -C "${REPO_ROOT}" add "pilot_v1/results/${task_id}.result.json" "pilot_v1/state/worker_autopilot_status.json" "pilot_v1/state/worker_autopilot_live.txt" "pilot_v1/state/worker_autopilot_events.log" || true
  git -C "${REPO_ROOT}" commit -m "worker: autopilot result ${task_id}" >/dev/null || true
  git -C "${REPO_ROOT}" push origin main >/dev/null || {
    echo "[autopilot] Warning: push failed for ${task_id}; result remains local until next successful push." >&2
  }
}

process_task() {
  local task_file="$1"
  local task_id executor_script assigned_to required_worker_id
  task_id="$(task_field "${task_file}" "task_id")"
  executor_script="$(task_field "${task_file}" "executor_script")"
  assigned_to="$(task_field "${task_file}" "assigned_to")"
  required_worker_id="$(task_field "${task_file}" "required_worker_id")"

  if [[ -z "${task_id}" ]]; then
    return 1
  fi

  if [[ -z "${required_worker_id}" ]]; then
    required_worker_id="${assigned_to}"
  fi

  if [[ "${required_worker_id}" != "${WORKER_ID}" ]]; then
    if [[ -n "${FORCE_TASK_ID}" && "${FORCE_TASK_ID}" == "${task_id}" ]] && admin_override_authorized; then
      echo "[autopilot] Admin override accepted for ${task_id} (required_worker_id=${required_worker_id}, worker_id=${WORKER_ID})."
    else
      echo "[autopilot] Ignoring ${task_id}: required_worker_id=${required_worker_id}, worker_id=${WORKER_ID}."
      return 0
    fi
  fi

  echo "[autopilot] Candidate task: ${task_id} (${task_file})"

  if [[ "${DRY_RUN}" == "true" ]]; then
    write_status "dry-run" "${task_id}" "Candidate mtask detected; no execution in dry-run mode."
    return 0
  fi

  local stdout_tmp stderr_tmp result_file
  stdout_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  result_file="${RESULT_DIR}/${task_id}.result.json"

  if [[ -z "${executor_script}" ]]; then
    write_result_json "${result_file}" "${task_id}" "failed" "Missing required executor_script field in task." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task failed: missing executor_script."
    commit_and_push_result "${task_id}"
    rm -f "${stdout_tmp}" "${stderr_tmp}"
    return 0
  fi

  local script_abs="${REPO_ROOT}/${executor_script}"
  if [[ ! -f "${script_abs}" ]]; then
    echo "Executor script not found: ${executor_script}" >"${stderr_tmp}"
    write_result_json "${result_file}" "${task_id}" "failed" "Executor script not found." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task failed: executor script not found."
    commit_and_push_result "${task_id}"
    rm -f "${stdout_tmp}" "${stderr_tmp}"
    return 0
  fi

  echo "[autopilot] Executing ${executor_script} for ${task_id}"
  if bash "${script_abs}" >"${stdout_tmp}" 2>"${stderr_tmp}"; then
    write_result_json "${result_file}" "${task_id}" "completed" "Executor script completed successfully." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task completed successfully."
  else
    write_result_json "${result_file}" "${task_id}" "failed" "Executor script exited with non-zero status." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task failed: executor script non-zero exit."
  fi

  commit_and_push_result "${task_id}"
  rm -f "${stdout_tmp}" "${stderr_tmp}"
}

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "Autopilot already running for worker ${WORKER_ID}."
  exit 0
fi

write_status "running" "" "Autopilot started."

while true; do
  if ! git_sync; then
    write_status "running" "" "Warning: git_sync failed; retrying next poll."
    sleep "${POLL_SECONDS}"
    continue
  fi

  queue_stats="$(queue_summary)"
  approved_total="${queue_stats%%|*}"
  remaining_stats="${queue_stats#*|}"
  eligible_count="${remaining_stats%%|*}"
  mismatch_count="${remaining_stats#*|}"

  processed_any="false"

  if [[ -n "${FORCE_TASK_ID}" ]]; then
    task_file="$(force_task_file || true)"
    if [[ -n "${task_file}" ]]; then
      process_task "${task_file}"
      processed_any="true"
    fi

    write_status "idle" "${FORCE_TASK_ID}" "Forced task cycle finished."
    break
  fi

  while true; do
    task_file="$(next_task_file || true)"
    if [[ -z "${task_file}" ]]; then
      break
    fi

    process_task "${task_file}"
    processed_any="true"

    if [[ "${DRY_RUN}" == "true" ]]; then
      break
    fi

    # Immediately check for the next task after each completion.
    if ! git_sync; then
      echo "[autopilot] Warning: git_sync failed after task completion; continuing with local queue state." >&2
    fi
  done

  if [[ "${ONESHOT}" == "true" ]]; then
    write_status "idle" "" "Autopilot one-shot cycle finished. approved=${approved_total}, eligible=${eligible_count}, mismatched=${mismatch_count}."
    break
  fi

  if [[ "${processed_any}" == "false" ]]; then
    write_status "idle" "" "No assigned mtasks found; sleeping until next poll. approved=${approved_total}, eligible=${eligible_count}, mismatched=${mismatch_count}."

    if [[ "${PUSH_IDLE_HEARTBEAT}" == "true" ]]; then
      commit_and_push_status_heartbeat
    fi
  fi

  sleep "${POLL_SECONDS}"
done
