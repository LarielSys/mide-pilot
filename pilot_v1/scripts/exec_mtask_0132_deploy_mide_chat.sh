#!/usr/bin/env bash
# MTASK-0132 — Deploy mide-chat multi-user WebSocket chat service in Docker on Ubuntu
set -euo pipefail

REPO="/home/larieladmin"
CHAT_DIR="$REPO/mide-chat"
COMPOSE_FILE="$REPO/docker-compose.yml"
RESULT_FILE="/home/larieladmin/mide-pilot/pilot_v1/results/MTASK-0132.result.json"
TS_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[MTASK-0132] start $TS_START"

mkdir -p "$CHAT_DIR/static"

# ── Write all files via Python (avoids bash heredoc nesting issues) ────────────
python3 << 'PYEOF'
import os

chat_dir = "/home/larieladmin/mide-chat"
static_dir = chat_dir + "/static"
os.makedirs(static_dir, exist_ok=True)

# ── server.py ──────────────────────────────────────────────────────────────────
server_py = r'''from __future__ import annotations
import asyncio, json, os, uuid
from collections import defaultdict, deque
from datetime import datetime, timezone
from typing import Dict, Set
import httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

OLLAMA_BASE  = os.getenv("OLLAMA_BASE_URL", "http://ollama:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_CHAT_MODEL", "qwen2.5-coder:7b")
AI_NAME      = os.getenv("AI_NAME", "LARIEL")
HISTORY_LIMIT = int(os.getenv("HISTORY_LIMIT", "200"))

app = FastAPI(title="MIDE Chat")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

connections: Dict[str, Set[WebSocket]] = defaultdict(set)
ws_users: Dict[WebSocket, str] = {}
history: Dict[str, deque] = defaultdict(lambda: deque(maxlen=HISTORY_LIMIT))
presence: Dict[str, Set[str]] = defaultdict(set)

def now_iso(): return datetime.now(timezone.utc).isoformat(timespec="seconds")

def build_msg(room, sender, text, kind="chat"):
    return {"id": str(uuid.uuid4())[:8], "room": room, "sender": sender, "text": text, "kind": kind, "ts": now_iso()}

async def broadcast(room, msg):
    history[room].append(msg)
    dead = []
    payload = json.dumps(msg)
    for ws in list(connections[room]):
        try: await ws.send_text(payload)
        except: dead.append(ws)
    for ws in dead: _remove_ws(ws, room)

def _remove_ws(ws, room):
    connections[room].discard(ws)
    username = ws_users.pop(ws, None)
    if username: presence[room].discard(username)

async def broadcast_presence(room):
    await broadcast(room, build_msg(room, "SYSTEM", json.dumps(list(presence[room])), kind="presence"))

async def ai_respond(room, trigger_text, caller):
    system_prompt = f"You are {AI_NAME}, an expert AI assistant in the MIDE platform. Be concise and technical."
    payload = {"model": OLLAMA_MODEL, "stream": False,
               "messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": trigger_text}]}
    await broadcast(room, build_msg(room, AI_NAME, "...", kind="typing"))
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(f"{OLLAMA_BASE}/api/chat", json=payload)
            resp.raise_for_status()
            reply = resp.json().get("message", {}).get("content", "").strip()
    except Exception as exc:
        reply = f"[ERROR] Ollama unreachable: {exc}"
    if history[room] and list(history[room])[-1].get("kind") == "typing":
        history[room].pop()
    await broadcast(room, build_msg(room, AI_NAME, reply, kind="ai"))

@app.websocket("/ws/{room}/{username}")
async def ws_endpoint(ws: WebSocket, room: str, username: str):
    await ws.accept()
    connections[room].add(ws); ws_users[ws] = username; presence[room].add(username)
    for m in list(history[room]): await ws.send_text(json.dumps(m))
    await broadcast(room, build_msg(room, "SYSTEM", f"{username} joined", kind="join"))
    await broadcast_presence(room)
    try:
        while True:
            raw = await ws.receive_text()
            try: text = json.loads(raw).get("text", "").strip()
            except: text = raw.strip()
            if not text: continue
            await broadcast(room, build_msg(room, username, text))
            lower = text.lower()
            if lower.startswith("@ai ") or lower.startswith(f"@{AI_NAME.lower()} "):
                trigger = text.split(" ", 1)[1] if " " in text else text
                asyncio.create_task(ai_respond(room, trigger, username))
    except WebSocketDisconnect: pass
    finally:
        _remove_ws(ws, room)
        await broadcast(room, build_msg(room, "SYSTEM", f"{username} left", kind="leave"))
        await broadcast_presence(room)

@app.get("/health")
async def health(): return {"status": "ok", "model": OLLAMA_MODEL, "ai": AI_NAME}

@app.get("/rooms")
async def list_rooms():
    return {"rooms": [{"name": r, "users": list(presence[r]), "message_count": len(history[r])} for r in connections]}

@app.get("/rooms/{room}/history")
async def room_history(room: str, limit: int = 50):
    return {"room": room, "messages": list(history[room])[-limit:]}

@app.get("/rooms/{room}/users")
async def room_users(room: str): return {"room": room, "users": list(presence[room])}

@app.post("/rooms/{room}/broadcast")
async def api_broadcast(room: str, body: dict):
    sender = body.get("sender", "EXTERNAL"); text = body.get("text", ""); kind = body.get("kind", "system")
    if not text: raise HTTPException(400, "text required")
    msg = build_msg(room, sender, text, kind=kind)
    await broadcast(room, msg)
    return {"ok": True, "msg_id": msg["id"]}

@app.post("/rooms/{room}/ask-ai")
async def ask_ai(room: str, body: dict):
    text = body.get("text", ""); caller = body.get("caller", "API")
    if not text: raise HTTPException(400, "text required")
    asyncio.create_task(ai_respond(room, text, caller))
    return {"ok": True, "status": "ai_triggered"}

app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
'''

