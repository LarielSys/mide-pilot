"""Messenger endpoint — in-memory message store for cockpit relay."""

import uuid
from collections import deque
from datetime import datetime, timezone

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel

router = APIRouter(prefix="/api/messenger", tags=["messenger"])

_MAX_MESSAGES = 100
_messages: deque = deque(maxlen=_MAX_MESSAGES)


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class MessageIn(BaseModel):
    text: str
    sender: str = "olegreen"
    type: str = "message"


@router.post("")
async def post_message(msg: MessageIn) -> JSONResponse:
    entry = {
        "id": str(uuid.uuid4())[:8],
        "text": msg.text,
        "sender": msg.sender,
        "type": msg.type,
        "timestamp": _utc_now_iso(),
    }
    _messages.append(entry)
    return JSONResponse(content={"ok": True, "id": entry["id"], "timestamp": entry["timestamp"]})


@router.get("")
async def get_messages(limit: int = 20) -> JSONResponse:
    msgs = list(_messages)[-limit:]
    return JSONResponse(content={"ok": True, "count": len(msgs), "messages": msgs})


@router.delete("")
async def clear_messages() -> JSONResponse:
    _messages.clear()
    return JSONResponse(content={"ok": True, "cleared": True})
