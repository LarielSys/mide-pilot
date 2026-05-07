/* ── MIDE Chat — client logic ── */
"use strict";

let ws = null;
let myUsername = "";
let myRoom = "";
let typingMsgId = null;

const $ = (id) => document.getElementById(id);

// ── Determine server base (same host, port 7070 or current if proxied) ────────
const SERVER_BASE = (() => {
  const loc = window.location;
  // If not on port 7070, still use same host:port (assume nginx proxy or direct)
  return `${loc.protocol}//${loc.host}`;
})();

const WS_PROTO = SERVER_BASE.startsWith("https") ? "wss" : "ws";
const WS_BASE  = SERVER_BASE.replace(/^https?/, WS_PROTO);

// ── Login ─────────────────────────────────────────────────────────────────────
$("login-btn").addEventListener("click", doLogin);
$("login-room").addEventListener("keydown", (e) => e.key === "Enter" && doLogin());
$("login-user").addEventListener("keydown", (e) => e.key === "Enter" && doLogin());

function doLogin() {
  const user = $("login-user").value.trim().toUpperCase().replace(/\s+/g, "_") || "ANON";
  const room = $("login-room").value.trim().toUpperCase().replace(/\s+/g, "-") || "OPS-CENTRAL";
  connect(room, user);
}

// ── Connect ───────────────────────────────────────────────────────────────────
function connect(room, username) {
  myRoom = room;
  myUsername = username;

  $("room-label").textContent = room;
  $("user-label").textContent = username;
  $("input-prefix").textContent = `${room} >`;

  const url = `${WS_BASE}/ws/${encodeURIComponent(room)}/${encodeURIComponent(username)}`;
  ws = new WebSocket(url);

  ws.onopen = () => {
    setStatus(true);
    $("login-overlay").classList.add("hidden");
    $("app").classList.remove("hidden");
    refreshRooms();
  };

  ws.onmessage = (evt) => {
    try {
      const msg = JSON.parse(evt.data);
      handleMessage(msg);
    } catch (_) {}
  };

  ws.onclose = () => {
    setStatus(false);
    setTimeout(() => connect(myRoom, myUsername), 3000);
  };

  ws.onerror = () => ws.close();
}

// ── Handle incoming message ───────────────────────────────────────────────────
function handleMessage(msg) {
  if (msg.kind === "presence") {
    updateUserList(JSON.parse(msg.text || "[]"));
    return;
  }
  if (msg.kind === "typing") {
    // show or replace typing indicator
    removeTypingIndicator();
    typingMsgId = msg.id;
    appendMessage(msg);
    return;
  }
  // If an AI message arrives, remove typing indicator first
  if (msg.kind === "ai") {
    removeTypingIndicator();
  }
  appendMessage(msg);
}

function removeTypingIndicator() {
  if (typingMsgId) {
    const el = document.querySelector(`[data-id="${typingMsgId}"]`);
    if (el) el.remove();
    typingMsgId = null;
  }
}

// ── Render message ────────────────────────────────────────────────────────────
function appendMessage(msg) {
  const container = $("messages");
  const div = document.createElement("div");
  const isMe = (msg.sender === myUsername);

  const kindClass = msg.kind || "chat";
  div.className = `msg ${kindClass}${isMe ? " me" : ""}`;
  div.dataset.id = msg.id;

  const tsShort = msg.ts ? msg.ts.slice(11, 19) : "";
  div.innerHTML = `
    <span class="ts">${tsShort}</span>
    <span class="sender">${escHtml(msg.sender)}</span>
    <span class="body">${formatBody(msg.text, msg.kind)}</span>
  `;
  container.appendChild(div);
  container.scrollTop = container.scrollHeight;
}

function formatBody(text, kind) {
  if (!text) return "";
  const escaped = escHtml(text);
  if (kind === "ai") {
    // simple code block formatting: ```...``` → <pre><code>
    return escaped.replace(/```([\s\S]*?)```/g, "<pre><code>$1</code></pre>");
  }
  return escaped;
}

function escHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ── Send ──────────────────────────────────────────────────────────────────────
$("send-btn").addEventListener("click", sendMsg);
$("msg-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendMsg(); }
});

function sendMsg() {
  const input = $("msg-input");
  const text = input.value.trim();
  if (!text || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ text }));
  input.value = "";
}

// ── Presence / user list ──────────────────────────────────────────────────────
function updateUserList(users) {
  const ul = $("user-list");
  ul.innerHTML = "";
  users.forEach((u) => {
    const li = document.createElement("li");
    li.textContent = u;
    if (u === "LARIEL" || u.startsWith("AI_")) li.classList.add("ai-user");
    if (u === myUsername) li.style.color = "var(--accent)";
    ul.appendChild(li);
  });
}

// ── Room list (poll every 10s) ────────────────────────────────────────────────
function refreshRooms() {
  fetch(`${SERVER_BASE}/rooms`)
    .then((r) => r.json())
    .then((data) => {
      const ul = $("room-list");
      ul.innerHTML = "";
      (data.rooms || []).forEach((r) => {
        const li = document.createElement("li");
        li.textContent = `${r.name} (${r.users.length})`;
        if (r.name === myRoom) li.classList.add("active");
        li.addEventListener("click", () => switchRoom(r.name));
        ul.appendChild(li);
      });
    })
    .catch(() => {});
}
setInterval(refreshRooms, 10_000);

// ── Room switch ───────────────────────────────────────────────────────────────
$("join-room-btn").addEventListener("click", () => {
  const val = $("join-room-input").value.trim().toUpperCase().replace(/\s+/g, "-");
  if (val) switchRoom(val);
});
$("join-room-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    const val = $("join-room-input").value.trim().toUpperCase().replace(/\s+/g, "-");
    if (val) switchRoom(val);
  }
});

function switchRoom(room) {
  if (room === myRoom) return;
  if (ws) ws.close();
  $("messages").innerHTML = "";
  $("join-room-input").value = "";
  connect(room, myUsername);
}

// ── Status indicator ──────────────────────────────────────────────────────────
function setStatus(online) {
  const el = $("conn-status");
  el.textContent = online ? "● ONLINE" : "○ CONNECTING...";
  el.className = `topbar-status ${online ? "online" : "offline"}`;
}
