import json
from pathlib import Path
import time
from typing import Any
import asyncio

import httpx
from fastapi import APIRouter, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from ..services import load_worker_services
from ..settings import settings

router = APIRouter(prefix="/api/llm", tags=["llm"])


class ChatRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=2000)
    source: str = Field(default="local", min_length=1, max_length=40)
    model: str | None = Field(default=None, max_length=120)


class HistoryEntry(BaseModel):
    role: str = Field(min_length=1, max_length=20)
    text: str = Field(min_length=1, max_length=8000)
    model: str = Field(default="ollama", max_length=120)
    source: str = Field(default="local-ide", max_length=40)
    ts: int = Field(default=0)


def _history_path() -> Path:
    repo_root = Path(__file__).resolve().parents[3]
    return (repo_root / settings.llm_chat_history_path).resolve()


def _load_history() -> list[dict[str, Any]]:
    path = _history_path()
    if not path.exists():
        return []

    try:
        with path.open("r", encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []

    if not isinstance(raw, list):
        return []

    out: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "").strip()
        text = str(item.get("text") or "").strip()
        if not role or not text:
            continue
        out.append({
            "role": role,
            "text": text,
            "model": str(item.get("model") or "ollama"),
            "source": str(item.get("source") or "local-ide"),
            "ts": int(item.get("ts") or 0),
        })
    return out


def _save_history(rows: list[dict[str, Any]]) -> None:
    path = _history_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(rows[-400:], f, ensure_ascii=True, indent=2)


def _append_history(role: str, text: str, model: str, source: str) -> None:
    clean_text = str(text or "").strip()
    if not clean_text:
        return

    rows = _load_history()
    rows.append({
        "role": str(role or "assistant"),
        "text": clean_text,
        "model": str(model or "ollama"),
        "source": str(source or "local-ide"),
        "ts": int(time.time() * 1000),
    })
    _save_history(rows)


async def _append_history_async(role: str, text: str, model: str, source: str) -> None:
    """Append history asynchronously to avoid blocking responses."""
    clean_text = str(text or "").strip()
    if not clean_text:
        return

    # Run file I/O in thread pool to avoid blocking
    await asyncio.get_event_loop().run_in_executor(
        None,
        lambda: _append_history(role, text, model, source)
    )


def _map_source(raw: str) -> str:
    value = (raw or "").strip().lower()
    if value in ("remote", "remote-ide"):
        return "remote-ide"
    return "local-ide"


def _resolve_generate_url() -> tuple[str | None, str, str | None]:
    repo_root = Path(__file__).resolve().parents[3]
    svc = load_worker_services(repo_root)
    if svc.get("status") == "ok":
        raw = svc.get("services") or {}
        services_obj = raw.get("services") or {}
        ollama = services_obj.get("ollama") or {}

        for bucket_name, bucket in (("services", raw), ("services.services", services_obj), ("services.services.ollama", ollama)):
            for key in ("proxy_endpoint", "ollama_proxy_generate", "ollama_generate_url", "ollama_generate", "ollama_url"):
                value = bucket.get(key)
                if isinstance(value, str) and value.strip():
                    url = value.strip().rstrip("/")
                    if url.endswith("/api"):
                        url = f"{url}/generate"
                    if url.endswith("/api/ollama"):
                        url = f"{url}/generate"
                    return url, f"{bucket_name}.{key}", None

    env_url = (settings.ollama_url or "").strip() if hasattr(settings, "ollama_url") else ""
    if env_url:
        return env_url, "settings.ollama_url", None

    if svc.get("status") != "ok":
        return None, "none", "worker1_services.json missing"

    return None, "none", "No Ollama endpoint found in worker services config"


def _resolve_default_model() -> str:
    repo_root = Path(__file__).resolve().parents[3]
    svc = load_worker_services(repo_root)
    raw = svc.get("services") or {}
    services_obj = raw.get("services") or {}
    ollama = services_obj.get("ollama") or {}
    model = ollama.get("model_primary")
    if isinstance(model, str) and model.strip():
        return model.strip()
    return "qwen2.5-coder:7b"


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


@router.get("/history")
def llm_history(limit: int = Query(default=200, ge=1, le=400)) -> dict[str, Any]:
    rows = _load_history()
    return {
        "status": "ok",
        "count": min(len(rows), limit),
        "messages": rows[-limit:],
    }


@router.post("/chat")
async def llm_chat_stream(payload: ChatRequest):
    """Stream Ollama responses via Server-Sent Events for real-time display."""
    target, source_key, reason = _resolve_generate_url()
    model = payload.model or _resolve_default_model()
    mapped_source = _map_source(payload.source)

    # Append user message synchronously upfront so it shows immediately
    _append_history("user", payload.prompt, model, mapped_source)

    if not target:
        error_msg = reason or "No Ollama endpoint configured"
        # Send error as SSE event
        async def error_stream():
            yield f"data: {json.dumps({'error': error_msg, 'done': True})}\n\n"
        # Append error to history asynchronously
        asyncio.create_task(_append_history_async("assistant", f"[error] {error_msg}", model, mapped_source))
        return StreamingResponse(error_stream(), media_type="text/event-stream")

    body: dict[str, Any] = {
        "model": model,
        "prompt": payload.prompt,
        "stream": True,  # Enable streaming!
    }

    async def stream_response():
        """Generator that yields SSE events with Ollama token chunks."""
        full_response = ""
        try:
            async with httpx.AsyncClient(timeout=settings.request_timeout_seconds) as client:
                async with client.stream("POST", target, json=body) as res:
                    res.raise_for_status()
                    async for line in res.aiter_lines():
                        if not line:
                            continue
                        try:
                            chunk = json.loads(line)
                            token = _extract_text(chunk) or ""
                            full_response += token
                            # Send each token as SSE event
                            yield f"data: {json.dumps({'token': token, 'done': False})}\n\n"
                        except json.JSONDecodeError:
                            continue
        except httpx.HTTPError as exc:
            error_msg = f"Upstream LLM error: {exc}"
            full_response = f"[error] {error_msg}"
            yield f"data: {json.dumps({'error': error_msg, 'done': True})}\n\n"

        # Send completion marker
        yield f"data: {json.dumps({'done': True, 'text': full_response})}\n\n"

        # Persist response asynchronously after streaming completes
        if full_response and not full_response.startswith("[error]"):
            asyncio.create_task(_append_history_async("assistant", full_response, model, mapped_source))
        elif full_response.startswith("[error]"):
            asyncio.create_task(_append_history_async("assistant", full_response, model, mapped_source))

    return StreamingResponse(stream_response(), media_type="text/event-stream")
