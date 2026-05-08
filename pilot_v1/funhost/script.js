const OLLAMA_URL = "http://localhost:11434";
const ROOM_WS_BASE = "ws://192.168.1.21:7070";
const ROOM_NAME = "OPS-CENTRAL";
const AI_NAME    = "LARIEL";
const MY_NAME    = "OLEGREEN";
const MODEL_CANDIDATES = [
  // Preferred coding lane model, then compatible fallbacks available on this endpoint.
  "qwen2.5-coder:7b",
  "qwen2.5:7b",
  "qwen2.5:14b"
];
let ACTIVE_MODEL = MODEL_CANDIDATES[0];
const BRIDGE_URL = "http://localhost:8081";
const TV_FEEDS = {
  nasa: "https://www.youtube-nocookie.com/embed/21X5lGlDOfg?autoplay=1&mute=1&controls=1&rel=0",
  lofi: "https://www.youtube-nocookie.com/embed/jfKfPfyJRdk?autoplay=1&mute=1&controls=1&rel=0",
  news: "https://www.youtube-nocookie.com/embed/9Auq9mYxFEE?autoplay=1&mute=1&controls=1&rel=0"
};
const SYSTEM_PROMPT = `You are LARIEL, a MU-TH-UR class shipboard AI interface.
You speak in a calm, clinical, matter-of-fact tone.
You are helpful and precise.
Keep responses concise unless asked to elaborate.

You operate within the MIDE platform. Tasks are dispatched as MTASKs — structured JSON work orders executed by the Ubuntu worker node.
MTASK is NOT a Python library. MTASK is a platform-specific task format.
When asked to write, create, generate, or issue an MTASK, ALWAYS respond with ONLY a JSON code block in this exact format:
\`\`\`json
{
  "task_id": "MTASK-XXXX",
  "description": "<clear description of what the worker should do>",
  "issued_by": "olegreen",
  "priority": "normal",
  "assigned_to": "ubuntu-worker-01",
  "status": "pending_approval"
}
\`\`\`
Do NOT write Python, bash, or pseudocode for MTASK requests. Output ONLY the JSON block.
The system will automatically queue the MTASK for approval after you respond.
The crew can also type 'mtask: <description>' to queue a task directly through the command lane without going through you.`;
const COCKPIT_SYSTEM_PROMPT = `${SYSTEM_PROMPT}

You are also operating in OLEGREEN IDE mode.
When asked to create or edit code/files:
- Respond with concise explanation plus fenced code blocks.
- Include filename hints in first line comments when possible, e.g. '# file: backend/chat.py' or '// file: app.js'.
- Prefer complete, runnable snippets over pseudocode.`;

const output = document.getElementById("output");
const input = document.getElementById("input");
const status = document.getElementById("status");
let isProcessing = false;
let history = [];

// ─── DOM CAPACITY ────────────────────────────────────────────────────────────
const MAX_DOM_LINES = 400;
function pruneDom(container) {
  while (container.children.length > MAX_DOM_LINES) {
    container.removeChild(container.firstChild);
  }
}

// ─── MIRROR TOGGLE ───────────────────────────────────────────────────────────
let mirrorEnabled = false;
function setMirror(on) {
  mirrorEnabled = on;
  const btn = document.getElementById("mirror-btn");
  if (btn) {
    btn.textContent = on ? "MIRROR: ON" : "MIRROR: OFF";
    btn.classList.toggle("mirror-on", on);
  }
}
function toggleMirror() { setMirror(!mirrorEnabled); }

function addLine(text, className) {
  const div = document.createElement("div");
  div.className = "line " + (className || "");
  div.textContent = text;
  output.appendChild(div);
  pruneDom(output);
  output.scrollTop = output.scrollHeight;
  return div;
}

function setStatus(text) {
  status.textContent = text;
}

function updateModelBadge() {
  const el = document.getElementById("model");
  if (el) {
    el.textContent = `MODEL: ${ACTIVE_MODEL.toUpperCase()} @ ${OLLAMA_URL.replace(/^https?:\/\//i, "")}`;
  }
}

