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

echo "task=MTASK-0043"
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

from ..services import load_worker_services

router = APIRouter(prefix="/api/execute", tags=["execute"])

MAX_OUTPUT_CHARS = 4000
ALLOWED_LOCAL_COMMANDS = {
    "echo",
    "pwd",
    "ls",
    "cat",
    "python3",
    "python",
}


class LocalExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=240)
    cwd: Optional[str] = None
    timeout_seconds: int = Field(default=20, ge=1, le=30)


class RemoteExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=240)
    host: Optional[str] = Field(default=None, max_length=200)
    user: Optional[str] = Field(default=None, max_length=120)
    key_path: Optional[str] = Field(default=None, max_length=260)
    timeout_seconds: int = Field(default=25, ge=1, le=35)
    use_worker_config: bool = True


def _safe_cwd(path_str: Optional[str]) -> Path:
    repo_root = Path(__file__).resolve().parents[4]
    if not path_str:
        return repo_root

    p = Path(path_str).expanduser().resolve()
    if not str(p).startswith(str(repo_root)):
        raise HTTPException(status_code=400, detail="cwd must stay inside repo root")
    return p


def _parse_local_command(command: str) -> list[str]:
    try:
        args = shlex.split(command)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid command syntax: {exc}") from exc

    if not args:
        raise HTTPException(status_code=400, detail="Empty command")

    base = args[0]
    if base not in ALLOWED_LOCAL_COMMANDS:
        allowed = ", ".join(sorted(ALLOWED_LOCAL_COMMANDS))
        raise HTTPException(status_code=400, detail=f"Command '{base}' is not allowed. Allowed: {allowed}")

    return args


def _resolve_remote_target(payload: RemoteExecuteRequest) -> tuple[str, str, Optional[str]]:
    host = payload.host
    user = payload.user
    key_path = payload.key_path

    if payload.use_worker_config:
        repo_root = Path(__file__).resolve().parents[4]
        services = load_worker_services(repo_root)

        host = host or services.get("worker_host") or services.get("host")
        user = user or services.get("worker_user") or services.get("ssh_user")
        key_path = key_path or services.get("ssh_key_path")

        services_obj = services.get("services") or {}
        host = host or services_obj.get("worker_host")
        user = user or services_obj.get("worker_user")
        key_path = key_path or services_obj.get("ssh_key_path")

    if not host or not user:
        raise HTTPException(status_code=400, detail="Remote target missing host/user and no worker config provided")

    return host, user, key_path


@router.post("/local")
def execute_local(payload: LocalExecuteRequest) -> dict:
    cwd = _safe_cwd(payload.cwd)
    args = _parse_local_command(payload.command)

    try:
        proc = subprocess.run(
            args,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=payload.timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Local command timed out: {exc}") from exc

    return {
        "command": payload.command,
        "argv": args,
        "cwd": str(cwd),
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-MAX_OUTPUT_CHARS:],
        "stderr": proc.stderr[-MAX_OUTPUT_CHARS:],
        "ok": proc.returncode == 0,
    }


