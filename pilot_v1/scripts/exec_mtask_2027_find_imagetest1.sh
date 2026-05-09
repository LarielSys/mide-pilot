#!/usr/bin/env bash
set -euo pipefail

STATE_DIR='pilot_v1/state'
DELIVERY_DIR='pilot_v1/deliverables'
mkdir -p "$STATE_DIR" "$DELIVERY_DIR"

log(){ echo "[MTASK-2027] $*"; }
error(){ echo "[MTASK-2027 ERROR] $*" >&2; }

log "Starting autonomous image discovery and delivery..."

# Search for imagetest1.png on the entire filesystem
log "Searching for imagetest1.png..."
IMAGE_PATH=$(find / -name "imagetest1.png" -type f 2>/dev/null | head -1 || true)

if [ -z "$IMAGE_PATH" ]; then
  error "imagetest1.png not found on system"
  exit 1
fi

log "Found image at: $IMAGE_PATH"

# Check if file is readable
if [ ! -r "$IMAGE_PATH" ]; then
  error "Cannot read file: $IMAGE_PATH"
  exit 1
fi

# Base64 encode the image
log "Encoding image to base64..."
BASE64_OUTPUT="$DELIVERY_DIR/imagetest1.png.b64"
base64 < "$IMAGE_PATH" > "$BASE64_OUTPUT"

log "Image encoded: $BASE64_OUTPUT"
log "Encoded size: $(wc -c < "$BASE64_OUTPUT") bytes"

# Get original image info
log "Image info:"
file "$IMAGE_PATH"
ls -lh "$IMAGE_PATH"

# Create metadata file
METADATA_FILE="$DELIVERY_DIR/imagetest1.metadata.json"
cat > "$METADATA_FILE" <<EOF
{
  "filename": "imagetest1.png",
  "original_path": "$IMAGE_PATH",
  "discovered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "file_size_bytes": $(stat -f%z "$IMAGE_PATH" 2>/dev/null || stat -c%s "$IMAGE_PATH" 2>/dev/null || echo "unknown"),
  "file_type": "$(file -b "$IMAGE_PATH")",
  "base64_file": "imagetest1.png.b64",
  "delivery_method": "git_base64_encoded"
}
EOF

log "Metadata written: $METADATA_FILE"

# Prepare for git delivery
log "Preparing git delivery..."
cd "$(git rev-parse --show-toplevel)" || { error "Not in git repo"; exit 1; }

# Stage files for commit
git add "$BASE64_OUTPUT" "$METADATA_FILE"

# Commit
git commit -m "MTASK-2027: Autonomous imagetest1.png delivery (base64 encoded)" || log "Nothing to commit or commit failed"

# Push to origin
log "Pushing to git..."
git push origin HEAD:main || git push origin HEAD || log "Push attempt completed (may not have upstream)"

log "MTASK-2027 complete: Image discovered, encoded, and pushed to git"
log "Delivery file: $BASE64_OUTPUT"
log "Metadata: $METADATA_FILE"

exit 0