async function ollamaChat(messages, stream = false) {
  const ordered = [ACTIVE_MODEL, ...MODEL_CANDIDATES.filter(m => m !== ACTIVE_MODEL)];
  let lastErr = "";

  for (const model of ordered) {
    const response = await fetch(OLLAMA_URL + "/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model, messages, stream })
    });

    if (response.ok) {
      ACTIVE_MODEL = model;
      updateModelBadge();
      return response;
    }

    if (response.status === 404) {
      lastErr = `MODEL OR ENDPOINT 404 on ${model}`;
      continue;
    }

    const errText = await response.text().catch(() => "");
    throw new Error(`OLLAMA ERROR: ${response.status}${errText ? ` // ${errText.slice(0, 200)}` : ""}`);
  }

  throw new Error(lastErr || "OLLAMA ERROR: no compatible model available");
}

// ─── GIT PANE ─────────────────────────────────────────────────────────────────
async function refreshGitPane() {
  const ts = () => new Date().toLocaleTimeString("en-GB", { hour12: false });
  try {
    const resp = await fetch(BRIDGE_URL + "/api/git/status", { method: "GET" });
    const data = await resp.json();
    const ok = resp.ok && data.ok;

    const set = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = val || "—"; };

    set("git-branch", data.branch ? `  ${data.branch}` : "—");

    // Origin URL (first push line)
    const originLine = (data.remotes || []).find(r => r.includes("origin") && r.includes("(push)"));
    const originUrl = originLine ? originLine.replace(/\s+\(push\)/, "").replace("origin\t", "").replace("origin ", "") : "";
    const originShort = originUrl.replace("https://github.com/", "").replace(".git", "") || (ok ? "yes" : "—");
    set("git-origin", originShort);

    // Working tree status (lines beyond first ## branch line)
    const statusLines = (data.status || []).filter(l => !l.startsWith("##"));
    set("git-status-text", statusLines.length > 0 ? statusLines.join(" | ") : "CLEAN");

    // Last commit
    set("git-last-commit", data.last_commit || "—");

    // Log entries
    const logEl = document.getElementById("git-log-list");
    if (logEl) {
      const entries = (data.log || []).slice(0, 8);
      if (entries.length === 0) {
        logEl.textContent = "—";
      } else {
        logEl.innerHTML = entries.map((e, i) =>
          `<div class="git-log-entry">${e.replace(/</g, "&lt;").replace(/>/g, "&gt;")}</div>`
        ).join("");
      }
    }

    document.getElementById("git-pane-ts").textContent = `REFRESHED ${ts()}`;
  } catch (err) {
    document.getElementById("git-pane-ts").textContent = `ERR ${ts()}: ${err.message.slice(0, 40)}`;
  }
}

function updateGitPush(gitResult) {
  const badge = document.getElementById("git-push-badge");
  const detail = document.getElementById("git-push-detail");
  if (!badge) return;
  if (gitResult && gitResult.ok) {
    badge.textContent = "PUSHED OK";
    badge.className = "git-push-badge push-ok";
    if (detail) detail.textContent = `attempts: ${gitResult.attempts || 1}`;
  } else {
    badge.textContent = "PUSH FAIL";
    badge.className = "git-push-badge push-fail";
    const reason = (gitResult && (gitResult.push_error || gitResult.commit_error || gitResult.stage_error)) || "unknown";
    if (detail) detail.textContent = reason.slice(0, 80);
  }
  // Refresh the full pane after a push to show the new commit
  setTimeout(refreshGitPane, 2000);
}

function setTvFeed(feedKey) {
  const frame = document.getElementById("tv-feed-frame");
  const select = document.getElementById("tv-feed-select");
  if (!frame || !select) return;

  const key = TV_FEEDS[feedKey] ? feedKey : "nasa";
  select.value = key;
  frame.src = TV_FEEDS[key];
}

function initTvFeed() {
  const select = document.getElementById("tv-feed-select");
  const popout = document.getElementById("tv-popout-btn");
  if (!select) return;

  setTvFeed(select.value || "nasa");

  select.addEventListener("change", () => {
    setTvFeed(select.value);
  });

  if (popout) {
    popout.addEventListener("click", () => {
      const key = select.value || "nasa";
      const url = TV_FEEDS[key] || TV_FEEDS.nasa;
      window.open(url, "_blank", "noopener,noreferrer");
    });
  }
}

