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
SERVICES_JSON="${REPO_ROOT}/pilot_v1/config/worker1_services.json"

cd "${REPO_ROOT}"

echo "task=MTASK-0047"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

mkdir -p "$(dirname "${SERVICES_JSON}")"
if [[ ! -f "${SERVICES_JSON}" ]]; then
  cat > "${SERVICES_JSON}" <<'JSON'
{
  "status": "ok",
  "services": {
    "ollama_generate_url": "http://127.0.0.1:11434/api/generate",
    "ollama": {
      "proxy_endpoint": "http://127.0.0.1:11434/api/generate"
    }
  }
}
JSON
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


def _map_source(raw: str) -> str:
    value = (raw or "").strip().lower()
    if value in ("remote", "remote-ide"):
        return "remote-ide"
    return "local-ide"


def _resolve_generate_url() -> tuple[str | None, str, str | None]:
    env_url = (settings.ollama_url or "").strip() if hasattr(settings, "ollama_url") else ""
    if env_url:
        return env_url, "settings.ollama_url", None

    repo_root = Path(__file__).resolve().parents[3]
    svc = load_worker_services(repo_root)
    if svc.get("status") != "ok":
        return None, "none", "worker1_services.json missing"

    raw = svc.get("services") or {}
    services_obj = raw.get("services") or {}
    ollama = services_obj.get("ollama") or {}

    for bucket_name, bucket in (("services", raw), ("services.services", services_obj), ("services.services.ollama", ollama)):
        for key in ("ollama_generate_url", "ollama_generate", "ollama_proxy_generate", "ollama_url", "proxy_endpoint"):
            value = bucket.get(key)
            if isinstance(value, str) and value.strip():
                url = value.strip().rstrip("/")
                if url.endswith("/api"):
                    url = f"{url}/generate"
                return url, f"{bucket_name}.{key}", None

    return None, "none", "No Ollama endpoint found in worker services config"


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
def llm_health() -> dict[str, Any]:
    target, source_key, reason = _resolve_generate_url()
    if target:
        return {
            "status": "configured",
            "generate_url": target,
            "source_key": source_key,
        }

    return {
        "status": "degraded",
        "generate_url": "",
        "source_key": source_key,
        "reason": reason,
    }


@router.post("/chat")
def llm_chat(payload: ChatRequest) -> dict[str, Any]:
    target, source_key, reason = _resolve_generate_url()
    model = payload.model or "qwen2.5"
    mapped_source = _map_source(payload.source)

    if not target:
        return {
            "source": mapped_source,
            "target": "",
            "model": model,
            "text": "",
            "degraded": True,
            "error": reason,
            "source_key": source_key,
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
            "source": mapped_source,
            "target": target,
            "model": model,
            "text": "",
            "degraded": True,
            "error": f"Upstream LLM error: {exc}",
            "source_key": source_key,
            "raw": {},
        }

    return {
        "source": mapped_source,
        "target": target,
        "model": model,
        "text": _extract_text(data),
        "degraded": False,
        "error": "",
        "source_key": source_key,
        "raw": data,
    }
PY

python3 -m py_compile "${ROUTES_ROOT}/shared_llm.py"

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0047-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0047-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

cleanup() {
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

HEALTH_JSON="$(curl -sS http://127.0.0.1:5555/api/llm/health)"
LLM_LOCAL_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/llm/chat -H 'Content-Type: application/json' -d '{"prompt":"Reply with local-contract-ok only.","source":"local"}')"
LLM_REMOTE_JSON="$(curl -sS -X POST http://127.0.0.1:5555/api/llm/chat -H 'Content-Type: application/json' -d '{"prompt":"Reply with remote-contract-ok only.","source":"remote"}')"

echo "llm_health=${HEALTH_JSON}"
echo "llm_local=${LLM_LOCAL_JSON}"
echo "llm_remote=${LLM_REMOTE_JSON}"

if [[ "${HEALTH_JSON}" != *"status"* ]]; then
  echo "error=llm_health_contract_missing"
  exit 1
fi
if [[ "${LLM_LOCAL_JSON}" != *"local-ide"* ]]; then
  echo "error=local_source_mapping_failed"
  exit 1
fi
if [[ "${LLM_REMOTE_JSON}" != *"remote-ide"* ]]; then
  echo "error=remote_source_mapping_failed"
  exit 1
fi
if [[ "${LLM_LOCAL_JSON}" != *"degraded"* || "${LLM_REMOTE_JSON}" != *"degraded"* ]]; then
  echo "error=degraded_contract_missing"
  exit 1
fi

echo "phase12_config_resolution=passed"
echo "shared_llm_health_contract=passed"
echo "shared_llm_chat_contract=passed"

git add \
  "pilot_v1/customide/backend/app/routes/shared_llm.py" \
  "pilot_v1/config/worker1_services.json"

git commit -m "customide: stabilize shared llm config contract (MTASK-0047)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
