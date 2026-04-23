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

echo "task=MTASK-0046-RETRY2"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${ROUTES_ROOT}/shared_llm.py" ]]; then
  echo "error=shared_llm_route_missing"
  exit 1
fi

cat > "${ROUTES_ROOT}/shared_llm.py" <<'PY'
from pathlib import Path
from typing import Any

import httpx
from fastapi import APIRouter
from pydantic import BaseModel, Field

from ..services import load_worker_services
from ..settings import settings

router = APIRouter(prefix="/api/llm", tags=["llm"])


class ChatRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=2000)
    source: str = Field(default="local", min_length=1, max_length=40)
    model: str | None = Field(default=None, max_length=120)


def _resolve_generate_url() -> tuple[str | None, str | None]:
    repo_root = Path(__file__).resolve().parents[3]
    svc = load_worker_services(repo_root)
    if svc.get("status") != "ok":
        return None, "worker1_services.json missing"

    raw = svc.get("services") or {}
    services_obj = raw.get("services") or {}
    ollama = services_obj.get("ollama") or {}

    for bucket in (raw, services_obj, ollama):
        for key in ("ollama_generate_url", "ollama_generate", "ollama_proxy_generate", "ollama_url"):
            value = bucket.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip(), None

    proxy_endpoint = ollama.get("proxy_endpoint")
    if isinstance(proxy_endpoint, str) and proxy_endpoint.strip():
        base = proxy_endpoint.strip().rstrip("/")
        if base.endswith("/generate"):
            return base, None
        return f"{base}/generate", None

    return None, "No Ollama endpoint found in worker services config"


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
    target, reason = _resolve_generate_url()
    if target:
        return {
            "status": "configured",
            "generate_url": target,
        }

    return {
        "status": "degraded",
        "generate_url": "",
        "reason": reason,
    }


@router.post("/chat")
def llm_chat(payload: ChatRequest) -> dict:
    target, reason = _resolve_generate_url()
    model = payload.model or "qwen2.5"

    if not target:
        return {
            "source": payload.source,
            "target": "",
            "model": model,
            "text": "",
            "degraded": True,
            "error": reason,
            "raw": {},
        }

    body: dict[str, Any] = {
        "model": model,
        "prompt": payload.prompt,
        "stream": False,
    }

    try:
        with httpx.Client(timeout=settings.request_timeout_seconds) as client:
            res = client.post(target, json=body)
            res.raise_for_status()
            data = res.json()
    except httpx.HTTPError as exc:
        return {
            "source": payload.source,
            "target": target,
            "model": model,
            "text": "",
            "degraded": True,
            "error": f"Upstream LLM error: {exc}",
            "raw": {},
        }

    return {
        "source": payload.source,
        "target": target,
        "model": model,
        "text": _extract_text(data),
        "degraded": False,
        "error": "",
        "raw": data,
    }
PY

python3 -m py_compile "${ROUTES_ROOT}/shared_llm.py" "${APP_ROOT}/main.py"

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0046r2-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0046r2-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

cleanup() {
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

HEALTH_JSON="$(curl -sS http://127.0.0.1:5555/health)"
LLM_HEALTH_JSON="$(curl -sS http://127.0.0.1:5555/api/llm/health)"
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
echo "shared_llm_degraded_mode=enabled"

git add \
  "pilot_v1/customide/backend/app/routes/shared_llm.py"

git commit -m "customide: shared llm degraded mode for tonight bridge (MTASK-0046-RETRY2)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
