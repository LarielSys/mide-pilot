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
STACK_HEALTH_FILE="${STATE_DIR}/customide_stack_health.json"
LAST_PUSHED_SIGNATURE_FILE="${RUNTIME_DIR}/worker_autopilot_last_pushed_signature.txt"
LAST_PUSHED_EPOCH_FILE="${RUNTIME_DIR}/worker_autopilot_last_pushed_epoch.txt"
LAST_STACK_STATE_FILE="${RUNTIME_DIR}/customide_stack_last_state.txt"
POLL_SECONDS="${POLL_SECONDS:-60}"
HEARTBEAT_PUSH_MAX_AGE_SECONDS="${HEARTBEAT_PUSH_MAX_AGE_SECONDS:-90}"
CUSTOMIDE_BACKEND_HEALTH_URL="${CUSTOMIDE_BACKEND_HEALTH_URL:-http://127.0.0.1:5555/health}"
CUSTOMIDE_FRONTEND_HEALTH_URL="${CUSTOMIDE_FRONTEND_HEALTH_URL:-http://127.0.0.1:5570}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_LOG_TZ="${WORKER_LOG_TZ:-America/New_York}"
ADMIN_PASSWORD_SHA256="${ADMIN_PASSWORD_SHA256:-}"
ADMIN_OVERRIDE_PASSWORD="${ADMIN_OVERRIDE_PASSWORD:-}"
PUSH_IDLE_HEARTBEAT="${PUSH_IDLE_HEARTBEAT:-true}"
DRY_RUN="false"
ONESHOT="false"
FORCE_TASK_ID=""
CURRENT_STATUS_SIGNATURE=""

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

touch "${EVENT_LOG_FILE}"

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

now_local_ts() {
  TZ="${WORKER_LOG_TZ}" date +"%Y-%m-%dT%H:%M:%S%:z"
}

sanitize_event_log() {
  python3 - "${EVENT_LOG_FILE}" "${WORKER_LOG_TZ}" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo
import sys

event_file = Path(sys.argv[1])
tz_name = sys.argv[2]

if not event_file.exists():
  raise SystemExit(0)

try:
  target_tz = ZoneInfo(tz_name)
except Exception:
  target_tz = timezone.utc

raw_lines = event_file.read_text(encoding="utf-8", errors="replace").splitlines()
normalized_lines = []
changed = False

for raw in raw_lines:
  line = raw.strip()
  if not line:
    changed = True
    continue

  if " | " not in line:
    changed = True
    continue

  token, remainder = line.split(" | ", 1)
  token = token.strip().lstrip("Z").strip()
  token = token.replace("Z", "+00:00")

  try:
    parsed = datetime.fromisoformat(token)
  except ValueError:
    changed = True
    continue

  if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)

  local_ts = parsed.astimezone(target_tz).isoformat(timespec="seconds")
  rebuilt = f"{local_ts} | {remainder.strip()}"
  normalized_lines.append(rebuilt)
  if rebuilt != line:
    changed = True

if changed:
  event_file.write_text("\n".join(normalized_lines) + ("\n" if normalized_lines else ""), encoding="utf-8")
PY
}

status_signature() {
  local mode="$1"
  local last_task="$2"
  local note="$3"
  printf "%s|%s|%s|%s|%s" "${WORKER_ID}" "${POLL_SECONDS}" "${mode}" "${last_task}" "${note}"
}

sync_gate_3x60_state() {
  python3 - "${EVENT_LOG_FILE}" <<'PY'
import datetime
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("missing")
    raise SystemExit(0)

stamps = []
for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
    token = raw.split(" | ", 1)[0].strip()
    if not token:
        continue
    token = token.replace("Z", "+00:00")
    try:
        parsed = datetime.datetime.fromisoformat(token)
    except ValueError:
        continue
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    stamps.append(parsed.astimezone(datetime.timezone.utc))
    if len(stamps) >= 4:
        break

if len(stamps) < 4:
    print("insufficient")
    raise SystemExit(0)

deltas = [(stamps[i] - stamps[i + 1]).total_seconds() for i in range(3)]
print("pass" if all(55 <= d <= 65 for d in deltas) else "drift")
PY
}

