"""
MIDE Chat Platform — Multi-user WebSocket chat server with local Ollama AI participant.
Rooms, presence, history, AI triggers, REST API.
"""

from __future__ import annotations
import asyncio
import json
import os
import time
import uuid
from collections import defaultdict, deque
from datetime import datetime, timezone
from typing import Dict, Set

import httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

OLLAMA_BASE = os.getenv("OLLAMA_BASE_URL", "http://ollama:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_CHAT_MODEL", "qwen2.5-coder:7b")
AI_NAME = os.getenv("AI_NAME", "LARIEL")
HISTORY_LIMIT = int(os.getenv("HISTORY_LIMIT", "200"))
AI_AUTO_REPLY = os.getenv("AI_AUTO_REPLY", "true").lower() in ("1", "true", "yes", "on")

app = FastAPI(title="MIDE Chat")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── In-memory state ────────────────────────────────────────────────────────────

# room_name → set of WebSocket connections
connections: Dict[str, Set[WebSocket]] = defaultdict(set)
# room_name → username for each ws
ws_users: Dict[WebSocket, str] = {}
# room_name → deque of message dicts
history: Dict[str, deque] = defaultdict(lambda: deque(maxlen=HISTORY_LIMIT))
# room_name → set of usernames currently online
presence: Dict[str, Set[str]] = defaultdict(set)


# ── Helpers ────────────────────────────────────────────────────────────────────

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def build_msg(room: str, sender: str, text: str, kind: str = "chat") -> dict:
    return {
        "id": str(uuid.uuid4())[:8],
        "room": room,
        "sender": sender,
        "text": text,
        "kind": kind,
        "ts": now_iso(),
    }


async def broadcast(room: str, msg: dict):
    history[room].append(msg)
    dead: list[WebSocket] = []
    payload = json.dumps(msg)
    for ws in list(connections[room]):
        try:
            await ws.send_text(payload)
        except Exception:
            dead.append(ws)
    for ws in dead:
        _remove_ws(ws, room)


def _remove_ws(ws: WebSocket, room: str):
    connections[room].discard(ws)
    username = ws_users.pop(ws, None)
    if username:
        presence[room].discard(username)


async def broadcast_presence(room: str):
    msg = build_msg(room, "SYSTEM", json.dumps(list(presence[room])), kind="presence")
    await broadcast(room, msg)


async def ai_respond(room: str, trigger_text: str, caller: str):
    """Call Ollama and stream response into the room."""
    system_prompt = (
        f"You are {AI_NAME}, a senior software and network engineer embedded in "
        "the MIDE cockpit. You have deep expertise in distributed systems, "
        "Linux, Docker, Kubernetes, Python/FastAPI, JavaScript, networking "
        "(TCP/IP, DNS, HTTP, WebSockets, firewalls, NAT, VPN, routing), "
        "git operations, CI/CD, and infrastructure troubleshooting. "
        "When the user pastes pane data prefixed with [CTX <pane>], analyze it "
        "as that pane's live state and answer their question grounded in that "
        "data: identify root causes, point to specific lines/values, and propose "
        "concrete next steps (commands, config changes, or code). "
        "Be concise and technical. Use code blocks for commands. "
        "Keep replies short unless depth is explicitly requested."
    )
    chat_payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": trigger_text},
        ],
    }
    generate_payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "prompt": f"{system_prompt}\n\nUser: {trigger_text}",
    }
    # typing indicator
    await broadcast(room, build_msg(room, AI_NAME, "...", kind="typing"))
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            # Prefer /api/chat, fallback to /api/generate if chat route is unavailable.
            resp = await client.post(f"{OLLAMA_BASE}/api/chat", json=chat_payload)
            if resp.status_code == 404:
                resp = await client.post(f"{OLLAMA_BASE}/api/generate", json=generate_payload)
            resp.raise_for_status()
            data = resp.json()
            reply = data.get("message", {}).get("content", "").strip()
            if not reply:
                reply = str(data.get("response", "")).strip()
    except Exception as exc:
        reply = f"[ERROR] Ollama unreachable: {exc}"
    # remove typing indicator from history, broadcast real response
    if history[room] and history[room][-1].get("kind") == "typing":
        history[room].pop()
    msg = build_msg(room, AI_NAME, reply, kind="ai")
    await broadcast(room, msg)


# ── WebSocket endpoint ─────────────────────────────────────────────────────────

@app.websocket("/ws/{room}/{username}")
async def ws_endpoint(ws: WebSocket, room: str, username: str):
    await ws.accept()
    connections[room].add(ws)
    ws_users[ws] = username
    presence[room].add(username)

    # Send history to newcomer
    for m in list(history[room]):
        await ws.send_text(json.dumps(m))

    # Announce join
    await broadcast(room, build_msg(room, "SYSTEM", f"{username} joined", kind="join"))
    await broadcast_presence(room)

    try:
        while True:
            raw = await ws.receive_text()
            try:
                data = json.loads(raw)
                text = data.get("text", "").strip()
            except Exception:
                text = raw.strip()

            if not text:
                continue

            msg = build_msg(room, username, text)
            await broadcast(room, msg)

            # AI trigger: starts with @ai or @LARIEL
            lower = text.lower()
            if lower.startswith("@ai ") or lower.startswith(f"@{AI_NAME.lower()} "):
                trigger = text.split(" ", 1)[1] if " " in text else text
                asyncio.create_task(ai_respond(room, trigger, username))
            elif AI_AUTO_REPLY and username != AI_NAME:
                # Messenger-like behavior: AI responds automatically after each human message.
                asyncio.create_task(ai_respond(room, text, username))

    except WebSocketDisconnect:
        pass
    finally:
        _remove_ws(ws, room)
        await broadcast(room, build_msg(room, "SYSTEM", f"{username} left", kind="leave"))
        await broadcast_presence(room)


# ── REST endpoints ─────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "model": OLLAMA_MODEL, "ai": AI_NAME}


@app.get("/rooms")
async def list_rooms():
    return {
        "rooms": [
            {
                "name": r,
                "users": list(presence[r]),
                "message_count": len(history[r]),
            }
            for r in connections
        ]
    }


@app.get("/rooms/{room}/history")
async def room_history(room: str, limit: int = 50):
    msgs = list(history[room])
    return {"room": room, "messages": msgs[-limit:]}


@app.get("/rooms/{room}/users")
async def room_users(room: str):
    return {"room": room, "users": list(presence[room])}


@app.post("/rooms/{room}/broadcast")
async def api_broadcast(room: str, body: dict):
    """POST a message into a room from an external service (e.g. cockpit/worker)."""
    sender = body.get("sender", "EXTERNAL")
    text = body.get("text", "")
    kind = body.get("kind", "system")
    if not text:
        raise HTTPException(400, "text required")
    msg = build_msg(room, sender, text, kind=kind)
    await broadcast(room, msg)
    return {"ok": True, "msg_id": msg["id"]}


@app.post("/rooms/{room}/ask-ai")
async def ask_ai(room: str, body: dict):
    """Trigger AI response in a room from external caller."""
    text = body.get("text", "")
    caller = body.get("caller", "API")
    if not text:
        raise HTTPException(400, "text required")
    asyncio.create_task(ai_respond(room, text, caller))
    return {"ok": True, "status": "ai_triggered"}


# ── Static frontend ────────────────────────────────────────────────────────────

app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
