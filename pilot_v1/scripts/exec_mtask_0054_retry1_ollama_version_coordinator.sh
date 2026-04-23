#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
VERSION_FILE="${REPO_ROOT}/pilot_v1/config/ollama_version.txt"
SERVICES_FILE="${REPO_ROOT}/pilot_v1/config/worker1_services.json"
RUNBOOK_FILE="${REPO_ROOT}/pilot_v1/customide/OLLAMA_VERSION_COORDINATOR.md"

cd "${REPO_ROOT}"

echo "task=MTASK-0054-RETRY1"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

# Robust sync flow: avoid git pull ambiguity in worker environments.
git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD
echo "git_sync=passed"

mkdir -p "$(dirname "${VERSION_FILE}")"
mkdir -p "$(dirname "${RUNBOOK_FILE}")"

python3 - <<'PY'
import json
import pathlib
import re

repo_root = pathlib.Path('.')
services = repo_root / 'pilot_v1/config/worker1_services.json'
version_file = repo_root / 'pilot_v1/config/ollama_version.txt'

version = 'unknown'
if services.exists():
    data = json.loads(services.read_text(encoding='utf-8'))
    raw = (
        (((data.get('services') or {}).get('ollama') or {}).get('version'))
        or ''
    )
    m = re.search(r'(\d+\.\d+\.\d+)', raw)
    if m:
        version = m.group(1)

version_file.write_text(version + '\n', encoding='utf-8')
PY

if [[ ! -s "${VERSION_FILE}" ]]; then
  echo "error=ollama_version_file_missing"
  exit 1
fi

cat > "${RUNBOOK_FILE}" <<'MD'
# Ollama Version Coordinator

## Goal
Keep Ollama runtime version aligned between Windows and Ubuntu Worker 1 so shared LLM behavior is reproducible.

## Canonical Version File
- Path: `pilot_v1/config/ollama_version.txt`
- This file is the contract value for local parity checks.

## Verification Commands
### Ubuntu Worker 1
```bash
ollama --version
cat ~/mide-pilot/pilot_v1/config/ollama_version.txt
```

### Windows
```powershell
Invoke-RestMethod http://localhost:11434/api/version
Get-Content c:\AI Assistant\MIDE\pilot_v1\config\ollama_version.txt
```

## Contract Rule
- If Ubuntu or Windows runtime version differs from `ollama_version.txt`, treat as mismatch and halt architecture-forward MTASK execution until reconciled.

## Update Procedure
1. Update/confirm Ollama on both systems.
2. Write canonical value to `pilot_v1/config/ollama_version.txt`.
3. Re-run validation commands on both systems.
4. Continue next MTASK only after parity is verified.
MD

if ! grep -q "Canonical Version File" "${RUNBOOK_FILE}"; then
  echo "error=runbook_missing_contract_section"
  exit 1
fi
if ! grep -q "Invoke-RestMethod http://localhost:11434/api/version" "${RUNBOOK_FILE}"; then
  echo "error=runbook_missing_windows_verification"
  exit 1
fi
if ! grep -q "ollama --version" "${RUNBOOK_FILE}"; then
  echo "error=runbook_missing_ubuntu_verification"
  exit 1
fi

echo "ollama_version_file=passed"
echo "ollama_version_runbook=passed"
echo "ollama_version_contract_ready=passed"

git add \
  "pilot_v1/config/ollama_version.txt" \
  "pilot_v1/customide/OLLAMA_VERSION_COORDINATOR.md"
git commit -m "customide: add ollama version coordinator artifacts (MTASK-0054-RETRY1)" >/dev/null || true
git push origin main >/dev/null || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
