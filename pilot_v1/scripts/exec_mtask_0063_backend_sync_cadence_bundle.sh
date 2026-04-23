#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
RUNTIME_FILE="${REPO_ROOT}/pilot_v1/customide/backend/app/routes/runtime.py"

cd "${REPO_ROOT}"

echo "task=MTASK-0063"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

path = Path('pilot_v1/customide/backend/app/routes/runtime.py')
text = path.read_text(encoding='utf-8')

if 'def get_sync_cadence() -> dict:' not in text:
    insert_after = 'def get_sync_health() -> dict:\n'
    block = '''

def get_sync_cadence() -> dict:
    from datetime import datetime

    repo_root = Path(__file__).resolve().parents[3]
    event_file = repo_root / "pilot_v1/state/worker_autopilot_events.log"

    if not event_file.exists():
        return {
            "samples": 0,
            "deltas_seconds": [],
            "gate_3x60_pass": False,
            "status": "missing",
            "source_file": str(event_file),
        }

    lines = event_file.read_text(encoding="utf-8", errors="replace").splitlines()
    stamps = []
    for line in lines:
        if len(line) >= 20 and line[19] == "Z":
            head = line[:20]
            try:
                stamps.append(datetime.strptime(head, "%Y-%m-%dT%H:%M:%SZ"))
            except ValueError:
                continue
        if len(stamps) >= 4:
            break

    deltas = []
    for i in range(len(stamps) - 1):
        deltas.append(int((stamps[i] - stamps[i + 1]).total_seconds()))

    gate = len(deltas) >= 3 and all(55 <= d <= 65 for d in deltas[:3])
    status = "pass" if gate else ("insufficient" if len(deltas) < 3 else "drift")

    return {
        "samples": len(stamps),
        "deltas_seconds": deltas,
        "gate_3x60_pass": gate,
        "status": status,
        "source_file": str(event_file),
    }
'''
    text = text.replace(insert_after, insert_after + block)

if '"sync_cadence": get_sync_cadence()' not in text:
    text = text.replace(
        '    return {\n        "runtime": get_runtime_status(),\n        "sync_health": get_sync_health(),\n    }\n',
        '    return {\n        "runtime": get_runtime_status(),\n        "sync_health": get_sync_health(),\n        "sync_cadence": get_sync_cadence(),\n    }\n'
    )

path.write_text(text, encoding='utf-8')
PY

if ! grep -q 'def get_sync_cadence() -> dict:' "${RUNTIME_FILE}"; then
  echo "error=sync_cadence_function_missing"
  exit 1
fi
if ! grep -q '"sync_cadence": get_sync_cadence()' "${RUNTIME_FILE}"; then
  echo "error=bundle_sync_cadence_missing"
  exit 1
fi
if ! grep -q '"gate_3x60_pass"' "${RUNTIME_FILE}"; then
  echo "error=gate_3x60_flag_missing"
  exit 1
fi

echo "backend_sync_cadence_bundle=passed"
echo "phase25_sync_cadence_bundle=passed"

git add "pilot_v1/customide/backend/app/routes/runtime.py"
git commit -m "customide-backend: add sync cadence bundle payload (MTASK-0063)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
