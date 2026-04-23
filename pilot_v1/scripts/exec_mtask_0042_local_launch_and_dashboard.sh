#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

BACKEND_ROOT="${REPO_ROOT}/pilot_v1/customide/backend"
APP_ROOT="${BACKEND_ROOT}/app"
ROUTES_ROOT="${APP_ROOT}/routes"
FRONTEND_ROOT="${REPO_ROOT}/pilot_v1/customide/frontend"
CUSTOMIDE_ROOT="${REPO_ROOT}/pilot_v1/customide"
TOOLS_ROOT="${CUSTOMIDE_ROOT}/scripts"

cd "${REPO_ROOT}"

echo "task=MTASK-0042"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${APP_ROOT}/main.py" ]]; then
  echo "error=backend_missing"
  exit 1
fi
if [[ ! -f "${FRONTEND_ROOT}/index.html" ]]; then
  echo "error=frontend_missing"
  exit 1
fi

mkdir -p "${TOOLS_ROOT}"

cat > "${ROUTES_ROOT}/runtime.py" <<'PY'
from pathlib import Path

from fastapi import APIRouter

from ..services import load_worker_services

router = APIRouter(prefix="/api/status", tags=["status"])


@router.get("/runtime")
def get_runtime_status() -> dict:
    repo_root = Path(__file__).resolve().parents[3]
    services = load_worker_services(repo_root)

    code_server_url = (
        services.get("code_server_url")
        or services.get("codeserver_url")
        or services.get("code_server")
        or (services.get("services") or {}).get("code_server_url")
        or (services.get("services") or {}).get("codeserver_url")
        or ""
    )

    return {
        "backend": {
            "status": "ok",
            "repo_root": str(repo_root),
            "execute_routes": {
                "local": "/api/execute/local",
                "remote": "/api/execute/remote",
            },
        },
        "worker": {
            "remote_url_available": bool(code_server_url),
            "remote_url": code_server_url,
        },
    }
PY

cat > "${APP_ROOT}/main.py" <<'PY'
from fastapi import FastAPI

from .routes import config, execute, health, ollama_proxy, runtime
from .settings import settings

app = FastAPI(title=settings.app_name)

app.include_router(health.router)
app.include_router(config.router)
app.include_router(ollama_proxy.router)
app.include_router(execute.router)
app.include_router(runtime.router)


@app.get("/")
def root() -> dict:
    return {
        "name": settings.app_name,
        "status": "running",
        "health": "/health",
        "runtime_status": "/api/status/runtime",
    }
PY

cat > "${CUSTOMIDE_ROOT}/scripts/start_local_stack.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOMIDE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_ROOT="${CUSTOMIDE_ROOT}/backend"
FRONTEND_ROOT="${CUSTOMIDE_ROOT}/frontend"

PYTHON_BIN="${PYTHON_BIN:-python3}"
BACKEND_PORT="${BACKEND_PORT:-5555}"
FRONTEND_PORT="${FRONTEND_PORT:-5570}"

cd "${BACKEND_ROOT}"
if [[ ! -d .venv ]]; then
  "${PYTHON_BIN}" -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null

uvicorn app.main:app --host 127.0.0.1 --port "${BACKEND_PORT}" >/tmp/customide-backend.log 2>&1 &
BACK_PID=$!

cd "${FRONTEND_ROOT}"
"${PYTHON_BIN}" -m http.server "${FRONTEND_PORT}" >/tmp/customide-frontend.log 2>&1 &
FRONT_PID=$!

echo "backend_pid=${BACK_PID}"
echo "frontend_pid=${FRONT_PID}"
echo "backend_url=http://127.0.0.1:${BACKEND_PORT}"
echo "frontend_url=http://127.0.0.1:${FRONTEND_PORT}"
echo "Stop with: kill ${BACK_PID} ${FRONT_PID}"
SH

chmod +x "${CUSTOMIDE_ROOT}/scripts/start_local_stack.sh"

cat > "${FRONTEND_ROOT}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>CustomIDE - Dual Pane</title>
  <link rel="stylesheet" href="css/style.css">
</head>
<body>
  <div class="bg-orbit"></div>
  <header class="topbar">
    <div class="brand">CustomIDE</div>
    <div class="status" id="backendStatus">Backend: checking...</div>
  </header>

  <main class="layout">
    <section class="pane pane-left">
      <div class="pane-title">Windows Editor</div>
      <textarea id="editor" spellcheck="false">// Start coding here...</textarea>

      <div class="controls">
        <button id="btnRefreshStatus" type="button">Refresh Status</button>
        <button id="btnRunLocal" type="button">Run Local Echo</button>
        <button id="btnRunRemote" type="button">Run Remote Echo</button>
      </div>

      <div id="dashboard" class="dashboard"></div>
      <pre id="execOutput"></pre>
    </section>

    <section class="pane pane-right">
      <div class="pane-title">Worker 1 Remote View</div>
      <iframe id="remoteFrame" title="Worker 1 code-server view"></iframe>
      <div class="hint">Set remote URL in config when MTASK-0034 services are available.</div>
    </section>
  </main>

  <script src="js/config.js"></script>
  <script src="js/app.js"></script>
