#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

B64_PATH='pilot_v1/deliverables/screenshot1.png.b64'
META_PATH='pilot_v1/deliverables/screenshot1.metadata.json'

log(){ echo "[MTASK-2036] $*"; }
err(){ echo "[MTASK-2036 ERROR] $*" >&2; }

if [[ ! -f "$B64_PATH" ]]; then
  err "Missing artifact: $B64_PATH"
  exit 1
fi

if [[ ! -f "$META_PATH" ]]; then
  err "Missing metadata: $META_PATH"
  exit 1
fi

log "Artifacts present"
log "artifact=$B64_PATH"
log "metadata=$META_PATH"
log "artifact_bytes=$(wc -c < "$B64_PATH")"
log "metadata_bytes=$(wc -c < "$META_PATH")"
log "ready_for_autopilot_commit=true"