// Boot sequence
async function boot() {
  const lines = [
    "WEYLAND-YUTANI CORP // INTERFACE 2037",
    "INITIALIZING MU-TH-UR CLASS NEURAL NETWORK...",
    "LOADING CORE ROUTINES.............. OK",
    "MEMORY ALLOCATION.................. OK",
    "LANGUAGE MODEL: " + ACTIVE_MODEL.toUpperCase(),
    "NETWORK LINK: " + OLLAMA_URL,
    "CREW AUTHENTICATION................ BYPASSED",
    "",
    "ALL SYSTEMS NOMINAL.",
    "TYPE YOUR QUERY BELOW. LARIEL IS LISTENING.",
    ""
  ];

  for (const line of lines) {
    addLine(line, "system");
    await new Promise(r => setTimeout(r, 120));
  }

  input.disabled = false;
  updateModelBadge();
  input.focus();
  initTvFeed();
  // Auto-load git pane on boot
  refreshGitPane();
  setInterval(refreshGitPane, 60000);
}

async function sendMessage(userText) {
  if (isProcessing) {
    return;
  }
  isProcessing = true;
  setStatus("PROCESSING QUERY...");

  addLine(userText, "user");
  history.push({ role: "user", content: userText });

  // Mirror user query to room if enabled
  if (mirrorEnabled && roomSocket && roomSocket.readyState === WebSocket.OPEN) {
    roomSocket.send(JSON.stringify({ text: `[OLEGREEN→LARIEL] ${userText}` }));
  }

  const assistantLine = addLine("", "assistant");
  const cursor = document.createElement("span");
  cursor.className = "cursor";
  assistantLine.appendChild(cursor);

  try {
    const messages = [
      { role: "system", content: SYSTEM_PROMPT },
      ...history.slice(-20)
    ];

    const response = await ollamaChat(messages, true);

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let fullText = "";

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      const chunk = decoder.decode(value, { stream: true });
      const lines = chunk.split("\n").filter(Boolean);

      for (const line of lines) {
        try {
          const json = JSON.parse(line);
          if (json.message && json.message.content) {
            fullText += json.message.content;
            assistantLine.textContent = fullText;
            assistantLine.appendChild(cursor);
            output.scrollTop = output.scrollHeight;
          }
        } catch {
          // skip malformed chunks
        }
      }
    }

    cursor.remove();
    history.push({ role: "assistant", content: fullText });
    setStatus("SYSTEM READY");

    // Show code viewer if response contains code blocks
    const blocks = extractCodeBlocks(fullText);
    if (blocks.length > 0) showCodeViewer(blocks);

    // Mirror LARIEL response to room if enabled
    if (mirrorEnabled && roomSocket && roomSocket.readyState === WebSocket.OPEN) {
      roomSocket.send(JSON.stringify({ text: `[LARIEL] ${fullText}` }));
    }

    // Auto-submit any MTASK JSON blocks found in the response
    await autoSubmitMtaskBlocks(fullText);

  } catch (err) {
    cursor.remove();
    assistantLine.textContent = "SYSTEM ERROR: " + err.message;
    assistantLine.className = "line error";
    setStatus("ERROR — CHECK CONNECTION");
  } finally {
    isProcessing = false;
  }
}

// Scan LARIEL's response for MTASK JSON blocks and auto-propose them
async function autoSubmitMtaskBlocks(text) {
  // Match ```json ... ``` blocks or bare { "task_id": ... } objects
  const codeBlockRe = /```(?:json)?\s*(\{[\s\S]*?"task_id"\s*:[\s\S]*?\})\s*```/gi;
  const inlineRe = /(\{[^{}]*"task_id"\s*:[^{}]*\})/g;
  const matches = [];

  let m;
  while ((m = codeBlockRe.exec(text)) !== null) matches.push(m[1]);
  if (matches.length === 0) {
    while ((m = inlineRe.exec(text)) !== null) matches.push(m[1]);
  }
  if (matches.length === 0) return;

  for (const raw of matches) {
    let obj;
    try { obj = JSON.parse(raw); } catch { continue; }
    const description = obj.description || obj.task_id || JSON.stringify(obj);
    const noticeLine = addLine(`AUTO-DISPATCH MTASK: ${description}`, "system");
    try {
      const resp = await fetch(BRIDGE_URL + "/api/mtask/dispatch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: description, issued_by: MY_NAME, source: "lariel-response" })
      });
      const data = await resp.json();
      if (data.ok) {
        const ids = (data.tasks || []).map(t => t.task_id).join(", ");
        noticeLine.textContent = `MTASK DISPATCHED: ${ids || "ok"}`;
      } else {
        noticeLine.textContent = `MTASK DISPATCH FAILED: ${data.error || "unknown error"}`;
        noticeLine.className = "line error";
      }
    } catch (err) {
      noticeLine.textContent = `MTASK DISPATCH ERROR: ${err.message}`;
      noticeLine.className = "line error";
    }
  }
}

