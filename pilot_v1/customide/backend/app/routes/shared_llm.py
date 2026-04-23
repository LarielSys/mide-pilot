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
