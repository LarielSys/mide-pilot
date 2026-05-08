"""Messenger endpoint — in-memory message store for cockpit relay."""

import asyncio
import uuid
from collections import deque
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from .mtask import process_chat_command

router = APIRouter(prefix="/api/messenger", tags=["messenger"])

_MAX_MESSAGES = 100
_messages: deque = deque(maxlen=_MAX_MESSAGES)
_CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
    "Access-Control-Allow-Headers": "*",
}

# mide-chat is on the same Docker bridge network
_MIDECHAT_BROADCAST = "http://mide-chat:7070/rooms/OPS-CENTRAL/broadcast"


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class MessageIn(BaseModel):
    text: str
    sender: str = "olegreen"
    type: str = "message"


class MessageReadIn(BaseModel):
    limit: int = 20


def _cors_json(content: dict, status_code: int = 200) -> JSONResponse:
    return JSONResponse(content=content, status_code=status_code, headers=_CORS_HEADERS)


async def _forward_to_midechat(sender: str, text: str) -> None:
    """Fire-and-forget: forward message to mide-chat OPS-CENTRAL room."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            await client.post(
                _MIDECHAT_BROADCAST,
                json={"sender": sender.upper(), "text": text, "kind": "chat"},
            )
    except Exception:
        pass  # Never block the cockpit on mide-chat availability


@router.options("")
async def options_messenger() -> JSONResponse:
    return _cors_json({"ok": True})


@router.post("")
async def post_message(msg: MessageIn) -> JSONResponse:
    # Product command lane: mtask:, mtask approve <id>, mtask pending
    mtask_result = process_chat_command(msg.text, msg.sender)
    if mtask_result is not None:
        entry = {
            "id": str(uuid.uuid4())[:8],
            "text": msg.text,
            "sender": msg.sender,
            "type": "mtask",
            "timestamp": _utc_now_iso(),
            "mtask": mtask_result,
        }
        _messages.append(entry)
        return _cors_json({"ok": True, "id": entry["id"], "timestamp": entry["timestamp"], "mtask": mtask_result})

    entry = {
        "id": str(uuid.uuid4())[:8],
        "text": msg.text,
        "sender": msg.sender,
        "type": msg.type,
        "timestamp": _utc_now_iso(),
    }
    _messages.append(entry)
    # Forward to mide-chat OPS-CENTRAL room (non-blocking)
    asyncio.create_task(_forward_to_midechat(msg.sender, msg.text))
    return _cors_json({"ok": True, "id": entry["id"], "timestamp": entry["timestamp"]})


@router.get("")
async def get_messages(limit: int = 20) -> JSONResponse:
    msgs = list(_messages)[-limit:]
    return _cors_json({"ok": True, "count": len(msgs), "messages": msgs})


@router.post("/read")
async def read_messages(body: MessageReadIn) -> JSONResponse:
    limit = max(1, min(body.limit, _MAX_MESSAGES))
    msgs = list(_messages)[-limit:]
    return _cors_json({"ok": True, "count": len(msgs), "messages": msgs})


@router.delete("")
async def clear_messages() -> JSONResponse:
    _messages.clear()
    return _cors_json({"ok": True, "cleared": True})
