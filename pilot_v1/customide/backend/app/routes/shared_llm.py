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
