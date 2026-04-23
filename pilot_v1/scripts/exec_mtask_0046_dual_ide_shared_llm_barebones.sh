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

echo "task=MTASK-0046"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${ROUTES_ROOT}/ollama_proxy.py" ]]; then
  echo "error=ollama_proxy_missing"
  exit 1
fi
if [[ ! -f "${FRONTEND_ROOT}/js/app.js" ]]; then
  echo "error=frontend_missing"
  exit 1
fi

cat > "${ROUTES_ROOT}/shared_llm.py" <<'PY'
from pathlib import Path
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ..services import load_worker_services
from ..settings import settings

router = APIRouter(prefix="/api/llm", tags=["llm"])


class ChatRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=2000)
    source: str = Field(default="local", min_length=1, max_length=40)
    model: str | None = Field(default=None, max_length=120)


def _resolve_generate_url() -> str:
    repo_root = Path(__file__).resolve().parents[3]
    svc = load_worker_services(repo_root)
    if svc.get("status") != "ok":
        raise HTTPException(status_code=503, detail="worker1_services.json missing")

    services = svc.get("services") or {}
    ollama = services.get("ollama") or {}

    for key in ("ollama_generate_url", "ollama_generate", "ollama_proxy_generate", "ollama_url"):
        value = services.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()

    proxy_endpoint = ollama.get("proxy_endpoint")
    if isinstance(proxy_endpoint, str) and proxy_endpoint.strip():
        base = proxy_endpoint.strip().rstrip("/")
        return f"{base}/generate"

    raise HTTPException(status_code=503, detail="No Ollama endpoint found in worker services config")


def _extract_text(data: dict[str, Any]) -> str:
    response_text = data.get("response")
    if isinstance(response_text, str) and response_text.strip():
        return response_text.strip()

    message = data.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return content.strip()

    return ""


@router.get("/health")
def llm_health() -> dict:
    return {
        "status": "configured",
        "generate_url": _resolve_generate_url(),
    }


@router.post("/chat")
def llm_chat(payload: ChatRequest) -> dict:
    target = _resolve_generate_url()

    body: dict[str, Any] = {
        "model": payload.model or "qwen2.5",
        "prompt": payload.prompt,
        "stream": False,
    }

    try:
        with httpx.Client(timeout=settings.request_timeout_seconds) as client:
            res = client.post(target, json=body)
            res.raise_for_status()
            data = res.json()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Upstream LLM error: {exc}") from exc

    return {
        "source": payload.source,
        "target": target,
        "model": body["model"],
        "text": _extract_text(data),
        "raw": data,
    }
PY

cat > "${APP_ROOT}/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .routes import config, execute, health, ollama_proxy, runtime, shared_llm
from .settings import settings

app = FastAPI(title=settings.app_name)

# Barebones interoperability for tonight: allow both local pane and remote IDE tools
# to call the same backend LLM bridge endpoint.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(config.router)
app.include_router(ollama_proxy.router)
app.include_router(execute.router)
app.include_router(runtime.router)
app.include_router(shared_llm.router)


@app.get("/")
def root() -> dict:
    return {
        "name": settings.app_name,
        "status": "running",
        "health": "/health",
        "runtime_status": "/api/status/runtime",
        "shared_llm": "/api/llm/chat",
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

      <div class="exec-card">
        <label for="sharedPrompt">Shared LLM prompt (both IDEs use this same backend route)</label>
        <textarea id="sharedPrompt" rows="3">Give me a short coding tip for tonight.</textarea>
        <div class="controls">
          <button id="btnAskLocalLLM" type="button">Ask Shared LLM (Local IDE)</button>
          <button id="btnAskRemoteLLM" type="button">Ask Shared LLM (Remote IDE)</button>
        </div>
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
  const btnAskLocalLLM = document.getElementById("btnAskLocalLLM");
  const btnAskRemoteLLM = document.getElementById("btnAskRemoteLLM");

  const localInput = document.getElementById("localCommand");
  const remoteInput = document.getElementById("remoteCommand");
  const sharedPrompt = document.getElementById("sharedPrompt");

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
    btnAskLocalLLM.disabled = isBusy;
    btnAskRemoteLLM.disabled = isBusy;
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
      "- Shared LLM: /api/llm/chat",
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

  async function askSharedLlm(source) {
    const prompt = sharedPrompt.value.trim();
    if (!prompt) {
      throw new Error("Shared prompt is empty");
    }

    const res = await fetch(cfg.backendBaseUrl + "/api/llm/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt, source }),
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.detail || "Shared LLM call failed");
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

  btnAskLocalLLM.addEventListener("click", async () => {
    try {
      setBusy(true, "Asking shared LLM from local IDE...");
      await askSharedLlm("local-ide");
      await checkBackend();
    } catch (err) {
      outputEl.textContent = "shared llm local failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  btnAskRemoteLLM.addEventListener("click", async () => {
    try {
      setBusy(true, "Asking shared LLM from remote IDE...");
      await askSharedLlm("remote-ide");
      await checkBackend();
    } catch (err) {
      outputEl.textContent = "shared llm remote failed: " + err;
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

python3 -m py_compile "${ROUTES_ROOT}/shared_llm.py" "${APP_ROOT}/main.py"

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0046-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0046-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

cleanup() {
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

HEALTH_JSON="$(curl -sSf http://127.0.0.1:5555/health)"
LLM_HEALTH_JSON="$(curl -sSf http://127.0.0.1:5555/api/llm/health)"
LLM_LOCAL_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/llm/chat -H 'Content-Type: application/json' -d '{"prompt":"Reply with local-bridge-ok only.","source":"local-ide"}')"
LLM_REMOTE_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/llm/chat -H 'Content-Type: application/json' -d '{"prompt":"Reply with remote-bridge-ok only.","source":"remote-ide"}')"
FRONTEND_OK="$(curl -sSf http://127.0.0.1:5570 >/dev/null && echo yes || echo no)"

echo "health_check=${HEALTH_JSON}"
echo "llm_health=${LLM_HEALTH_JSON}"
echo "llm_local=${LLM_LOCAL_JSON}"
echo "llm_remote=${LLM_REMOTE_JSON}"
echo "frontend_reachable=${FRONTEND_OK}"

if [[ "${FRONTEND_OK}" != "yes" ]]; then
  echo "error=frontend_not_reachable"
  exit 1
fi

if [[ "${LLM_LOCAL_JSON}" != *"source"* || "${LLM_LOCAL_JSON}" != *"local-ide"* ]]; then
  echo "error=shared_llm_local_path_failed"
  exit 1
fi

if [[ "${LLM_REMOTE_JSON}" != *"source"* || "${LLM_REMOTE_JSON}" != *"remote-ide"* ]]; then
  echo "error=shared_llm_remote_path_failed"
  exit 1
fi

echo "dual_ide_visible=passed"
echo "shared_llm_local=passed"
echo "shared_llm_remote=passed"

git add \
  "pilot_v1/customide/backend/app/main.py" \
  "pilot_v1/customide/backend/app/routes/shared_llm.py" \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js"

git commit -m "customide: dual-pane shared llm barebones bridge (MTASK-0046)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