write_status() {
  local mode="$1"
  local last_task="$2"
  local note="$3"
  local ts ts_local gate_state sig git_branch git_local_head git_origin_head git_heads_match
  local backend_state frontend_state stack_state last_stack_state
  sanitize_event_log
  ts="$(now_utc)"
  ts_local="$(now_local_ts)"
  gate_state="$(sync_gate_3x60_state)"

  if curl -fsS --max-time 2 "${CUSTOMIDE_BACKEND_HEALTH_URL}" >/dev/null 2>&1; then
    backend_state="up"
  else
    backend_state="down"
  fi

  if curl -fsS --max-time 2 "${CUSTOMIDE_FRONTEND_HEALTH_URL}" >/dev/null 2>&1; then
    frontend_state="up"
  else
    frontend_state="down"
  fi

  if [[ "${backend_state}" == "up" && "${frontend_state}" == "up" ]]; then
    stack_state="healthy"
  elif [[ "${backend_state}" == "down" && "${frontend_state}" == "down" ]]; then
    stack_state="down"
  else
    stack_state="degraded"
  fi

  sig="$(status_signature "${mode}" "${last_task}" "${note}")"

  git_branch="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  git_local_head="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  git_origin_head="$(git -C "${REPO_ROOT}" rev-parse --short origin/main 2>/dev/null || echo "unknown")"
  if [[ -n "${git_local_head}" && -n "${git_origin_head}" && "${git_local_head}" == "${git_origin_head}" ]]; then
    git_heads_match="yes"
  else
    git_heads_match="no"
  fi

  CURRENT_STATUS_SIGNATURE="${sig}"

  last_stack_state="$(cat "${LAST_STACK_STATE_FILE}" 2>/dev/null || true)"
  if [[ "${stack_state}" != "${last_stack_state}" ]]; then
    printf "%s | mode=%s | last_task=%s | note=CustomIDE stack state changed: %s (backend=%s frontend=%s)\n" "${ts_local}" "${mode}" "${last_task}" "${stack_state}" "${backend_state}" "${frontend_state}" >> "${EVENT_LOG_FILE}"
    printf "%s\n" "${stack_state}" > "${LAST_STACK_STATE_FILE}"
  fi

  printf "%s | mode=%s | last_task=%s | note=%s\n" "${ts_local}" "${mode}" "${last_task}" "${note}" >> "${EVENT_LOG_FILE}"

  python3 - "${STATUS_FILE}" "${WORKER_NAME}" "${WORKER_ID}" "${mode}" "${ts}" "${ts_local}" "${WORKER_LOG_TZ}" "${last_task}" "${POLL_SECONDS}" "${note}" "${backend_state}" "${frontend_state}" "${stack_state}" <<'PY'
import json
import pathlib
import sys

status_file, worker_name, worker_id, mode, ts_utc, ts_local, tz_name, last_task, poll_seconds, note, backend_state, frontend_state, stack_state = sys.argv[1:14]
payload = {
    "worker_name": worker_name,
    "worker_id": worker_id,
    "mode": mode,
    "last_run_utc": ts_utc,
    "last_run_local": ts_local,
    "log_timezone": tz_name,
    "last_task_processed": last_task,
    "poll_seconds": int(poll_seconds),
    "note": note,
    "customide_backend_state": backend_state,
    "customide_frontend_state": frontend_state,
    "customide_stack_state": stack_state,
}
pathlib.Path(status_file).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

    python3 - "${STACK_HEALTH_FILE}" "${ts}" "${ts_local}" "${backend_state}" "${frontend_state}" "${stack_state}" "${CUSTOMIDE_BACKEND_HEALTH_URL}" "${CUSTOMIDE_FRONTEND_HEALTH_URL}" <<'PY'
import json
import pathlib
import sys

health_file, ts_utc, ts_local, backend_state, frontend_state, stack_state, backend_url, frontend_url = sys.argv[1:9]
payload = {
    "timestamp_utc": ts_utc,
    "timestamp_local": ts_local,
    "backend_url": backend_url,
    "frontend_url": frontend_url,
    "backend_state": backend_state,
    "frontend_state": frontend_state,
    "stack_state": stack_state,
}
pathlib.Path(health_file).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

  {
    echo "Autopilot Live Status"
    echo "updated_utc: ${ts}"
    echo "updated_local: ${ts_local}"
    echo "log_timezone: ${WORKER_LOG_TZ}"
    echo "worker_name: ${WORKER_NAME}"
    echo "worker_id: ${WORKER_ID}"
    echo "mode: ${mode}"
    echo "last_task_processed: ${last_task}"
    echo "poll_seconds: ${POLL_SECONDS}"
    echo "note: ${note}"
    echo "sync_gate_3x60: ${gate_state}"
    echo "git_branch: ${git_branch}"
    echo "git_local_head: ${git_local_head}"
    echo "git_origin_head: ${git_origin_head}"
    echo "git_heads_match: ${git_heads_match}"
    echo "customide_backend_state: ${backend_state}"
    echo "customide_frontend_state: ${frontend_state}"
    echo "customide_stack_state: ${stack_state}"
    echo "customide_backend_url: ${CUSTOMIDE_BACKEND_HEALTH_URL}"
    echo "customide_frontend_url: ${CUSTOMIDE_FRONTEND_HEALTH_URL}"
    if [[ -f "${SYNC_ERROR_FILE}" ]]; then
      echo "git_sync_last_error: $(head -n 1 "${SYNC_ERROR_FILE}" 2>/dev/null || true)"
    else
      echo "git_sync_last_error: none"
    fi
    echo
    echo "Recent Events (latest 20, newest first):"
    tail -n 20 "${EVENT_LOG_FILE}" 2>/dev/null | tac || true
  } > "${LIVE_STATUS_FILE}"
}