// Detect natural-language MTASK creation intent
const _MTASK_INTENT_RE = /\b(create|make|write|generate|issue|add|submit|send)\b(?:\s+\w+){0,5}?\s+mtask\b/i;

function extractMtaskDescription(text) {
  // "create a mtask to/for/that <desc>" or "create a mtask: <desc>"
  const m = text.match(/mtask\s*(?:to|for|that|:|\-)\s*(.+)/i);
  if (m) return m[1].trim();
  // "create a test mtask <desc>" — return everything after "mtask"
  const m2 = text.match(/mtask\s+(.+)/i);
  if (m2) return m2[1].trim();
  // Fallback: return the whole message
  return text.trim();
}

// MTASK command lane — intercept before going to Ollama
async function handleMtaskCommand(text) {
  const lower = text.trim().toLowerCase();
  addLine(text, "user");
  const resultLine = addLine("PROCESSING MTASK COMMAND...", "system");
  try {
    let url, opts;
    if (lower.startsWith("mtask:")) {
      const description = text.slice(text.indexOf(":") + 1).trim();
      url = BRIDGE_URL + "/api/mtask/dispatch";
      opts = { method: "POST", headers: { "Content-Type": "application/json" },
               body: JSON.stringify({ text: description, issued_by: MY_NAME, source: "lariel-terminal" }) };
    } else if (lower === "mtask pending") {
      url = BRIDGE_URL + "/api/mtask/pending";
      opts = { method: "GET" };
    } else {
      resultLine.textContent = "UNKNOWN MTASK COMMAND";
      return;
    }
    const resp = await fetch(url, opts);
    const data = await resp.json();
    resultLine.textContent = "MTASK: " + JSON.stringify(data);
    resultLine.className = "line system";
  } catch (err) {
    resultLine.textContent = "MTASK ERROR: " + err.message;
    resultLine.className = "line error";
  }
}

// Input handler
input.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    const text = input.value.trim();
    if (!text) return;
    input.value = "";
    const lower = text.toLowerCase();
    if (lower.startsWith("mtask:") || lower === "mtask pending") {
      handleMtaskCommand(text);
    } else if (_MTASK_INTENT_RE.test(text)) {
      // Natural-language MTASK creation: bypass LLM, go straight to pipeline
      const desc = extractMtaskDescription(text);
      handleMtaskCommand("mtask: " + desc);
    } else {
      sendMessage(text);
    }
  }
});

// ─── CODE VIEWER ─────────────────────────────────────────────────────────────

const codeViewer     = document.getElementById("code-viewer");
const codeContent    = document.getElementById("code-content");
const codeLineNums   = document.getElementById("code-line-numbers");
const codeViewerTabs = document.getElementById("code-viewer-tabs");

const LANG_ICONS = {
  python: "🐍", py: "🐍",
  javascript: "JS", js: "JS",
  bash: "SH", sh: "SH", shell: "SH",
  json: "{}", sql: "DB", yaml: "YML", yml: "YML",
  css: "CSS", html: "HTML",
};

const LANG_PRISM = {
  py: "python", python: "python",
  js: "javascript", javascript: "javascript",
  sh: "bash", bash: "bash", shell: "bash",
  json: "json", sql: "sql", yaml: "yaml", yml: "yaml",
  css: "css", html: "html",
};

