#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
REPO_ROOT="${HOME}/mide-pilot"
SPEC_DIR="${REPO_ROOT}/pilot_v1/specs/weather_live_compare"
MOSS_FILE="${SPEC_DIR}/weather_live_architecture.moss"
API_FILE="${SPEC_DIR}/weather_compare_api_contract.json"
NOTES_FILE="${SPEC_DIR}/integration_notes.txt"

cd "${REPO_ROOT}"

echo "task=MTASK-0027"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "spec_dir=${SPEC_DIR}"

missing=0
for f in "${MOSS_FILE}" "${API_FILE}" "${NOTES_FILE}"; do
  if [[ ! -f "${f}" ]]; then
    echo "missing_file=${f}"
    missing=1
  fi
done

if [[ "${missing}" -ne 0 ]]; then
  echo "error=required_spec_files_missing"
  exit 1
fi

echo "verified_file=${MOSS_FILE}"
echo "verified_file=${API_FILE}"
echo "verified_file=${NOTES_FILE}"

git add \
  pilot_v1/specs/weather_live_compare/weather_live_architecture.moss \
  pilot_v1/specs/weather_live_compare/weather_compare_api_contract.json \
  pilot_v1/specs/weather_live_compare/integration_notes.txt

if git diff --cached --quiet; then
  echo "sync_commit=not_needed_no_changes"
else
  git commit -m "worker: sync MTASK-0026 weather architecture specs"
  git push origin main
  echo "sync_commit=created"
fi

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
