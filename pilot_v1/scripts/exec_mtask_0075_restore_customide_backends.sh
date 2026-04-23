#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "task=MTASK-0075"
echo "objective=restore customide backends and verify health endpoints"

cd "${REPO_ROOT}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

chmod +x "pilot_v1/customide/scripts/start_local_stack.sh"

if bash "pilot_v1/customide/scripts/start_local_stack.sh"; then
  echo "backend_stack_start=passed"
else
  echo "backend_stack_start=failed"
  exit 1
fi

health_json="$(curl -fsS http://127.0.0.1:5555/health || true)"
bundle_json="$(curl -fsS http://127.0.0.1:5555/api/status/bundle || true)"
llm_json="$(curl -fsS http://127.0.0.1:5555/api/llm/health || true)"

if [[ -n "${health_json}" ]]; then
  echo "backend_health=passed"
else
  echo "backend_health=failed"
  exit 1
fi

if [[ -n "${bundle_json}" ]]; then
  echo "status_bundle=passed"
else
  echo "status_bundle=failed"
  exit 1
fi

if [[ -n "${llm_json}" ]]; then
  echo "llm_health=passed"
else
  echo "llm_health=failed"
  exit 1
fi

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"