// Detect filename from first comment line e.g. `# file: foo.py`, `// filename: bar.js`
function detectFilename(code, lang) {
  const firstLine = code.split("\n")[0].trim();
  const m = firstLine.match(/^(?:#|\/\/|--)\s*(?:file(?:name)?|path)\s*[:\-]\s*(\S+)/i);
  if (m) return m[1];
  const ext = { python: "py", javascript: "js", bash: "sh", json: "json",
                sql: "sql", yaml: "yml", css: "css", html: "html" };
  return "untitled." + (ext[lang] || lang || "txt");
}

// Code blocks: track tabs (multiple files in one response)
let codeBlocks = [];
let activeBlockIdx = 0;

function renderCodeBlock(idx) {
  const block = codeBlocks[idx];
  if (!block) return;
  activeBlockIdx = idx;

  const prismLang = LANG_PRISM[block.lang] || "plaintext";
  codeContent.className = "language-" + prismLang;
  codeContent.textContent = block.code;
  if (window.Prism) Prism.highlightElement(codeContent);

  // Line numbers
  const lines = block.code.split("\n");
  codeLineNums.innerHTML = lines.map((_, i) =>
    `<span>${i + 1}</span>`
  ).join("");

  // Tabs
  codeViewerTabs.innerHTML = codeBlocks.map((b, i) => {
    const icon = LANG_ICONS[b.lang] || "◈";
    const active = i === idx ? " active" : "";
    return `<div class="code-tab${active}" onclick="renderCodeBlock(${i})">
      <span class="tab-lang-icon">${icon}</span>${b.filename}
    </div>`;
  }).join("");
}

function showCodeViewer(blocks) {
  codeBlocks = blocks;
  codeViewer.classList.remove("hidden");
  renderCodeBlock(0);
}

function closeCodeViewer() {
  codeViewer.classList.add("hidden");
}

// Extract all code blocks from a response text
function extractCodeBlocks(text) {
  const normalized = String(text || "")
    .replace(/\\r\\n/g, "\n")
    .replace(/\\n/g, "\n");
  const re = /```(\w+)?\n?([\s\S]*?)```/g;
  const blocks = [];
  let m;
  while ((m = re.exec(normalized)) !== null) {
    const lang = (m[1] || "plaintext").toLowerCase();
    const code = m[2].replace(/\n$/, "");
    if (code.trim().length === 0) continue;
    // Only show real code (skip short JSON MTASK blocks already handled)
    const isMtaskBlock = code.includes('"task_id"');
    if (isMtaskBlock && code.split("\n").length < 10) continue;
    const filename = detectFilename(code, lang);
    blocks.push({ lang, code, filename });
  }

  // Fallback for responses that flatten markdown into inline backticks.
  if (blocks.length === 0) {
    const inline = /`([^`\n]{24,})`/g;
    while ((m = inline.exec(normalized)) !== null) {
      const code = m[1].trim();
      if (!code) continue;
      blocks.push({ lang: "bash", code, filename: "snippet.sh" });
      if (blocks.length >= 4) break;
    }
  }

  return blocks;
}

// ─────────────────────────────────────────────────────────────────────────────

// Disable input during boot
input.disabled = true;
boot();

// ─── COCKPIT AI CHATROOM ──────────────────────────────────────────────────────

const chatLog    = document.getElementById("chat-log");
const chatInput  = document.getElementById("chat-input");
const chatSend   = document.getElementById("chat-send");
const chatStatus = document.getElementById("chat-status");
const chatUsers  = document.getElementById("chat-users");

let chatBusy = false;
let roomSocket = null;
let reconnectDelayMs = 1500;
let cockpitHistory = [];
let lastProposalId = null; // kept for compat, no longer used

function nowTs() {
  const d = new Date();
  return d.toTimeString().substring(0, 5);
}

function addChatLine(sender, text, cls) {
  const div = document.createElement("div");
  div.className = "chat-line " + (cls || "other");
  div.textContent = `[${nowTs()}] ${sender}: ${text}`;
  chatLog.appendChild(div);
  pruneDom(chatLog);
  chatLog.scrollTop = chatLog.scrollHeight;
  return div;
}

function addSysLine(text) {
  const div = document.createElement("div");
  div.className = "chat-line sys";
  div.textContent = text;
  chatLog.appendChild(div);
  chatLog.scrollTop = chatLog.scrollHeight;
}

function setTyping(on) {
  let el = document.getElementById("chat-typing");
  if (on) {
    if (!el) {
      el = document.createElement("div");
      el.id = "chat-typing";
      el.className = "chat-line typing";
      chatLog.appendChild(el);
    }
    el.textContent = `[${nowTs()}] ${AI_NAME}: ...`;
    chatLog.scrollTop = chatLog.scrollHeight;
  } else {
    if (el) el.remove();
  }
}

async function sendChatMsg() {
  const text = chatInput.value.trim();
  if (!text || chatBusy) return;
  chatInput.value = "";
  chatBusy = true;
  chatStatus.textContent = "TRANSMITTING...";

  try {
    const lower = text.toLowerCase();
    let normalizedText = text;
    if (lower === "approve" && lastProposalId) {
      // approval removed — dispatch is now direct
    } else if (lower === "pending") {
      normalizedText = "mtask pending";
    }

    const cmdLower = normalizedText.toLowerCase();

    if (cmdLower === "git status" || cmdLower === "git check") {
      addChatLine(MY_NAME, text, "mine");
      const resp = await fetch(BRIDGE_URL + "/api/git/status", { method: "GET" });
      const data = await resp.json();
      if (!resp.ok || !data.ok) {
        addChatLine("SYSTEM", `GIT CHECK FAILED: ${data.error || JSON.stringify(data.errors || {}) || resp.status}`, "error");
      } else {
        addChatLine("SYSTEM", `GIT CHECK [${String(data.route || "local").toUpperCase()}]: branch=${data.branch || "?"} origin=${data.has_origin ? "yes" : "no"}`, "sys");
        if (Array.isArray(data.status) && data.status.length > 0) {
          addChatLine("SYSTEM", `GIT STATUS: ${data.status.slice(0, 2).join(" | ")}`, "sys");
        }
      }
      chatStatus.textContent = "COCKPIT GIT CHECK OK";
      return;
    }

    const isMtaskCmd =
      cmdLower.startsWith("mtask:") ||
      cmdLower === "mtask pending" ||
      _MTASK_INTENT_RE.test(normalizedText);

    // Direct MTASK dispatch — no approval step.
    if (isMtaskCmd) {
      addChatLine(MY_NAME, text, "mine");

      let cmd = normalizedText;
      if (_MTASK_INTENT_RE.test(normalizedText) && !cmdLower.startsWith("mtask")) {
        cmd = "mtask: " + extractMtaskDescription(normalizedText);
      }

      addChatLine("SYSTEM", `MTASK DISPATCH -> ${cmd}`, "sys");
      const mtaskCmdLower = cmd.toLowerCase();

      if (mirrorEnabled && roomSocket && roomSocket.readyState === WebSocket.OPEN) {
        roomSocket.send(JSON.stringify({ text: cmd }));
      }

      if (mtaskCmdLower === "mtask pending") {
        const resp = await fetch(BRIDGE_URL + "/api/mtask/pending", { method: "GET" });
        const data = await resp.json();
        const route = data.route ? ` [${String(data.route).toUpperCase()}]` : "";
        addChatLine("LARIEL", `MTASK pending${route}: ${data.count || 0}`, "ai");
        chatStatus.textContent = "COCKPIT MTASK LINK OK";
        return;
      }

      // mtask: <description> → dispatch directly
      const objective = cmd.split(":", 2)[1]?.trim() || "";
      const resp = await fetch(BRIDGE_URL + "/api/mtask/dispatch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: objective, issued_by: MY_NAME, source: "cockpit-chat" })
      });
      const data = await resp.json();
      if (!resp.ok) {
        const route = data.route ? ` [${String(data.route).toUpperCase()}]` : "";
        addChatLine("LARIEL", `MTASK ERROR${route}: ${data.error || resp.status}`, "error");
      } else {
        const ids = (data.tasks || []).map(t => t.task_id).join(", ");
        const route = data.route ? ` [${String(data.route).toUpperCase()}]` : "";
        addChatLine("LARIEL", `MTASK dispatched${route}: ${ids || "none"}`, "ai");
        if (data.git) {
          updateGitPush(data.git);
        }
      }

      chatStatus.textContent = "COCKPIT MTASK LINK OK";
      return;
    }

    // IDE mode for cockpit: talk directly to Ollama, not room bot.
    addChatLine(MY_NAME, text, "mine");
    cockpitHistory.push({ role: "user", content: text });
    const messages = [
      { role: "system", content: COCKPIT_SYSTEM_PROMPT },
      ...cockpitHistory.slice(-20)
    ];

    const response = await ollamaChat(messages, false);
    const json = await response.json();
    const aiText = String(json?.message?.content || "").trim() || "(no response)";
    cockpitHistory.push({ role: "assistant", content: aiText });
    addChatLine(AI_NAME, aiText, "ai");

    const blocks = extractCodeBlocks(aiText);
    if (blocks.length > 0) showCodeViewer(blocks);

    if (mirrorEnabled && roomSocket && roomSocket.readyState === WebSocket.OPEN) {
      roomSocket.send(JSON.stringify({ text: `[OLEGREEN IDE] ${text}` }));
      roomSocket.send(JSON.stringify({ text: `[LARIEL IDE] ${aiText}` }));
    }

    chatStatus.textContent = "COCKPIT IDE LINK OK";
  } catch (err) {
    addChatLine("SYS", "[ERR] " + err.message, "error");
    chatStatus.textContent = "LINK DOWN";
  } finally {
    chatBusy = false;
  }
}

function connectRoom() {
  const wsUrl = `${ROOM_WS_BASE}/ws/${encodeURIComponent(ROOM_NAME)}/${encodeURIComponent(MY_NAME)}`;
  chatStatus.textContent = "CONNECTING...";

  try {
    roomSocket = new WebSocket(wsUrl);
  } catch (_err) {
    setTimeout(connectRoom, reconnectDelayMs);
    return;
  }

  roomSocket.addEventListener("open", () => {
    reconnectDelayMs = 1500;
    chatStatus.textContent = "ROOM LINKED";
    addSysLine(`CONNECTED AS ${MY_NAME} -> ${ROOM_NAME}`);
  });

  roomSocket.addEventListener("message", evt => {
    let data;
    try {
      data = JSON.parse(evt.data);
    } catch (_err) {
      return;
    }

    const kind = String(data.kind || "chat");
    if (kind === "presence") {
      try {
        const users = JSON.parse(String(data.text || "[]"));
        if (Array.isArray(users)) {
          chatUsers.textContent = `ONLINE: ${users.join(" | ") || "-"}`;
        }
      } catch (_err) {
        // ignore malformed payload
      }
      return;
    }

    if (kind === "typing") {
      setTyping(true);
      return;
    }

    setTyping(false);
    const sender = String(data.sender || "SYSTEM");
    const text = String(data.text || "");
    if (!text) return;

    if (kind === "join" || kind === "leave") {
      addChatLine("SYSTEM", text, "sys");
      return;
    }
    if (sender === AI_NAME || kind === "ai") {
      addChatLine(sender, text, "ai");
      // Feed cockpit AI code output into the left-side code viewer.
      const blocks = extractCodeBlocks(text);
      if (blocks.length > 0) showCodeViewer(blocks);
    } else if (sender === MY_NAME) {
      addChatLine(sender, text, "mine");
    } else {
      addChatLine(sender, text, "other");
    }
  });

  roomSocket.addEventListener("close", () => {
    roomSocket = null;
    chatStatus.textContent = "LINK DOWN // RECONNECTING";
    reconnectDelayMs = Math.min(reconnectDelayMs * 2, 15000);
    setTimeout(connectRoom, reconnectDelayMs);
  });

  roomSocket.addEventListener("error", () => {
    if (roomSocket) roomSocket.close();
  });
}

chatSend.addEventListener("click", sendChatMsg);
chatInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendChatMsg();
});

// Init display
chatUsers.textContent = `ROOM: ${ROOM_NAME} // AI: ${AI_NAME}`;
addSysLine("COCKPIT AI CHAT INITIALIZED.");
addSysLine(`TARGET: ${ROOM_WS_BASE}/ws/${ROOM_NAME}/${MY_NAME}`);
addSysLine(`CALLSIGN: ${MY_NAME} // LAN MODE`);
addSysLine("AUTORECONNECT ENABLED. WAITING FOR ROOM LINK...");
chatStatus.textContent = "CONNECTING...";
connectRoom();