requirements_txt = '''fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
'''

dockerfile = '''FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
COPY static/ ./static/
EXPOSE 7070
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "7070"]
'''

index_html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/>
<title>MIDE CHAT // MU-TH-UR NETWORK</title>
<link rel="stylesheet" href="style.css"/>
</head>
<body>
<div id="login-overlay">
  <div class="login-box">
    <div class="login-title">MU-TH-UR COMMS NETWORK</div>
    <div class="login-sub">MIDE MULTI-USER RELAY — AUTHENTICATED ACCESS ONLY</div>
    <div class="login-form">
      <label>CALLSIGN</label>
      <input id="login-user" type="text" placeholder="e.g. ADMIN" autocomplete="off" maxlength="24"/>
      <label>ROOM</label>
      <input id="login-room" type="text" value="OPS-CENTRAL" autocomplete="off" maxlength="32"/>
      <button id="login-btn">CONNECT</button>
    </div>
    <div class="login-hint">Use <code>@ai</code> to invoke LARIEL in any message.</div>
  </div>
</div>
<div id="app" class="hidden">
  <header class="topbar">
    <span class="topbar-logo">MU-TH-UR // MIDE COMMS</span>
    <span class="topbar-room">ROOM: <span id="room-label">—</span></span>
    <span class="topbar-user">YOU: <span id="user-label">—</span></span>
    <span class="topbar-status" id="conn-status">&#9675; OFFLINE</span>
  </header>
  <div class="layout">
    <aside class="sidebar">
      <div class="sidebar-section"><div class="sidebar-heading">ACTIVE ROOMS</div><ul id="room-list" class="sidebar-list"></ul></div>
      <div class="sidebar-section"><div class="sidebar-heading">USERS ONLINE</div><ul id="user-list" class="sidebar-list"></ul></div>
      <div class="sidebar-section"><div class="sidebar-heading">JOIN ROOM</div>
        <div class="join-form"><input id="join-room-input" type="text" placeholder="room-name" maxlength="32"/><button id="join-room-btn">JOIN</button></div>
      </div>
    </aside>
    <main class="chat-pane">
      <div id="messages" class="messages"></div>
      <div class="input-bar">
        <span class="input-prefix" id="input-prefix">OPS-CENTRAL &gt;</span>
        <input id="msg-input" type="text" placeholder="type message or @ai &lt;question&gt;" autocomplete="off"/>
        <button id="send-btn">TX</button>
      </div>
    </main>
  </div>
