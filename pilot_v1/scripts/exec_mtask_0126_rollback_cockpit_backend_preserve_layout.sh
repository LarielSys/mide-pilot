#!/usr/bin/env bash
set -euo pipefail

TASK_ID="MTASK-0126"
REPO_ROOT="/home/larieladmin/mide-pilot"
TARGET_COMMIT="12e870d8eb033225b278d2b78992dcf06bf4723e"
BACKUP_ROOT="${REPO_ROOT}/pilot_v1/backups"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/cockpit_rollback_${TS}"
COCKPIT_PORT="5555"

hash_file() {
  local p="$1"
  if [[ -f "$p" ]]; then
    sha256sum "$p" | awk '{print $1}'
  else
    echo "missing"
  fi
}

push_retry() {
  local attempt
  for attempt in 1 2 3; do
    if GIT_TERMINAL_PROMPT=0 timeout 60 git -C "${REPO_ROOT}" push origin main; then
      return 0
    fi
    GIT_TERMINAL_PROMPT=0 timeout 60 git -C "${REPO_ROOT}" pull --rebase origin main >/dev/null || true
    sleep $((3 + attempt))
  done
  return 1
}

echo "task=${TASK_ID}"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "target_commit=${TARGET_COMMIT}"

mkdir -p "${BACKUP_DIR}"

# Snapshot current cockpit before rollback.
tar -czf "${BACKUP_DIR}/customide_pre_rollback.tgz" -C "${REPO_ROOT}/pilot_v1" customide
echo "backup_archive=${BACKUP_DIR}/customide_pre_rollback.tgz"

FRONTEND_INDEX="${REPO_ROOT}/pilot_v1/customide/frontend/index.html"
FRONTEND_APPJS="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"
FRONTEND_STYLE="${REPO_ROOT}/pilot_v1/customide/frontend/css/style.css"

IDX_BEFORE="$(hash_file "${FRONTEND_INDEX}")"
APP_BEFORE="$(hash_file "${FRONTEND_APPJS}")"
CSS_BEFORE="$(hash_file "${FRONTEND_STYLE}")"

echo "frontend_index_hash_before=${IDX_BEFORE}"
echo "frontend_appjs_hash_before=${APP_BEFORE}"
echo "frontend_style_hash_before=${CSS_BEFORE}"

GIT_TERMINAL_PROMPT=0 timeout 60 git -C "${REPO_ROOT}" fetch origin main

# Roll back backend only, keep current frontend layout intact.
git -C "${REPO_ROOT}" checkout "${TARGET_COMMIT}" -- pilot_v1/customide/backend

IDX_AFTER="$(hash_file "${FRONTEND_INDEX}")"
APP_AFTER="$(hash_file "${FRONTEND_APPJS}")"
CSS_AFTER="$(hash_file "${FRONTEND_STYLE}")"

echo "frontend_index_hash_after=${IDX_AFTER}"
echo "frontend_appjs_hash_after=${APP_AFTER}"
echo "frontend_style_hash_after=${CSS_AFTER}"

FRONTEND_PRESERVED="yes"
if [[ "${IDX_BEFORE}" != "${IDX_AFTER}" || "${APP_BEFORE}" != "${APP_AFTER}" || "${CSS_BEFORE}" != "${CSS_AFTER}" ]]; then
  FRONTEND_PRESERVED="no"
fi
echo "frontend_layout_preserved=${FRONTEND_PRESERVED}"

# Persist rollback to git if there are backend changes.
git -C "${REPO_ROOT}" add pilot_v1/customide/backend
if ! git -C "${REPO_ROOT}" diff --cached --quiet; then
  git -C "${REPO_ROOT}" commit -m "rollback: cockpit backend to MTASK-0103 known-good (preserve frontend layout)"
  if push_retry; then
    echo "rollback_commit_pushed=yes"
  else
    echo "rollback_commit_pushed=no"
  fi
else
  echo "rollback_commit_pushed=not_needed"
fi

# Restart cockpit backend.
pkill -f "uvicorn.*app.main:app" 2>/dev/null || true
sleep 2
cd "${REPO_ROOT}/pilot_v1/customide/backend"
nohup "${REPO_ROOT}/pilot_v1/customide/backend/.venv/bin/uvicorn" app.main:app --host 0.0.0.0 --port ${COCKPIT_PORT} \
  > "${REPO_ROOT}/pilot_v1/state/cockpit_backend.log" 2>&1 &
echo "backend_pid=$!"
sleep 4

RUNTIME_CODE="$(curl -s -o /tmp/mtask_0126_runtime.json -w "%{http_code}" "http://127.0.0.1:${COCKPIT_PORT}/api/status/runtime" || true)"
echo "runtime_http=${RUNTIME_CODE}"

if [[ "${RUNTIME_CODE}" == "200" && "${FRONTEND_PRESERVED}" == "yes" ]]; then
  echo "final_status=ALL_CHECKS_PASSED"
else
  echo "final_status=ROLLBACK_PARTIAL_runtime=${RUNTIME_CODE}_frontend_preserved=${FRONTEND_PRESERVED}"
fi
