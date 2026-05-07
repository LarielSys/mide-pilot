#!/usr/bin/env bash
# MTASK-0112 — Implement push_with_retry() in worker_mtask_autopilot.sh
# Decision: MTASK-0111 option C — retry with rebase + random backoff
set -uo pipefail

TASK_ID="MTASK-0112"
REPO_ROOT="/home/larieladmin/Documents/itheia-llm/MIDE"
AUTOPILOT="$REPO_ROOT/pilot_v1/scripts/worker_mtask_autopilot.sh"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0112.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

cd "$REPO_ROOT"
git pull --rebase origin main 2>&1 | tee -a "$LOG"

# --- Check if push_with_retry already exists ---
if grep -q "push_with_retry" "$AUTOPILOT"; then
  echo "push_with_retry=already_exists" | tee -a "$LOG"
  echo "final_status=ALREADY_PATCHED" | tee -a "$LOG"
  exit 0
fi

echo "patching=$AUTOPILOT" | tee -a "$LOG"

# --- Insert push_with_retry function after the existing helper functions ---
# Find the line number of the first non-comment non-blank function def to insert before it
# We insert after the 'set -euo pipefail' line (or similar setup block)

# Create the patch content
PATCH_FUNC='
# ── push_with_retry: rebase-pull then retry up to 3 times with random backoff ─
push_with_retry() {
  local attempt=1
  local max_attempts=3
  while [ $attempt -le $max_attempts ]; do
    if git -C "'"$REPO_ROOT"'" push origin main 2>&1; then
      return 0
    fi
    echo "[push_with_retry] attempt=$attempt failed, pulling and retrying..."
    git -C "'"$REPO_ROOT"'" pull --rebase origin main 2>&1 || true
    local delay=$(( RANDOM % 11 + 5 ))  # 5-15 seconds
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
  echo "[push_with_retry] PUSH_FAILED_MAX_RETRIES after $max_attempts attempts — continuing loop"
  return 0  # Non-fatal: loop must continue
}
'

# Write to a temp patch file
PATCH_FILE=$(mktemp /tmp/mtask0112_patch.XXXXXX)
echo "$PATCH_FUNC" > "$PATCH_FILE"

# Find insertion point: after the last 'set -' line or after shebang block
# Use awk to insert after the first blank line following a 'set -' line
BACKUP="$AUTOPILOT.bak_mtask0112"
cp "$AUTOPILOT" "$BACKUP"
echo "backup=$BACKUP" | tee -a "$LOG"

# Insert the function after the set -euo pipefail line
awk '
  /^set -/ { print; inserted=1; next }
  inserted && /^$/ && !done { print ""; while ((getline line < patch) > 0) print line; done=1; inserted=0 }
  { print }
' patch="$PATCH_FILE" "$BACKUP" > "$AUTOPILOT"

# --- Replace direct `git push origin main` calls with push_with_retry ---
# Preserve lines that are part of push_with_retry itself
# Use sed to replace standalone push calls outside the function
sed -i '/push_with_retry/! s/git -C.*push origin main/push_with_retry/g' "$AUTOPILOT"
sed -i '/push_with_retry/! s/git push origin main/push_with_retry/g' "$AUTOPILOT"

echo "patch_applied=yes" | tee -a "$LOG"

# --- Verify the function exists ---
if grep -q "push_with_retry()" "$AUTOPILOT"; then
  echo "function_verified=yes" | tee -a "$LOG"
else
  echo "function_verified=FAILED — restoring backup" | tee -a "$LOG"
  cp "$BACKUP" "$AUTOPILOT"
  echo "final_status=PATCH_FAILED_RESTORED" | tee -a "$LOG"
  exit 1
fi

# --- Show diff ---
echo "--- diff ---" | tee -a "$LOG"
diff "$BACKUP" "$AUTOPILOT" | head -60 | tee -a "$LOG"

# --- Commit and push the patched script ---
git add "$AUTOPILOT"
git commit -m "worker: add push_with_retry() to autopilot — MTASK-0112 git sync fix"
push_with_retry

echo "--- verify ---" | tee -a "$LOG"
grep -n "push_with_retry" "$AUTOPILOT" | head -10 | tee -a "$LOG"

rm -f "$PATCH_FILE"
echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