hash_sha256() {
  local input="$1"
  python3 - "$input" <<'PY'
import hashlib
import sys
print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
}

admin_override_authorized() {
  if [[ -z "${ADMIN_PASSWORD_SHA256}" || -z "${ADMIN_OVERRIDE_PASSWORD}" ]]; then
    return 1
  fi
  [[ "$(hash_sha256 "${ADMIN_OVERRIDE_PASSWORD}")" == "${ADMIN_PASSWORD_SHA256}" ]]
}

queue_summary() {
  python3 - "${TASK_DIR}" "${RESULT_DIR}" "${WORKER_ID}" <<'PY'
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
            task = json.loads(open(path, "r", encoding="utf-8").read())
        except Exception:
            continue

        if task.get("status") != "approved_to_execute":
            continue

        approved_total += 1
        task_id = task.get("task_id", "")
        if not task_id:
            continue

        if os.path.exists(os.path.join(result_dir, f"{task_id}.result.json")):
            continue

        task_worker = task.get("required_worker_id") or task.get("assigned_to")
        if task_worker == worker_id:
            eligible += 1
        else:
            mismatch += 1

print(f"{approved_total}|{eligible}|{mismatch}")
PY
}

git_commit_and_push() {
  local commit_msg="$1"

  # Clear any sticky index flags that would keep tracked state files from staging.
  git -C "${REPO_ROOT}" update-index \
    --no-assume-unchanged \
    --no-skip-worktree \
    "pilot_v1/state/worker_autopilot_status.json" \
    "pilot_v1/state/worker_autopilot_live.txt" \
    "pilot_v1/state/worker_autopilot_events.log" \
    "pilot_v1/state/worker_autopilot_heartbeat_epoch.txt" \
    "pilot_v1/state/worker_autopilot_git_sync_last_error.txt" \
    "pilot_v1/state/customide_stack_health.json" \
    "pilot_v1/state/cockpit_hard_reset_request.json" 2>/dev/null || true

  git -C "${REPO_ROOT}" add -A pilot_v1/state || true
  git -C "${REPO_ROOT}" add pilot_v1/results/*.result.json 2>/dev/null || true

  if ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    git -C "${REPO_ROOT}" commit -m "${commit_msg}" >/dev/null || true
    git -C "${REPO_ROOT}" push origin main >/dev/null || return 1
  fi

  return 0
}

commit_and_push_status_heartbeat() {
  local ts last_sig last_push_epoch age_seconds
  ts="$(now_epoch)"
  echo "${ts}" > "${HEARTBEAT_FILE}"

  if [[ -f "${LAST_PUSHED_SIGNATURE_FILE}" ]]; then
    last_sig="$(cat "${LAST_PUSHED_SIGNATURE_FILE}" 2>/dev/null || true)"
  else
    last_sig=""
  fi

  if [[ -f "${LAST_PUSHED_EPOCH_FILE}" ]]; then
    last_push_epoch="$(cat "${LAST_PUSHED_EPOCH_FILE}" 2>/dev/null || true)"
  else
    last_push_epoch=""
  fi

  if [[ "${CURRENT_STATUS_SIGNATURE}" == "${last_sig}" ]]; then
    if [[ -n "${last_push_epoch}" ]]; then
      age_seconds=$(( ts - last_push_epoch ))
      if (( age_seconds < HEARTBEAT_PUSH_MAX_AGE_SECONDS )); then
        return 0
      fi
    else
      return 0
    fi
  fi

  if git_commit_and_push "worker: autopilot heartbeat ${WORKER_ID} ${ts}"; then
    printf "%s\n" "${CURRENT_STATUS_SIGNATURE}" > "${LAST_PUSHED_SIGNATURE_FILE}"
    printf "%s\n" "${ts}" > "${LAST_PUSHED_EPOCH_FILE}"
    return 0
  fi

  echo "[autopilot] Warning: heartbeat push failed; will retry next cycle." >&2
  return 1
}

git_sync() {
  local attempt err sync_ok
  err="$(mktemp -p "${RUNTIME_DIR}" worker_git_sync_err.XXXXXX)"

  for attempt in 1 2 3; do
    sync_ok="false"

    # Clear stale in-progress git operations that block fetch/rebase flows.
    git -C "${REPO_ROOT}" rebase --abort >/dev/null 2>>"${err}" || true
    git -C "${REPO_ROOT}" merge --abort >/dev/null 2>>"${err}" || true
    git -C "${REPO_ROOT}" cherry-pick --abort >/dev/null 2>>"${err}" || true

    if git -C "${REPO_ROOT}" fetch origin main >/dev/null 2>"${err}" && \
       git -C "${REPO_ROOT}" checkout -q main >/dev/null 2>>"${err}" && \
       git -C "${REPO_ROOT}" merge --ff-only FETCH_HEAD >/dev/null 2>>"${err}"; then
      sync_ok="true"
    elif git -C "${REPO_ROOT}" checkout -q main >/dev/null 2>>"${err}" && \
         git -C "${REPO_ROOT}" pull --rebase --autostash origin main >/dev/null 2>>"${err}"; then
      sync_ok="true"
    fi

    if [[ "${sync_ok}" == "true" ]]; then
      rm -f "${err}" "${SYNC_ERROR_FILE}"
      return 0
    fi
  done

  if [[ -f "${err}" ]]; then
    {
      echo "$(now_utc) | git_sync_failed"
      head -n 20 "${err}"
    } > "${SYNC_ERROR_FILE}" || true
    rm -f "${err}"
  fi
  return 1
}

next_task_file() {
  python3 - "${TASK_DIR}" "${RESULT_DIR}" "${WORKER_ID}" <<'PY'
import glob
import json
import os
import sys

task_dir, result_dir, worker_id = sys.argv[1:4]
candidates = []

for pattern in ("TASK-*.json", "MTASK-*.json"):
    for path in glob.glob(os.path.join(task_dir, pattern)):
        try:
            task = json.loads(open(path, "r", encoding="utf-8").read())
        except Exception:
            continue

        task_id = task.get("task_id", "")
        if not task_id:
            continue
        if task.get("status") != "approved_to_execute":
            continue

        task_worker = task.get("required_worker_id") or task.get("assigned_to")
        if task_worker != worker_id:
            continue

        if os.path.exists(os.path.join(result_dir, f"{task_id}.result.json")):
            continue

        candidates.append((task_id, path))

candidates.sort(key=lambda x: x[0])
if candidates:
    print(candidates[0][1])
PY
}

force_task_file() {
  [[ -z "${FORCE_TASK_ID}" ]] && return 0

  local task_file="${TASK_DIR}/${FORCE_TASK_ID}.json"
  [[ -f "${task_file}" ]] && echo "${task_file}" || {
    echo "[autopilot] Forced task not found: ${FORCE_TASK_ID}" >&2
    return 1
  }
}

task_field() {
  local task_file="$1"
  local field_name="$2"
  python3 - "${task_file}" "${field_name}" <<'PY'
import json
import sys

task_file, field_name = sys.argv[1:3]
try:
    data = json.loads(open(task_file, "r", encoding="utf-8").read())
except Exception:
    print("")
    raise SystemExit(0)

value = data.get(field_name, "")
print("" if value is None else value)
PY
}

write_result_json() {
  local result_file="$1"
  local task_id="$2"
  local status="$3"
  local summary="$4"
  local stdout_file="$5"
  local stderr_file="$6"

  python3 - "${result_file}" "${task_id}" "${status}" "${summary}" "${stdout_file}" "${stderr_file}" "${WORKER_ID}" <<'PY'
import datetime
import json
import pathlib
import sys

result_file, task_id, status, summary, stdout_file, stderr_file, worker_id = sys.argv[1:8]

def excerpt(path):
    p = pathlib.Path(path)
    if not p.exists():
        return ""
    lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
    if len(lines) > 120:
        lines = lines[-120:]
    return "\n".join(lines)

payload = {
    "task_id": task_id,
    "worker_id": worker_id,
    "execution_status": status,
    "summary": summary,
    "stdout_excerpt": excerpt(stdout_file),
    "stderr_excerpt": excerpt(stderr_file),
    "timestamp_utc": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
}
pathlib.Path(result_file).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

commit_and_push_result() {
  local task_id="$1"
  if ! git_commit_and_push "worker: autopilot result ${task_id}"; then
    echo "[autopilot] Warning: push failed for ${task_id}; result remains local until next successful push." >&2
  fi
}

process_task() {
  local task_file="$1"
  local task_id executor_script assigned_to required_worker_id

  task_id="$(task_field "${task_file}" "task_id")"
  executor_script="$(task_field "${task_file}" "executor_script")"
  assigned_to="$(task_field "${task_file}" "assigned_to")"
  required_worker_id="$(task_field "${task_file}" "required_worker_id")"

  [[ -z "${task_id}" ]] && return 1
  [[ -z "${required_worker_id}" ]] && required_worker_id="${assigned_to}"

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

  write_status "running" "${task_id}" "Task picked up; starting executor ${executor_script}."
  commit_and_push_status_heartbeat || true

  local stdout_tmp stderr_tmp result_file
  stdout_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  result_file="${RESULT_DIR}/${task_id}.result.json"

  if [[ -z "${executor_script}" ]]; then
    write_result_json "${result_file}" "${task_id}" "failed" "Missing required executor_script field in task." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task failed: missing executor_script (${task_id})."
    commit_and_push_result "${task_id}"
    rm -f "${stdout_tmp}" "${stderr_tmp}"
    return 0
  fi

  local script_abs="${REPO_ROOT}/${executor_script}"
  if [[ ! -f "${script_abs}" ]]; then
    echo "Executor script not found: ${executor_script}" > "${stderr_tmp}"
    write_result_json "${result_file}" "${task_id}" "failed" "Executor script not found." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task failed: executor script not found (${task_id})."
    commit_and_push_result "${task_id}"
    rm -f "${stdout_tmp}" "${stderr_tmp}"
    return 0
  fi

  echo "[autopilot] Executing ${executor_script} for ${task_id}"
  if bash "${script_abs}" > "${stdout_tmp}" 2> "${stderr_tmp}"; then
    write_result_json "${result_file}" "${task_id}" "completed" "Executor script completed successfully." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task completed successfully (${task_id})."
  else
    write_result_json "${result_file}" "${task_id}" "failed" "Executor script exited with non-zero status." "${stdout_tmp}" "${stderr_tmp}"
    write_status "running" "${task_id}" "Task failed: executor script non-zero exit (${task_id})."
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
    [[ -z "${task_file}" ]] && break

    process_task "${task_file}"
    processed_any="true"

    [[ "${DRY_RUN}" == "true" ]] && break

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
      commit_and_push_status_heartbeat || true
    fi
  fi

  sleep "${POLL_SECONDS}"
done
