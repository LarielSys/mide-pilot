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

cd "${REPO_ROOT}"

echo "task=MTASK-0041"
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

cat > "${ROUTES_ROOT}/execute.py" <<'PY'
import shlex
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/api/execute", tags=["execute"])


class LocalExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=200)
    cwd: Optional[str] = None


class RemoteExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=200)
    host: str = Field(min_length=1, max_length=200)
    user: str = Field(min_length=1, max_length=120)
    key_path: Optional[str] = None


def _safe_cwd(path_str: Optional[str]) -> Path:
    base = Path.cwd()
    if not path_str:
        return base

    p = Path(path_str).expanduser().resolve()
    if not str(p).startswith(str(base)):
        raise HTTPException(status_code=400, detail="cwd must stay inside repo root")
    return p


@router.post("/local")
def execute_local(payload: LocalExecuteRequest) -> dict:
    cwd = _safe_cwd(payload.cwd)

    try:
        proc = subprocess.run(
            payload.command,
            cwd=str(cwd),
            shell=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Local command timed out: {exc}") from exc

    return {
        "command": payload.command,
        "cwd": str(cwd),
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
    }


@router.post("/remote")
def execute_remote(payload: RemoteExecuteRequest) -> dict:
    ssh_cmd = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=12",
    ]

    if payload.key_path:
        ssh_cmd.extend(["-i", payload.key_path])

    target = f"{payload.user}@{payload.host}"
    ssh_cmd.extend([target, payload.command])

    try:
        proc = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=35,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Remote command timed out: {exc}") from exc

    return {
        "target": target,
        "command": payload.command,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
        "ssh_command": " ".join(shlex.quote(x) for x in ssh_cmd),
    }
PY

cat > "${APP_ROOT}/main.py" <<'PY'
from fastapi import FastAPI

from .routes import config, execute, health, ollama_proxy
from .settings import settings

app = FastAPI(title=settings.app_name)

app.include_router(health.router)
app.include_router(config.router)
app.include_router(ollama_proxy.router)
app.include_router(execute.router)


@app.get("/")
def root() -> dict:
    return {
        "name": settings.app_name,
        "status": "running",
        "health": "/health",
    }
PY

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
        <button id="btnRunLocal" type="button">Run Local Echo</button>
        <button id="btnRunRemote" type="button">Run Remote Echo</button>
      </div>
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
  const btnLocal = document.getElementById("btnRunLocal");
  const btnRemote = document.getElementById("btnRunRemote");

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

  await checkBackend();
  const remoteOk = await resolveRemoteUrl();
  if (!remoteOk) {
    statusEl.textContent += " | Remote: waiting for code-server URL";
  }
})();
JS

python3 -m py_compile "${ROUTES_ROOT}/execute.py" "${APP_ROOT}/main.py"

echo "execution_routes=created"
echo "ui_wiring=completed"

git add \
  "pilot_v1/customide/backend/app/routes/execute.py" \
  "pilot_v1/customide/backend/app/main.py" \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js"

git commit -m "customide: add execution endpoints and UI wiring (MTASK-0041)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
