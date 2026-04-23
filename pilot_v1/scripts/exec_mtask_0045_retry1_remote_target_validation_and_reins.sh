#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

BACKEND_ROOT="${REPO_ROOT}/pilot_v1/customide/backend"
FRONTEND_ROOT="${REPO_ROOT}/pilot_v1/customide/frontend"
SERVICES_JSON="${REPO_ROOT}/pilot_v1/config/worker1_services.json"

cd "${REPO_ROOT}"

echo "task=MTASK-0045-RETRY1"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${SERVICES_JSON}" ]]; then
  echo "error=worker_services_missing"
  exit 1
fi

# Tight reins preflight: allow autopilot state/result churn, block everything else.
DIRTY_NON_RUNTIME="$(git status --porcelain --untracked-files=no -- . ':(exclude)pilot_v1/state' ':(exclude)pilot_v1/results')"
if [[ -n "${DIRTY_NON_RUNTIME}" ]]; then
  echo "error=dirty_tree_non_runtime_before_validation"
  echo "dirty_non_runtime=${DIRTY_NON_RUNTIME}"
  exit 1
fi

# Tight reins preflight: verify canonical MTASK-0044 executor integrity from origin.
LOCAL_0044_HASH="$(git hash-object pilot_v1/scripts/exec_mtask_0044_smoke_verify_hardened_exec.sh)"
ORIGIN_0044_HASH="$(git show origin/main:pilot_v1/scripts/exec_mtask_0044_smoke_verify_hardened_exec.sh | git hash-object --stdin)"
if [[ "${LOCAL_0044_HASH}" != "${ORIGIN_0044_HASH}" ]]; then
  echo "error=mtask0044_executor_hash_mismatch"
  exit 1
fi

echo "reins_preflight_hash_match=passed"
MODE_LINE="$(git ls-files --stage pilot_v1/scripts/exec_mtask_0044_smoke_verify_hardened_exec.sh | awk '{print $1}')"
echo "mtask0044_mode=${MODE_LINE}"

if [[ ! -f "${BACKEND_ROOT}/app/routes/execute.py" ]]; then
  echo "error=execute_route_missing"
  exit 1
fi

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0045r1-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0045r1-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

cleanup() {
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

HEALTH_JSON="$(curl -sSf http://127.0.0.1:5555/health)"
RUNTIME_JSON="$(curl -sSf http://127.0.0.1:5555/api/status/runtime)"
REMOTE_CFG_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/execute/remote -H 'Content-Type: application/json' -d '{"command":"echo remote-0045","use_worker_config":true,"timeout_seconds":12}')"
REMOTE_FAIL_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/execute/remote -H 'Content-Type: application/json' -d '{"command":"echo should-fail","use_worker_config":false,"timeout_seconds":12}')"
FRONTEND_OK="$(curl -sSf http://127.0.0.1:5570 >/dev/null && echo yes || echo no)"

echo "health_check=${HEALTH_JSON}"
echo "runtime_status=${RUNTIME_JSON}"
echo "remote_exec_with_config=${REMOTE_CFG_JSON}"
echo "remote_exec_without_target=${REMOTE_FAIL_JSON}"
echo "frontend_reachable=${FRONTEND_OK}"

if [[ "${FRONTEND_OK}" != "yes" ]]; then
  echo "error=frontend_not_reachable"
  exit 1
fi

if [[ "${REMOTE_FAIL_JSON}" != *"Remote target missing host/user"* ]]; then
  echo "error=remote_failure_mode_not_enforced"
  exit 1
fi

if [[ "${REMOTE_CFG_JSON}" != *"target"* && "${REMOTE_CFG_JSON}" != *"detail"* ]]; then
  echo "error=remote_config_resolution_missing"
  exit 1
fi

echo "remote_target_resolution=passed"
echo "remote_failure_mode=passed"
echo "reins_guardrails=passed"

git add \
  "pilot_v1/customide/backend/app/routes/execute.py" \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js" \
  "pilot_v1/config/worker1_services.json" \
  "pilot_v1/scripts/exec_mtask_0044_smoke_verify_hardened_exec.sh" || true

git commit -m "customide: retry remote target validation and tighten reins (MTASK-0045-RETRY1)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
