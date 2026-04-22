#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"

cd "${REPO_ROOT}"

echo "task=MTASK-0036"
echo "worker_id=${WORKER_ID}"
echo "policy=mtask_universal_protocol"

git fetch origin
git pull --ff-only origin main

python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import json
import re
import sys

repo_root = Path(sys.argv[1])
tasks_dir = repo_root / "pilot_v1" / "tasks"
results_dir = repo_root / "pilot_v1" / "results"

changed = []
remaining_task_approved = []

for p in sorted(tasks_dir.glob("TASK-*.json")):
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        continue

    task_id = data.get("task_id", "")
    status = data.get("status", "")
    result_file = results_dir / f"{task_id}.result.json"

    if status == "approved_to_execute" and not result_file.exists():
        data["status"] = "deprecated_do_not_execute"
        objective = data.get("objective", "")
        if not objective.startswith("DEPRECATED:"):
            data["objective"] = "DEPRECATED: replaced by MTASK protocol. Do not execute."
        p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        changed.append(task_id)

for p in sorted(tasks_dir.glob("TASK-*.json")):
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        continue
    task_id = data.get("task_id", "")
    if data.get("status") == "approved_to_execute" and not (results_dir / f"{task_id}.result.json").exists():
        remaining_task_approved.append(task_id)

print("task_protocol_patched=" + (",".join(changed) if changed else "none"))
print("task_protocol_remaining_approved=" + (",".join(remaining_task_approved) if remaining_task_approved else "none"))
PY

git add pilot_v1/tasks/*.json
if ! git diff --cached --quiet; then
  git commit -m "mtask policy: deprecate pending TASK queue items" || true
  git push origin main || true
  echo "task_policy_commit=pushed"
else
  echo "task_policy_commit=no_changes"
fi

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