</div>
<script src="chat.js"></script>
</body>
</html>
'''

style_css = ''':root{--bg:#080c0f;--panel:#0d1318;--border:#1a2a35;--accent:#00c8ff;--accent2:#ffb300;--ai-color:#00e5b0;--sys-color:#556677;--text:#c8d8e0;--text-dim:#4a6070;--join-color:#4caf50;--leave-color:#f44336;--font:"Courier New",monospace;--radius:3px}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:var(--font);font-size:13px;height:100dvh;overflow:hidden}
.hidden{display:none!important}
#login-overlay{position:fixed;inset:0;background:var(--bg);display:flex;align-items:center;justify-content:center;z-index:100}
.login-box{border:1px solid var(--accent);padding:40px 48px;width:min(480px,90vw);background:var(--panel);box-shadow:0 0 40px rgba(0,200,255,.12)}
.login-title{font-size:18px;letter-spacing:.2em;color:var(--accent);margin-bottom:4px}
.login-sub{font-size:10px;color:var(--text-dim);letter-spacing:.12em;margin-bottom:28px}
.login-form{display:flex;flex-direction:column;gap:8px}
.login-form label{font-size:10px;color:var(--text-dim);letter-spacing:.1em}
.login-form input{background:var(--bg);border:1px solid var(--border);color:var(--text);padding:8px 10px;font-family:var(--font);font-size:13px;outline:none;margin-bottom:8px}
.login-form input:focus{border-color:var(--accent)}
.login-form button{margin-top:8px;padding:10px;background:transparent;border:1px solid var(--accent);color:var(--accent);font-family:var(--font);font-size:13px;letter-spacing:.12em;cursor:pointer;text-transform:uppercase;transition:background .15s,color .15s}
.login-form button:hover{background:var(--accent);color:var(--bg)}
.login-hint{margin-top:16px;font-size:10px;color:var(--text-dim)}
.login-hint code{color:var(--accent2)}
.topbar{display:flex;align-items:center;gap:24px;padding:8px 16px;background:var(--panel);border-bottom:1px solid var(--border);font-size:11px;letter-spacing:.1em}
.topbar-logo{color:var(--accent);font-size:13px;letter-spacing:.2em;flex:1}
.topbar-room{color:var(--accent2)}
.topbar-user{color:var(--text-dim)}
.topbar-status.online{color:var(--join-color)}
.topbar-status.offline{color:var(--leave-color)}
.layout{display:flex;height:calc(100dvh - 38px)}
.sidebar{width:200px;min-width:160px;background:var(--panel);border-right:1px solid var(--border);display:flex;flex-direction:column;overflow-y:auto;padding-bottom:8px}
.sidebar-section{padding:12px 10px 0}
.sidebar-heading{font-size:9px;letter-spacing:.15em;color:var(--text-dim);text-transform:uppercase;border-bottom:1px solid var(--border);padding-bottom:4px;margin-bottom:6px}
.sidebar-list{list-style:none;display:flex;flex-direction:column;gap:2px}
.sidebar-list li{padding:4px 6px;font-size:11px;color:var(--text-dim);cursor:pointer;border-radius:var(--radius);transition:background .1s}
.sidebar-list li:hover{background:var(--border);color:var(--text)}
.sidebar-list li.active{color:var(--accent);background:rgba(0,200,255,.06)}
.sidebar-list li.ai-user{color:var(--ai-color)}
.join-form{display:flex;gap:4px;margin-top:6px}
.join-form input{flex:1;background:var(--bg);border:1px solid var(--border);color:var(--text);padding:5px 7px;font-family:var(--font);font-size:11px;outline:none}
.join-form input:focus{border-color:var(--accent)}
.join-form button{background:transparent;border:1px solid var(--accent);color:var(--accent);padding:5px 8px;font-family:var(--font);font-size:10px;cursor:pointer;text-transform:uppercase;transition:background .15s,color .15s}
.join-form button:hover{background:var(--accent);color:var(--bg)}
.chat-pane{flex:1;display:flex;flex-direction:column;overflow:hidden}
.messages{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:6px;scrollbar-width:thin;scrollbar-color:var(--border) transparent}
.msg{display:flex;gap:8px;line-height:1.5}
.msg .ts{color:var(--text-dim);font-size:10px;min-width:80px;padding-top:2px}
.msg .sender{min-width:96px;font-size:11px;letter-spacing:.06em;text-align:right;padding-top:2px}
.msg .body{flex:1;white-space:pre-wrap;word-break:break-word}
.msg.chat .sender{color:var(--accent2)}
.msg.ai .sender{color:var(--ai-color)}
.msg.system .sender,.msg.system .body{color:var(--sys-color);font-style:italic}
.msg.join .sender,.msg.join .body{color:var(--join-color)}
.msg.leave .sender,.msg.leave .body{color:var(--leave-color)}
.msg.typing .body{color:var(--text-dim);font-style:italic;animation:blink 1s step-end infinite}
.msg.me .sender{color:var(--accent)}
.msg.ai .body code,.msg.ai .body pre{background:rgba(0,200,255,.06);padding:2px 5px;border-radius:2px}
@keyframes blink{50%{opacity:.3}}
.input-bar{display:flex;align-items:center;gap:8px;padding:10px 16px;border-top:1px solid var(--border);background:var(--panel)}
.input-prefix{color:var(--accent);font-size:12px;white-space:nowrap}
.input-bar input{flex:1;background:var(--bg);border:1px solid var(--border);color:var(--text);padding:8px 10px;font-family:var(--font);font-size:13px;outline:none}
.input-bar input:focus{border-color:var(--accent)}
.input-bar button{background:transparent;border:1px solid var(--accent);color:var(--accent);padding:8px 16px;font-family:var(--font);font-size:12px;letter-spacing:.12em;cursor:pointer;text-transform:uppercase;transition:background .15s,color .15s}
.input-bar button:hover{background:var(--accent);color:var(--bg)}
::-webkit-scrollbar{width:5px}::-webkit-scrollbar-thumb{background:var(--border)}
'''

chat_js = r'''"use strict";
let ws=null,myUsername="",myRoom="",typingMsgId=null;
const $=(id)=>document.getElementById(id);
const SERVER_BASE=(()=>{const l=window.location;return `${l.protocol}//${l.host}`;})();
const WS_BASE=SERVER_BASE.replace(/^https?/,SERVER_BASE.startsWith("https")?"wss":"ws");
$("login-btn").addEventListener("click",doLogin);
$("login-room").addEventListener("keydown",(e)=>e.key==="Enter"&&doLogin());
$("login-user").addEventListener("keydown",(e)=>e.key==="Enter"&&doLogin());
function doLogin(){const user=$("login-user").value.trim().toUpperCase().replace(/\s+/g,"_")||"ANON";const room=$("login-room").value.trim().toUpperCase().replace(/\s+/g,"-")||"OPS-CENTRAL";connect(room,user)}
function connect(room,username){myRoom=room;myUsername=username;$("room-label").textContent=room;$("user-label").textContent=username;$("input-prefix").textContent=`${room} >`;const url=`${WS_BASE}/ws/${encodeURIComponent(room)}/${encodeURIComponent(username)}`;ws=new WebSocket(url);ws.onopen=()=>{setStatus(true);$("login-overlay").classList.add("hidden");$("app").classList.remove("hidden");refreshRooms()};ws.onmessage=(evt)=>{try{handleMessage(JSON.parse(evt.data))}catch(_){}};ws.onclose=()=>{setStatus(false);setTimeout(()=>connect(myRoom,myUsername),3000)};ws.onerror=()=>ws.close()}
function handleMessage(msg){if(msg.kind==="presence"){updateUserList(JSON.parse(msg.text||"[]"));return}if(msg.kind==="typing"){removeTypingIndicator();typingMsgId=msg.id;appendMessage(msg);return}if(msg.kind==="ai")removeTypingIndicator();appendMessage(msg)}
function removeTypingIndicator(){if(typingMsgId){const el=document.querySelector(`[data-id="${typingMsgId}"]`);if(el)el.remove();typingMsgId=null}}
function appendMessage(msg){const c=$("messages");const d=document.createElement("div");d.className=`msg ${msg.kind||"chat"}${msg.sender===myUsername?" me":""}`;d.dataset.id=msg.id;const ts=msg.ts?msg.ts.slice(11,19):"";d.innerHTML=`<span class="ts">${ts}</span><span class="sender">${esc(msg.sender)}</span><span class="body">${fmt(msg.text,msg.kind)}</span>`;c.appendChild(d);c.scrollTop=c.scrollHeight}
function fmt(text,kind){if(!text)return"";const e=esc(text);if(kind==="ai")return e.replace(/```([\s\S]*?)```/g,"<pre><code>$1</code></pre>");return e}
function esc(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;")}
$("send-btn").addEventListener("click",sendMsg);
$("msg-input").addEventListener("keydown",(e)=>{if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();sendMsg()}});
function sendMsg(){const i=$("msg-input");const t=i.value.trim();if(!t||!ws||ws.readyState!==WebSocket.OPEN)return;ws.send(JSON.stringify({text:t}));i.value=""}
function updateUserList(users){const ul=$("user-list");ul.innerHTML="";users.forEach((u)=>{const li=document.createElement("li");li.textContent=u;if(u==="LARIEL"||u.startsWith("AI_"))li.classList.add("ai-user");if(u===myUsername)li.style.color="var(--accent)";ul.appendChild(li)})}
function refreshRooms(){fetch(`${SERVER_BASE}/rooms`).then(r=>r.json()).then(data=>{const ul=$("room-list");ul.innerHTML="";(data.rooms||[]).forEach(r=>{const li=document.createElement("li");li.textContent=`${r.name} (${r.users.length})`;if(r.name===myRoom)li.classList.add("active");li.addEventListener("click",()=>switchRoom(r.name));ul.appendChild(li)})}).catch(()=>{})}
setInterval(refreshRooms,10000);
$("join-room-btn").addEventListener("click",()=>{const v=$("join-room-input").value.trim().toUpperCase().replace(/\s+/g,"-");if(v)switchRoom(v)});
$("join-room-input").addEventListener("keydown",(e)=>{if(e.key==="Enter"){const v=$("join-room-input").value.trim().toUpperCase().replace(/\s+/g,"-");if(v)switchRoom(v)}});
function switchRoom(room){if(room===myRoom)return;if(ws)ws.close();$("messages").innerHTML="";$("join-room-input").value="";connect(room,myUsername)}
function setStatus(online){const el=$("conn-status");el.textContent=online?"● ONLINE":"○ CONNECTING...";el.className=`topbar-status ${online?"online":"offline"}`}
'''

files = {
    f"{chat_dir}/server.py": server_py,
    f"{chat_dir}/requirements.txt": requirements_txt,
    f"{chat_dir}/Dockerfile": dockerfile,
    f"{static_dir}/index.html": index_html,
    f"{static_dir}/style.css": style_css,
    f"{static_dir}/chat.js": chat_js,
}

for path, content in files.items():
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  wrote {path}")

print("ALL_FILES_WRITTEN")
PYEOF

echo "[MTASK-0132] Python file write done."

# ── Add mide-chat to docker-compose.yml if not present ────────────────────────
if grep -q "mide-chat" "$COMPOSE_FILE"; then
    echo "[MTASK-0132] mide-chat already in docker-compose.yml"
else
    echo "[MTASK-0132] Adding mide-chat service to docker-compose.yml..."
    python3 - "$COMPOSE_FILE" << 'PYEOF'
import sys, re

compose_file = sys.argv[1]
with open(compose_file, "r") as f:
    content = f.read()

new_service = """
  mide-chat:
    build:
      context: ./mide-chat
      dockerfile: Dockerfile
    container_name: mide-chat
    ports:
      - "7070:7070"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - OLLAMA_CHAT_MODEL=qwen2.5-coder:7b
      - AI_NAME=LARIEL
      - HISTORY_LIMIT=200
    networks:
      - yollama_yollama-net
    restart: unless-stopped
"""

content = re.sub(r'\nvolumes:', new_service + '\nvolumes:', content, count=1)
with open(compose_file, "w") as f:
    f.write(content)

print("COMPOSE_UPDATED")
PYEOF
fi

# ── Build and start ────────────────────────────────────────────────────────────
echo "[MTASK-0132] Building mide-chat Docker image..."
cd "$REPO"
docker compose build mide-chat 2>&1 | tail -5

echo "[MTASK-0132] Starting mide-chat container..."
docker compose up -d mide-chat

echo "[MTASK-0132] Waiting 8s for startup..."
sleep 8

HEALTH=$(curl -sf --max-time 10 http://127.0.0.1:7070/health 2>&1 || echo "FAIL")
echo "[MTASK-0132] Health: $HEALTH"

if echo "$HEALTH" | grep -q '"ok"'; then
    FINAL_STATUS="MIDE_CHAT_DEPLOYED_OK"
else
    FINAL_STATUS="MIDE_CHAT_HEALTH_FAIL"
    docker logs mide-chat --tail=20 2>&1 || true
fi

TS_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$(dirname "$RESULT_FILE")"
cat > "$RESULT_FILE" << RESULT_EOF
{
  "task_id": "MTASK-0132",
  "completed_at": "$TS_END",
  "execution_status": "completed",
  "summary": "$FINAL_STATUS",
  "health_response": $(echo "$HEALTH" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
}
RESULT_EOF

echo "[MTASK-0132] done: $FINAL_STATUS"