</body>
</html>
HTML

cat > "${FRONTEND_ROOT}/js/app.js" <<'JS'
(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");
  const outputEl = document.getElementById("execOutput");
  const dashboardEl = document.getElementById("dashboard");
  const btnRefresh = document.getElementById("btnRefreshStatus");
  const btnLocal = document.getElementById("btnRunLocal");
  const btnRemote = document.getElementById("btnRunRemote");

  const cfg = window.CUSTOMIDE_CONFIG || {
    backendBaseUrl: "http://127.0.0.1:5555",
    workerServicesPath: "../../config/worker1_services.json"
  };

  function renderDashboard(data) {
    const remote = data && data.worker ? data.worker : {};
    const backend = data && data.backend ? data.backend : {};
    const remoteUrl = remote.remote_url || "(not available yet)";

    dashboardEl.textContent = [
      "Runtime Dashboard",
      "- Backend: " + (backend.status || "unknown"),
      "- Local execute: " + ((backend.execute_routes || {}).local || "missing"),
      "- Remote execute: " + ((backend.execute_routes || {}).remote || "missing"),
      "- Remote URL available: " + (remote.remote_url_available ? "yes" : "no"),
      "- Remote URL: " + remoteUrl
    ].join("\n");
  }

  async function checkBackend() {
    try {
      const res = await fetch(cfg.backendBaseUrl + "/health");
      if (!res.ok) throw new Error("health failed");
      const data = await res.json();
      statusEl.textContent = "Backend: " + (data.status || "ok");
      return true;
    } catch (_err) {
      statusEl.textContent = "Backend: offline (start uvicorn on :5555)";
      return false;
    }
  }

  async function fetchRuntimeStatus() {
    try {
      const res = await fetch(cfg.backendBaseUrl + "/api/status/runtime");
      if (!res.ok) throw new Error("runtime status failed");
      const data = await res.json();
      renderDashboard(data);

      if (data.worker && data.worker.remote_url) {
        remoteFrame.src = data.worker.remote_url;
      }

      return data;
    } catch (_err) {
      renderDashboard({
        backend: { status: "offline", execute_routes: {} },
        worker: { remote_url_available: false, remote_url: "" }
      });
      return null;
    }
  }

  async function runLocal() {
    const payload = {
      command: "echo local-ok",
      cwd: "."
    };
    const res = await fetch(cfg.backendBaseUrl + "/api/execute/local", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    outputEl.textContent = JSON.stringify(data, null, 2);
  }

  async function runRemote() {
    const payload = {
      command: "echo remote-ok",
      host: "127.0.0.1",
      user: "invalid-user"
    };
    const res = await fetch(cfg.backendBaseUrl + "/api/execute/remote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    outputEl.textContent = JSON.stringify(data, null, 2);
  }

  btnRefresh.addEventListener("click", () => {
    fetchRuntimeStatus().catch((err) => {
      outputEl.textContent = "status refresh failed: " + err;
    });
  });

  btnLocal.addEventListener("click", () => {
    runLocal().catch((err) => {
      outputEl.textContent = "local run failed: " + err;
    });
  });

  btnRemote.addEventListener("click", () => {
    runRemote().catch((err) => {
      outputEl.textContent = "remote run failed: " + err;
    });
  });

  const backendOk = await checkBackend();
  await fetchRuntimeStatus();
  if (!backendOk) {
    statusEl.textContent += " | Run pilot_v1/customide/scripts/start_local_stack.sh";
  }
})();
JS

python3 -m py_compile "${ROUTES_ROOT}/runtime.py" "${APP_ROOT}/main.py"

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0042-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0042-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

sleep 3

HEALTH_JSON="$(curl -sSf http://127.0.0.1:5555/health)"
RUNTIME_JSON="$(curl -sSf http://127.0.0.1:5555/api/status/runtime)"
LOCAL_JSON="$(curl -sSf -X POST http://127.0.0.1:5555/api/execute/local -H 'Content-Type: application/json' -d '{"command":"echo selftest-ok","cwd":"."}')"
FRONTEND_OK="$(curl -sSf http://127.0.0.1:5570 >/dev/null && echo yes || echo no)"

echo "health_check=${HEALTH_JSON}"
echo "runtime_status=${RUNTIME_JSON}"
echo "local_exec=${LOCAL_JSON}"
echo "frontend_reachable=${FRONTEND_OK}"

kill "${BACK_PID}" "${FRONT_PID}" || true

if [[ "${LOCAL_JSON}" != *"selftest-ok"* ]]; then
  echo "error=local_execute_selftest_failed"
  exit 1
fi

echo "launch_flow=created"
echo "dashboard_status=completed"
echo "local_execute_selftest=passed"

git add \
  "pilot_v1/customide/backend/app/routes/runtime.py" \
  "pilot_v1/customide/backend/app/main.py" \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js" \
  "pilot_v1/customide/scripts/start_local_stack.sh"

git commit -m "customide: add local launch flow and runtime dashboard (MTASK-0042)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
