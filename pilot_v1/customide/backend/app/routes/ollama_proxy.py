from pathlib import Path

import httpx
from fastapi import APIRouter, HTTPException

from ..services import load_worker_services
from ..settings import settings

router = APIRouter(prefix="/api/ollama", tags=["ollama"])


def _resolve_target_url() -> str:
    repo_root = Path(__file__).resolve().parents[3]
    svc = load_worker_services(repo_root)
    if svc.get("status") != "ok":
        raise HTTPException(status_code=503, detail="worker1_services.json missing")

    services = svc.get("services") or {}

    for key in ("ollama_generate_url", "ollama_generate", "ollama_proxy_generate", "ollama_url"):
        value = services.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()

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
