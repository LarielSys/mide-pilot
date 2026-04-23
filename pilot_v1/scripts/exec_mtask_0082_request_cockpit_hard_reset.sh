#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_FILE="${REPO_ROOT}/pilot_v1/state/cockpit_hard_reset_request.json"

cd "${REPO_ROOT}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

ts_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
nonce="$(date -u +"%Y%m%dT%H%M%SZ")-${RANDOM}"
reason="${HARD_RESET_REASON:-manual_or_recovery_request}"
scope="${HARD_RESET_SCOPE:-customide_frontend}"
requested_by="${REQUESTED_BY:-ubuntu-worker-01}"

cat > "${STATE_FILE}" <<JSON
{
  "nonce": "${nonce}",
  "requested_at_utc": "${ts_utc}",
  "reason": "${reason}",
  "scope": "${scope}",
  "requested_by": "${requested_by}"
}
JSON

git add "pilot_v1/state/cockpit_hard_reset_request.json"

echo "hard_reset_requested=true"
echo "hard_reset_nonce=${nonce}"
echo "hard_reset_scope=${scope}"
echo "hard_reset_state_file=pilot_v1/state/cockpit_hard_reset_request.json"
echo "timestamp_utc=${ts_utc}"
