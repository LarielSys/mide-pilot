#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

DELIVERY_DIR='pilot_v1/deliverables'
mkdir -p "$DELIVERY_DIR"

log(){ echo "[MTASK-2035] $*"; }
err(){ echo "[MTASK-2035 ERROR] $*" >&2; }

log "Searching for screenshot1 by basename"
IMAGE_PATH="$(find / \( -iname 'screenshot1' -o -iname 'screenshot1.png' -o -iname 'screenshot1.jpg' -o -iname 'screenshot1.jpeg' -o -iname 'screenshot1.webp' \) -type f 2>/dev/null | head -1 || true)"

if [[ -z "$IMAGE_PATH" ]]; then
  err "screenshot1 not found"
  exit 1
fi

if [[ ! -r "$IMAGE_PATH" ]]; then
  err "found screenshot1 but file is not readable: $IMAGE_PATH"
  exit 1
fi

EXT="${IMAGE_PATH##*.}"
if [[ "$EXT" == "$IMAGE_PATH" ]]; then
  EXT="bin"
fi
B64_OUT="$DELIVERY_DIR/screenshot1.${EXT}.b64"
META_OUT="$DELIVERY_DIR/screenshot1.metadata.json"

base64 < "$IMAGE_PATH" > "$B64_OUT"

FILE_SIZE="$(stat -c%s "$IMAGE_PATH" 2>/dev/null || stat -f%z "$IMAGE_PATH" 2>/dev/null || echo null)"
FILE_TYPE="$(file -b "$IMAGE_PATH")"

cat > "$META_OUT" <<EOF
{
  "filename": "$(basename "$IMAGE_PATH")",
  "original_path": "$IMAGE_PATH",
  "discovered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "file_size_bytes": $FILE_SIZE,
  "file_type": "${FILE_TYPE//"/\\\"}",
  "base64_file": "$(basename "$B64_OUT")",
  "delivery_method": "git_base64_encoded"
}
EOF

log "Found image: $IMAGE_PATH"
log "Encoded artifact: $B64_OUT"
log "Metadata: $META_OUT"
log "Image type: $FILE_TYPE"
log "Image bytes: $FILE_SIZE"
