#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

B64_PATH='pilot_v1/deliverables/screenshot1.png.b64'
META_PATH='pilot_v1/deliverables/screenshot1.metadata.json'

log(){ echo "[MTASK-2037] $*"; }
err(){ echo "[MTASK-2037 ERROR] $*" >&2; }

[[ -f "$B64_PATH" ]] || { err "Missing artifact: $B64_PATH"; exit 1; }
[[ -f "$META_PATH" ]] || { err "Missing metadata: $META_PATH"; exit 1; }

log "Artifacts found locally"
log "artifact_bytes=$(wc -c < "$B64_PATH")"
log "metadata_bytes=$(wc -c < "$META_PATH")"

# Strict completion: artifact must reach origin/main, not just exist locally.
# This task intentionally performs its own git publish because the autopilot
# result commit path stages only result/state files.

git add -- "$B64_PATH" "$META_PATH"
if git diff --cached --quiet; then
  log "Artifacts already staged in current tree or unchanged"
else
  git commit -m "deliverable(MTASK-2037): upload screenshot1 artifacts"
fi

git push origin main

git fetch origin main
if ! git ls-tree -r --name-only origin/main -- "$B64_PATH" | grep -qx "$B64_PATH"; then
  err "Artifact file not present in origin/main after push"
  exit 1
fi
if ! git ls-tree -r --name-only origin/main -- "$META_PATH" | grep -qx "$META_PATH"; then
  err "Metadata file not present in origin/main after push"
  exit 1
fi

log "Artifacts confirmed in origin/main"
log "artifact=$B64_PATH"
log "metadata=$META_PATH"
