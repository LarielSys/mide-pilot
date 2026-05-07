from pathlib import Path
import os

import httpx
from fastapi import APIRouter, HTTPException

from ..services import load_worker_services
from ..settings import settings

router = APIRouter(prefix="/api/ollama", tags=["ollama"])


def _normalize_generate_url(raw_url: str) -> str:
    url = (raw_url or "").strip().rstrip("/")
    if not url:
        return ""

    lower = url.lower()
    if lower.endswith("/api/generate") or lower.endswith("/api/chat") or lower.endswith("/api/embeddings"):
        return url
    if lower.endswith("/api/ollama"):
        return f"{url}/generate"
    if lower.endswith("/api"):
        return f"{url}/generate"
    if lower.endswith(":11434"):
        return f"{url}/api/generate"
    if lower.endswith("/generate"):
        return url

    return f"{url}/api/generate"


def _resolve_target_url() -> str:
    env_generate_url = _normalize_generate_url(os.environ.get("CUSTOMIDE_OLLAMA_GENERATE_URL", ""))
    if env_generate_url:
        return env_generate_url

    env_legacy_url = _normalize_generate_url(os.environ.get("CUSTOMIDE_OLLAMA_URL", ""))
    if env_legacy_url:
        return env_legacy_url

    env_base_url = _normalize_generate_url(os.environ.get("CUSTOMIDE_OLLAMA_BASE_URL", ""))
    if env_base_url:
        return env_base_url

    _p = Path(__file__).resolve()
    repo_root = next((q for q in _p.parents if (q / ".git").exists()), _p.parents[5])
    svc = load_worker_services(repo_root)
    if svc.get("status") != "ok":
        raise HTTPException(status_code=503, detail="worker1_services.json missing")

    services = svc.get("services") or {}

    for key in ("ollama_generate_url", "ollama_generate", "ollama_proxy_generate", "ollama_url", "ollama_base_url"):
        value = services.get(key)
        if isinstance(value, str) and value.strip():
            return _normalize_generate_url(value)

    ollama_obj = (services.get("services") or {}).get("ollama") or {}
    for key in ("ollama_generate_url", "ollama_generate", "ollama_proxy_generate", "ollama_url", "ollama_base_url", "proxy_endpoint"):
        value = ollama_obj.get(key)
        if isinstance(value, str) and value.strip():
            return _normalize_generate_url(value)

    local_fallback = _normalize_generate_url(settings.ollama_base_url)
    if local_fallback:
        return local_fallback

    raise HTTPException(status_code=503, detail="No Ollama endpoint found in worker services config")


@router.get("/health")
def ollama_health() -> dict:
    target = _resolve_target_url()
    return {
        "status": "configured",
        "target": target,
    }


@router.post("/generate")
def ollama_generate(payload: dict) -> dict:
    target = _resolve_target_url()

    try:
        with httpx.Client(timeout=settings.request_timeout_seconds) as client:
            res = client.post(target, json=payload)
            res.raise_for_status()
            return res.json()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Upstream Ollama error: {exc}") from exc