@router.post("/remote")
def execute_remote(payload: RemoteExecuteRequest) -> dict:
    host, user, key_path = _resolve_remote_target(payload)

    ssh_cmd = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=12",
    ]

    if key_path:
        ssh_cmd.extend(["-i", key_path])

    target = f"{user}@{host}"
    ssh_cmd.extend([target, payload.command])

    try:
        proc = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=payload.timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Remote command timed out: {exc}") from exc

    return {
        "target": target,
        "command": payload.command,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-MAX_OUTPUT_CHARS:],
        "stderr": proc.stderr[-MAX_OUTPUT_CHARS:],
        "ssh_command": " ".join(shlex.quote(x) for x in ssh_cmd),
        "ok": proc.returncode == 0,
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
        <button id="btnRefreshStatus" type="button">Refresh Status</button>
      </div>

      <div class="exec-card">
        <label for="localCommand">Local command</label>
        <input id="localCommand" type="text" value="echo local-ok" />
        <button id="btnRunLocal" type="button">Run Local</button>
      </div>

      <div class="exec-card">
        <label for="remoteCommand">Remote command</label>
        <input id="remoteCommand" type="text" value="echo remote-ok" />
        <button id="btnRunRemote" type="button">Run Remote</button>
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

  const localInput = document.getElementById("localCommand");
  const remoteInput = document.getElementById("remoteCommand");

  const cfg = window.CUSTOMIDE_CONFIG || {
    backendBaseUrl: "http://127.0.0.1:5555",
  };

  function renderJson(data) {
    outputEl.textContent = JSON.stringify(data, null, 2);
  }

  function setBusy(isBusy, label) {
    btnLocal.disabled = isBusy;
    btnRemote.disabled = isBusy;
    btnRefresh.disabled = isBusy;
    if (isBusy) {
      statusEl.textContent = label || "Running...";
    }
  }

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
    const res = await fetch(cfg.backendBaseUrl + "/api/status/runtime");
    if (!res.ok) {
      throw new Error("runtime status failed");
    }

    const data = await res.json();
    renderDashboard(data);

    if (data.worker && data.worker.remote_url) {
      remoteFrame.src = data.worker.remote_url;
    }

    return data;
  }

  async function runLocal() {
    const payload = {
      command: localInput.value.trim(),
      cwd: ".",
      timeout_seconds: 20,
    };

    if (!payload.command) {
      throw new Error("Local command is empty");
    }

    const res = await fetch(cfg.backendBaseUrl + "/api/execute/local", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.detail || "Local execution failed");
    }

    renderJson(data);
  }

  async function runRemote() {
    const payload = {
      command: remoteInput.value.trim(),
      use_worker_config: true,
      timeout_seconds: 25,
    };

    if (!payload.command) {
      throw new Error("Remote command is empty");
    }

    const res = await fetch(cfg.backendBaseUrl + "/api/execute/remote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.detail || "Remote execution failed");
    }

    renderJson(data);
  }

  btnRefresh.addEventListener("click", async () => {
    try {
      setBusy(true, "Refreshing status...");
      await fetchRuntimeStatus();
      await checkBackend();
    } catch (err) {
      outputEl.textContent = "status refresh failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  btnLocal.addEventListener("click", async () => {
    try {
      setBusy(true, "Running local command...");
      await runLocal();
      await checkBackend();
    } catch (err) {
      outputEl.textContent = "local run failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  btnRemote.addEventListener("click", async () => {
    try {
      setBusy(true, "Running remote command...");
      await runRemote();
      await checkBackend();
    } catch (err) {
      outputEl.textContent = "remote run failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  const backendOk = await checkBackend();
  if (backendOk) {
    try {
      await fetchRuntimeStatus();
    } catch (err) {
      outputEl.textContent = "status bootstrap failed: " + err;
    }
  } else {
    statusEl.textContent += " | Run pilot_v1/customide/scripts/start_local_stack.sh";
  }
})();
JS

python3 -m py_compile "${ROUTES_ROOT}/execute.py"

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0043-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0043-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

sleep 3

HEALTH_JSON="$(curl -sSf http://127.0.0.1:5555/health)"
RUNTIME_JSON="$(curl -sSf http://127.0.0.1:5555/api/status/runtime)"
LOCAL_OK_JSON="$(curl -sSf -X POST http://127.0.0.1:5555/api/execute/local -H 'Content-Type: application/json' -d '{"command":"echo hardened-ok","cwd":".","timeout_seconds":10}')"
LOCAL_BLOCKED_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/execute/local -H 'Content-Type: application/json' -d '{"command":"bash -lc whoami","cwd":".","timeout_seconds":10}')"
FRONTEND_OK="$(curl -sSf http://127.0.0.1:5570 >/dev/null && echo yes || echo no)"

echo "health_check=${HEALTH_JSON}"
echo "runtime_status=${RUNTIME_JSON}"
echo "local_exec_ok=${LOCAL_OK_JSON}"
echo "local_exec_blocked=${LOCAL_BLOCKED_JSON}"
echo "frontend_reachable=${FRONTEND_OK}"

kill "${BACK_PID}" "${FRONT_PID}" || true

if [[ "${LOCAL_OK_JSON}" != *"hardened-ok"* ]]; then
  echo "error=local_hardening_selftest_failed"
  exit 1
fi

if [[ "${LOCAL_BLOCKED_JSON}" != *"not allowed"* ]]; then
  echo "error=allowlist_enforcement_failed"
  exit 1
fi

echo "execute_hardening=completed"
echo "ui_command_inputs=completed"
echo "local_allowlist_enforced=passed"

git add \
  "pilot_v1/customide/backend/app/routes/execute.py" \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js"

git commit -m "customide: harden execute API and interactive command UI (MTASK-0043)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
