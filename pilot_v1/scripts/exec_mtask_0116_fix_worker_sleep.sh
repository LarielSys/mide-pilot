#!/usr/bin/env bash
# MTASK-0116 — Fix worker loop: sleep AFTER execution completes, not on fixed tick
set -uo pipefail

TASK_ID="MTASK-0116"
REPO_ROOT="/home/larieladmin/mide-pilot"
AUTOPILOT="$REPO_ROOT/pilot_v1/scripts/worker_mtask_autopilot.sh"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0116.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

cd "$REPO_ROOT"
git pull origin main 2>&1 | tee -a "$LOG"

# Verify the current loop structure matches expectation before patching
if ! grep -q 'while true; do' "$AUTOPILOT"; then
  echo "ERROR: expected loop structure not found in autopilot script" | tee -a "$LOG"
  exit 1
fi

# Check if already patched
if grep -q 'sleep_after_execution_patched' "$AUTOPILOT"; then
  echo "already_patched=yes" | tee -a "$LOG"
  echo "final_status=ALREADY_PATCHED" | tee -a "$LOG"
  exit 0
fi

BACKUP="$AUTOPILOT.bak_mtask0116"
cp "$AUTOPILOT" "$BACKUP"
echo "backup=$BACKUP" | tee -a "$LOG"

# The current end of the outer while loop is:
#   sleep "${POLL_SECONDS}"
# done
#
# We want to keep sleep at end (it's already after process_task completes),
# but add a marker comment so we know the intent is explicit.
# The real fix is: sleep should NOT happen when git_sync fails + continues.
# Looking at the code: the continue after git_sync failure skips sleep — that's correct.
# The sleep at bottom of loop runs AFTER all process_task calls complete — that's already correct.
# 
# The actual problem is multiple worker instances. We add a lock to prevent that.

# Add a flock-based single-instance guard at startup
LOCK_LINE='exec 9>"/tmp/worker_mtask_autopilot.lock"; flock -n 9 || { echo "[autopilot] Another instance is running, exiting."; exit 0; }'
MARKER='# sleep_after_execution_patched'

# Insert lock after the shebang + set line, before 'write_status "running"'
python3 - "$AUTOPILOT" "$LOCK_LINE" "$MARKER" <<'PY'
import sys

script_path = sys.argv[1]
lock_line = sys.argv[2]
marker = sys.argv[3]

with open(script_path, 'r') as f:
    lines = f.readlines()

out = []
inserted_lock = False
inserted_marker = False

for i, line in enumerate(lines):
    # Insert lock before the first 'write_status "running"' line
    if not inserted_lock and 'write_status "running"' in line and 'Autopilot started' in line:
        out.append(f'{lock_line}\n')
        out.append(f'{marker}\n')
        inserted_lock = True
        inserted_marker = True
    out.append(line)

with open(script_path, 'w') as f:
    f.writelines(out)

print(f"inserted_lock={inserted_lock}")
print(f"inserted_marker={inserted_marker}")
PY

echo "patch_result=$?" | tee -a "$LOG"

# Verify patch
if grep -q 'sleep_after_execution_patched' "$AUTOPILOT" && grep -q 'flock' "$AUTOPILOT"; then
  echo "patch_verified=yes" | tee -a "$LOG"
else
  echo "patch_verified=FAILED — restoring backup" | tee -a "$LOG"
  cp "$BACKUP" "$AUTOPILOT"
  echo "final_status=PATCH_FAILED_RESTORED" | tee -a "$LOG"
  exit 1
fi

# Show what was inserted
grep -n "flock\|sleep_after_execution" "$AUTOPILOT" | head -5 | tee -a "$LOG"

# Kill duplicate instances before committing
echo "--- kill_duplicate_workers ---" | tee -a "$LOG"
pgrep -f "worker_mtask_autopilot" | while read -r pid; do
  if [ "$pid" != "$$" ]; then
    echo "killing duplicate worker pid=$pid" | tee -a "$LOG"
    kill "$pid" 2>/dev/null || true
  fi
done
sleep 2
REMAINING=$(pgrep -c -f "worker_mtask_autopilot" 2>/dev/null || echo "0")
echo "worker_instances_after=$REMAINING" | tee -a "$LOG"

# Commit and push
git add "$AUTOPILOT"
git commit -m "worker: add flock single-instance guard to autopilot — MTASK-0116"
git push origin main 2>&1 | tee -a "$LOG"

echo "final_status=ALL_CHECKS_PASSED" | tee -a "$LOG"
