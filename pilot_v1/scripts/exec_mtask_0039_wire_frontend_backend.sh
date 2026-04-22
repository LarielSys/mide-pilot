#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

FRONTEND_ROOT="${REPO_ROOT}/pilot_v1/customide/frontend"
BACKEND_ROOT="${REPO_ROOT}/pilot_v1/customide/backend"
CONFIG_PATH="${REPO_ROOT}/pilot_v1/config/worker1_services.json"

cd "${REPO_ROOT}"

echo "task=MTASK-0039"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${FRONTEND_ROOT}/index.html" ]]; then
  echo "error=frontend_shell_missing"
  echo "expected=${FRONTEND_ROOT}/index.html"
  exit 1
fi

if [[ ! -f "${BACKEND_ROOT}/app/main.py" ]]; then
  echo "error=backend_scaffold_missing"
  echo "expected=${BACKEND_ROOT}/app/main.py"
  exit 1
fi

cat > "${FRONTEND_ROOT}/js/config.js" <<'JS'
window.CUSTOMIDE_CONFIG = {
  backendBaseUrl: "http://127.0.0.1:5555",
  workerServicesPath: "../../config/worker1_services.json"
};
JS

cat > "${FRONTEND_ROOT}/js/app.js" <<'JS'
(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");

  const cfg = window.CUSTOMIDE_CONFIG || {
    backendBaseUrl: "http://127.0.0.1:5555",
    workerServicesPath: "../../config/worker1_services.json"
  };

  async function checkBackend() {
    try {
      const res = await fetch(cfg.backendBaseUrl + "/health");
      if (!res.ok) throw new Error("health failed");
      const data = await res.json();
      statusEl.textContent = "Backend: " + (data.status || "ok");
    } catch (_err) {
      statusEl.textContent = "Backend: offline (start uvicorn on :5555)";
    }
  }

  async function resolveRemoteUrl() {
    try {
      const res = await fetch(cfg.workerServicesPath);
      if (!res.ok) throw new Error("services json fetch failed");
      const data = await res.json();

      const candidates = [
        data.code_server_url,
        data.codeserver_url,
        data.code_server,
        data.services && data.services.code_server_url,
        data.services && data.services.codeserver_url
      ];

      const url = candidates.find((v) => typeof v === "string" && v.trim().length > 0);
      if (url) {
        remoteFrame.src = url;
        return true;
      }
    } catch (_err) {
      // keep fallback below
    }

    remoteFrame.src = "about:blank";
    return false;
  }

  await checkBackend();
  const remoteOk = await resolveRemoteUrl();
  if (!remoteOk) {
    statusEl.textContent += " | Remote: waiting for code-server URL";
  }
})();
JS

python3 - "$CONFIG_PATH" <<'PY'
import json
import pathlib
import sys

cfg = pathlib.Path(sys.argv[1])
if cfg.exists():
    with cfg.open("r", encoding="utf-8") as f:
        _ = json.load(f)
    print("services_config=json_valid")
else:
    print("services_config=missing")
PY

echo "frontend_backend_wire=completed"

git add \
  "pilot_v1/customide/frontend/js/config.js" \
  "pilot_v1/customide/frontend/js/app.js"

git commit -m "customide: wire frontend shell to backend/services (MTASK-0039)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
