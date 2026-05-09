(async function main() {
  const cfg = window.CUSTOMIDE_CONFIG || { backendBaseUrl: "http://127.0.0.1:5555" };
  const enableHardReset = new URLSearchParams(window.location.search).get("hard_reset") === "1";
  const refreshIntervalMs = Number(cfg.refreshIntervalMs || 2500);
  const llmRefreshEvery = 1;
  let tick = 0;
  let activeBackendBaseUrl = "";
  let lastErrorText = "";
  let lastKnownLlm = { status: "pending", source_key: "n/a" };

  // --- Event buffer state ---
  let eventBuffer = [];   // { line, color, ts_iso }
  let lineIndex = 0;      // global per-line counter drives green/yellow alternation
  const seenLines = new Set();
  let userPinned = false; // true when user has scrolled up away from bottom
  let currentDay = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  const resetNonceKey = "cockpit_hard_reset_last_nonce";
  const chatHistoryKey = "mide_chat_history_v1";
  let hardResetInFlight = false;
  const autopilotStaleResetMs = Number(cfg.autopilotStaleResetMs || 120000);
  let lastAutopilotFingerprint = "";
  let lastAutopilotChangeMs = Date.now();

  const statusEl = document.getElementById("backendStatus");
  const llmBadgeEl = document.getElementById("llmHealthBadge");
  const syncBadgeEl = document.getElementById("syncHealthBadge");
  const lastRefreshEl = document.getElementById("lastRefresh");
  const autopilotLiveEl = document.getElementById("autopilotLive");
  const taskHistoryCountEl = document.getElementById("taskHistoryCount");
  const chatPromptInputEl = document.getElementById("chatPromptInput");
  const chatPromptSendEl = document.getElementById("chatPromptSend");
  const chatPromptStatusEl = document.getElementById("chatPromptStatus");
  const workerLogPanelEl = document.getElementById("workerLogPanel");
  const programMetaEl = document.getElementById("programMeta");
  const routeListEl = document.getElementById("routeList");
  const flowSectionsEl = document.getElementById("flowSections");
  const flowEntryCardEl = document.getElementById("flowEntryCard");
  const flowEntryMetaEl = document.getElementById("flowEntryMeta");
  const flowSummaryStatsEl = document.getElementById("flowSummaryStats");
  const flowSummaryPathEl = document.getElementById("flowSummaryPath");
  const runtimePanelEl = document.getElementById("runtimePanel");
  const editorBreadcrumbEl = document.getElementById("editorBreadcrumb");
  const editorGutterEl = document.getElementById("editorGutter");
  const codeEditorEl = document.getElementById("codeEditor");
  const symbolListEl = document.getElementById("symbolList");
  const editorTabsEl = document.getElementById("editorTabs");

  const ideState = {
    files: [],
    filesByPath: {},
    activeFilePath: "",
    openTabs: [],
    activeSymbol: "",
    generatedContentByPath: {},
    context: {
      worker: {},
      gitStatus: {},
      tokens: {},
      runtime: {},
      sync: {},
      cadence: {}
    }
  };

  const chatState = {
    messages: [],
    pending: false,
  };

  function chatMessageKey(message) {
    return [
      String(message && message.role || ""),
      String(message && message.text || ""),
      String(message && message.model || ""),
      String(message && message.source || ""),
      String(message && message.ts || "")
    ].join("|");
  }

  function mergeChatMessages(incomingRows) {
    if (!Array.isArray(incomingRows) || incomingRows.length === 0) return;

    const existing = new Set(chatState.messages.map(chatMessageKey));
    for (const msg of incomingRows) {
      const row = {
        role: String((msg && msg.role) || "assistant"),
        text: String((msg && msg.text) || ""),
        model: String((msg && msg.model) || "ollama"),
        source: String((msg && msg.source) || "local-ide"),
        ts: Number((msg && msg.ts) || Date.now()),
      };
      if (!row.text) continue;
      const key = chatMessageKey(row);
      if (existing.has(key)) continue;
      existing.add(key);
      chatState.messages.push(row);
    }

    chatState.messages.sort((a, b) => Number(a.ts || 0) - Number(b.ts || 0));
    if (chatState.messages.length > 300) {
      chatState.messages = chatState.messages.slice(-300);
    }
  }

  function saveChatHistory() {
    try {
      localStorage.setItem(chatHistoryKey, JSON.stringify(chatState.messages.slice(-300)));
    } catch (_err) {
      // Ignore storage errors.
    }
  }

  function loadChatHistory() {
    try {
      const raw = localStorage.getItem(chatHistoryKey);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return;
      chatState.messages = parsed
        .filter(msg => msg && typeof msg.text === "string" && typeof msg.role === "string")
        .slice(-300)
        .map(msg => ({
          role: msg.role,
          text: String(msg.text || ""),
          model: String(msg.model || "ollama"),
          source: String(msg.source || "local-ide"),
          ts: Number(msg.ts || Date.now()),
        }));
    } catch (_err) {
      // Ignore malformed history.
    }
  }

  function appendChatMessage(role, text, model, source) {
    chatState.messages.push({
      role: String(role || "assistant"),
      text: String(text || ""),
      model: String(model || "ollama"),
      source: String(source || "local-ide"),
      ts: Date.now(),
    });
    if (chatState.messages.length > 300) {
      chatState.messages = chatState.messages.slice(-300);
    }
    saveChatHistory();
  }

  async function loadSharedChatHistory() {
    try {
      const data = await fetchJson("/api/llm/history?limit=300");
      const rows = Array.isArray(data && data.messages) ? data.messages : [];
      mergeChatMessages(rows);
      saveChatHistory();
      renderResponseStream(ideState.context.worker);
    } catch (_err) {
      // Backend may be offline; keep local chat history.
    }
  }

  // Scroll-pin: stop auto-scroll when user scrolls up; resume when they reach bottom
  workerLogPanelEl.addEventListener("scroll", () => {
    const el = workerLogPanelEl;
    userPinned = el.scrollTop < el.scrollHeight - el.clientHeight - 12;
  });
  const gitPanelEl = document.getElementById("gitPanel");
  const gitRemoteUrlEl = document.getElementById("gitRemoteUrl");
  const gitConnectBtnEl = document.getElementById("gitConnectBtn");
  const gitFetchBtnEl = document.getElementById("gitFetchBtn");
  const gitPullBtnEl = document.getElementById("gitPullBtn");
  const gitPushBtnEl = document.getElementById("gitPushBtn");
  const gitOpResultEl = document.getElementById("gitOpResult");
  const syncCadencePanelEl = document.getElementById("syncCadencePanel");
  const tokenPanelEl = document.getElementById("tokenPanel");
  const ollamaPanelEl = document.getElementById("ollamaPanel");

  function setGitOpResult(message, isError) {
    if (!gitOpResultEl) return;
    gitOpResultEl.textContent = message;
    gitOpResultEl.style.color = isError ? "#ff5d5d" : "";
  }

  function setChatStatus(message, isError) {
    if (!chatPromptStatusEl) return;
    chatPromptStatusEl.textContent = message;
    chatPromptStatusEl.style.color = isError ? "#ff5d5d" : "";
  }

  function extractCodeForEditor(text) {
    const raw = String(text || "").trim();
    if (!raw) return "";

    const fenced = raw.match(/```(?:[a-zA-Z0-9_+.-]+)?\r?\n([\s\S]*?)```/);
    if (fenced && fenced[1] && fenced[1].trim()) {
      return fenced[1].trim();
    }

    const likelyCode = (
      /\n/.test(raw) &&
      (/\{/.test(raw) || /\}/.test(raw) || /;\s*$/m.test(raw) || /^(\s)*(public|private|protected|class|interface|enum|def|function|import|from|const|let|var)\b/m.test(raw))
    );

    if (likelyCode) {
      return raw;
    }

    return "";
  }

  function applyAssistantCodeToEditor(text) {
    const activeFile = getActiveFile();
    if (!activeFile || !activeFile.path) return false;

    const editorContent = extractCodeForEditor(text);
    if (!editorContent) return false;

    ideState.generatedContentByPath[activeFile.path] = editorContent;
    if (ideState.filesByPath[activeFile.path]) {
      ideState.filesByPath[activeFile.path].content = editorContent;
    }

    renderConnectedIde();
    renderProgramMeta(ideState.context.worker, ideState.context.gitStatus, ideState.context.runtime);
    return true;
  }

  function buildAssistantPrompt(contextLabel, userPrompt) {
    const behavior = [
      "You are MIDE Copilot, a friendly coding assistant.",
      "Talk naturally in chat and explain your thinking in short, practical steps.",
      "Do not only execute; also describe what is happening and why.",
      "When code is requested, provide complete runnable code in a fenced code block.",
      "If you modify or suggest changes, summarize the process and expected result."
    ].join("\n");

    return [
      `[context: ${contextLabel}]`,
      behavior,
      "",
      "User request:",
      String(userPrompt || "").trim()
    ].join("\n");
  }

  function getActiveFile() {
    return ideState.filesByPath[ideState.activeFilePath] || ideState.files[0] || null;
  }

  function ensureOpenTab(path) {
    if (!path) return;
    if (!ideState.openTabs.includes(path)) {
      ideState.openTabs = [...ideState.openTabs, path].slice(-3);
    }
  }

  function setActiveFile(path, symbolName) {
    if (!ideState.filesByPath[path]) return;
    ideState.activeFilePath = path;
    ensureOpenTab(path);
    ideState.activeSymbol = symbolName || ideState.filesByPath[path].symbols[0] || "";
    renderConnectedIde();
    renderProgramMeta(ideState.context.worker, ideState.context.gitStatus, ideState.context.runtime);
  }

  function buildIdeFiles(worker, gitStatus, tokens, runtime) {
    const branch = (gitStatus && gitStatus.branch) || "main";
    const processName = (worker && worker.last_task_processed) || "renderTraceConsole";
    const trackedTasks = (tokens && tokens.summary && tokens.summary.tasks_tracked) || 0;
    const recentEvents = (worker && worker.recent_events) ? worker.recent_events.slice(-3) : [];

    return [
      {
        path: "frontend/js/app.js",
        title: "app.js",
        breadcrumb: "mide-workspace / frontend / js / app.js",
        symbols: ["buildIdeFiles", "setActiveFile", processName, "renderConnectedIde"],
        content: [
          "const ide = createIdeShell({",
          `  branch: \"${branch}\",`,
          "  layout: \"three-pane\",",
          "  theme: \"trace-console\",",
          "});",
          "",
          "const assistant = connectAssistant({",
          "  chat: \"ollama\",",
          "  code: \"ollama\",",
          `  state: \"${(worker && worker.mode) || "idle"}\",`,
          "});",
          "",
          "const context = {",
          `  activeSelection: \"${processName}\",`,
          `  trackedTasks: ${trackedTasks},`,
          `  runTarget: \"${((runtime && runtime.backend && runtime.backend.execute_routes && runtime.backend.execute_routes.local) || "/api/execute/local")}\",`,
          "};",
          "",
          "// Recent runtime context",
          ...recentEvents.map((eventLine, index) => `trace[${index}] = ${JSON.stringify(eventLine)};`)
        ].join("\n")
      },
      {
        path: "frontend/index.html",
        title: "index.html",
        breadcrumb: "mide-workspace / frontend / index.html",
        symbols: ["app-layout", "pane-left", "pane-center", "pane-right"],
        content: [
          "<main class=\"app-layout\">",
          "  <aside class=\"pane pane-left\">",
          "    <!-- explorer + git + problems -->",
          "  </aside>",
          "  <section class=\"pane pane-center\">",
          "    <!-- editor tabs + code column -->",
          "  </section>",
          "  <aside class=\"pane pane-right\">",
          "    <!-- copilot chat + terminal -->",
          "  </aside>",
          "</main>"
        ].join("\n")
      },
      {
        path: "frontend/css/style.lock-20260507.css",
        title: "style.lock-20260507.css",
        breadcrumb: "mide-workspace / frontend / css / style.lock-20260507.css",
        symbols: [":root", ".app-layout", ".editor-stage", ".response-stream"],
        content: [
          ":root {",
          "  --bg: #0a1220;",
          "  --panel: #0f1a2a;",
          "  --accent-blue: #53b7ff;",
          "  --accent-amber: #f2a93b;",
          "}",
          "",
          ".app-layout {",
          "  display: grid;",
          "  grid-template-columns: 320px 1fr 360px;",
          "}",
          "",
          ".editor-stage {",
          "  border: 1px solid var(--border-soft);",
          "  border-radius: 12px;",
          "}"
        ].join("\n")
      }
    ];
  }

  function updateIdeState(worker, gitStatus, tokens, runtime, sync, cadence) {
    const files = buildIdeFiles(worker, gitStatus, tokens, runtime);
    ideState.files = files;
    ideState.filesByPath = Object.fromEntries(files.map(file => [file.path, file]));

    for (const [path, content] of Object.entries(ideState.generatedContentByPath)) {
      if (ideState.filesByPath[path]) {
        ideState.filesByPath[path].content = String(content || "");
      }
    }

    ideState.context = { worker, gitStatus, tokens, runtime, sync, cadence };

    if (!ideState.activeFilePath || !ideState.filesByPath[ideState.activeFilePath]) {
      ideState.activeFilePath = files[0] ? files[0].path : "";
    }

    ideState.openTabs = ideState.openTabs.filter(path => ideState.filesByPath[path]);
    ensureOpenTab(ideState.activeFilePath);

    const activeFile = getActiveFile();
    if (!ideState.activeSymbol || (activeFile && !activeFile.symbols.includes(ideState.activeSymbol))) {
      ideState.activeSymbol = activeFile && activeFile.symbols[0] ? activeFile.symbols[0] : "";
    }
  }

  function renderEditorTabs() {
    if (!editorTabsEl) return;
    editorTabsEl.innerHTML = ideState.openTabs.map(path => {
      const file = ideState.filesByPath[path];
      const activeClass = path === ideState.activeFilePath ? " active" : "";
      return `<div class="editor-tab${activeClass}" data-path="${escHtml(path)}">${escHtml(file ? file.title : path)}</div>`;
    }).join("");
  }

  function renderConnectedIde() {
    renderEditorTabs();
    renderRouteList(ideState.context.worker, ideState.context.gitStatus);
    renderEditorSurface(ideState.context.worker, ideState.context.gitStatus, ideState.context.tokens, ideState.context.runtime);
    renderFlowCanvas(ideState.context.worker, ideState.context.gitStatus, ideState.context.tokens);
  }

  function wireIdeInteractions() {
    if (routeListEl) {
      routeListEl.addEventListener("click", (event) => {
        const target = event.target.closest("[data-path]");
        if (!target) return;
        setActiveFile(target.dataset.path || "");
      });
    }

    if (editorTabsEl) {
      editorTabsEl.addEventListener("click", (event) => {
        const target = event.target.closest("[data-path]");
        if (!target) return;
        setActiveFile(target.dataset.path || "");
      });
    }

    if (symbolListEl) {
      symbolListEl.addEventListener("click", (event) => {
        const target = event.target.closest("[data-symbol]");
        if (!target) return;
        ideState.activeSymbol = target.dataset.symbol || "";
        renderConnectedIde();
        renderProgramMeta(ideState.context.worker, ideState.context.gitStatus, ideState.context.runtime);
      });
    }
  }

  function renderProgramMeta(worker, gitStatus, runtime) {
    if (!programMetaEl) return;

    const activeFile = getActiveFile();
    const processName = ideState.activeSymbol || (worker && worker.last_task_processed) || "300-PROCESS-LOOP";
    const mode = (worker && worker.mode) || "trace console";
    const remoteLabel = (gitStatus && gitStatus.upstream) || ((gitStatus && gitStatus.has_origin) ? "origin configured" : "no upstream yet");
    const localExecute = ((runtime && runtime.backend && runtime.backend.execute_routes && runtime.backend.execute_routes.local) || "/api/execute/local");

    programMetaEl.innerHTML = [
      `<div class="info-line"><span class="muted">workspace:</span> MIDE</div>`,
      `<div class="info-line"><span class="muted">stack:</span> WEB / PYTHON</div>`,
      `<div class="info-line"><span class="muted">active file:</span> ${escHtml(activeFile ? activeFile.title : "main.py")}</div>`,
      `<div class="info-line"><span class="muted">selection:</span> ${escHtml(processName)}</div>`,
      `<div class="info-line"><span class="muted">assistant mode:</span> ${escHtml(mode)}</div>`,
      `<div class="info-line"><span class="muted">git remote:</span> ${escHtml(remoteLabel)}</div>`,
      `<div class="info-line"><span class="muted">run target:</span> ${escHtml(localExecute)}</div>`
    ].join("");
  }

  function renderRouteList(worker, gitStatus) {
    if (!routeListEl) return;

    const branch = (gitStatus && gitStatus.branch) || "main";
    const nodes = [
      { label: "mide-workspace/", tone: "folder", path: "" },
      { label: "  frontend/", tone: "folder", path: "" },
      ...ideState.files.map(file => ({
        label: `    ${file.path.replace("frontend/", "")}`,
        tone: file.path === ideState.activeFilePath ? "active" : "warm",
        path: file.path
      })),
      { label: `  .git/${branch}`, tone: "folder", path: "" }
    ];

    routeListEl.innerHTML = nodes.map((node) => {
      let className = "tree-item";
      if (node.tone === "folder") className += " folder";
      if (node.tone === "warm") className += " warm";
      if (node.path && node.path === ideState.activeFilePath) className += " active";
      const pathAttr = node.path ? ` data-path="${escHtml(node.path)}"` : "";
      return `<div class="${className}"${pathAttr}>${escHtml(node.label)}</div>`;
    }).join("");
  }

  function renderEditorSurface(worker, gitStatus, tokens, runtime) {
    if (!codeEditorEl || !editorGutterEl) return;

    const activeFile = getActiveFile();
    const lines = activeFile ? activeFile.content.split("\n") : ["loading editor..."];

    codeEditorEl.textContent = lines.join("\n");
    editorGutterEl.textContent = lines.map((_, index) => String(index + 1)).join("\n");

    if (editorBreadcrumbEl) {
      editorBreadcrumbEl.textContent = activeFile ? activeFile.breadcrumb : "mide-workspace / frontend / js / app.js";
    }
  }

  function renderOpenSymbols() {
    const activeFile = getActiveFile();
    if (symbolListEl) {
      const symbols = activeFile ? activeFile.symbols : [];
      symbolListEl.innerHTML = symbols.map((symbolName, index) => {
        const classes = symbolName === ideState.activeSymbol || (!ideState.activeSymbol && index === 0)
          ? "list-item active"
          : "list-item";
        return `<div class="${classes}" data-symbol="${escHtml(symbolName)}">${escHtml(symbolName)}</div>`;
      }).join("");
    }
  }

  function renderFlowCanvas(worker, gitStatus, tokens) {
    if (!flowSectionsEl) return;

    const sections = [
      {
        title: "APP SHELL",
        nodes: [
          {
            code: "S01-01",
            name: "BOOTSTRAP-SHELL",
            desc: `Prepare navigation, tabs, and editor state`
          }
        ]
      },
      {
        title: "SOURCE CONTROL",
        nodes: [
          {
            code: "S02-01",
            name: (gitStatus && gitStatus.branch) ? `BRANCH-${gitStatus.branch.toUpperCase()}` : "SYNC-ORIGIN",
            desc: `Ahead ${gitStatus && typeof gitStatus.ahead === "number" ? gitStatus.ahead : "n/a"} · Behind ${gitStatus && typeof gitStatus.behind === "number" ? gitStatus.behind : "n/a"}`
          }
        ]
      },
      {
        title: "ASSISTANT LANES",
        nodes: [
          {
            code: "S03-01",
            name: "OLLAMA-CODE-LANE",
            desc: `Token total ${(tokens && tokens.summary && tokens.summary.ollama_tokens_total) || 0}`
          },
          {
            code: "S03-02",
            name: "AI-RESPONSE-STREAM",
            desc: `Recent activity ${((worker && worker.recent_events && worker.recent_events.length) || 0)} events`
          }
        ]
      }
    ];

    flowSectionsEl.innerHTML = sections.map(section => {
      return [
        `<div class="section-block">`,
        `<div class="section-caption">${escHtml(section.title)}</div>`,
        `<div class="node-grid">`,
        ...section.nodes.map(node => [
          `<div class="node-card">`,
          `<div class="node-code">${escHtml(node.code)}</div>`,
          `<div class="node-name">${escHtml(node.name)}</div>`,
          `<div class="node-desc">${escHtml(node.desc)}</div>`,
          `</div>`
        ].join("")),
        `</div>`,
        `</div>`
      ].join("");
    }).join("");

    if (flowEntryCardEl) {
      const activeFile = getActiveFile();
      flowEntryCardEl.textContent = activeFile ? activeFile.title : "main.py";
    }
    if (flowEntryMetaEl) {
      flowEntryMetaEl.textContent = `${(gitStatus && gitStatus.branch) || "main"} · ${ideState.activeSymbol || "editor active"} · local shell`;
    }
    if (flowSummaryStatsEl) {
      flowSummaryStatsEl.textContent = `${sections.length} lanes · ${(tokens && tokens.summary && tokens.summary.tasks_tracked) || 0} tracked tasks · editor ready`;
    }
    if (flowSummaryPathEl) {
      flowSummaryPathEl.textContent = `workspace -> editor -> assistant -> terminal`;
    }
  }

  function renderResponseStream(worker) {
    // autopilotSummaryEl removed — Autopilot Live panel now shows task history
  }

  function renderTaskHistory(taskHistory) {
    if (!autopilotLiveEl) return;
    const tasks = (taskHistory && taskHistory.tasks) ? taskHistory.tasks : [];
    if (taskHistoryCountEl) {
      taskHistoryCountEl.textContent = tasks.length ? `(${tasks.length} tasks)` : "";
    }
    if (tasks.length === 0) {
      autopilotLiveEl.innerHTML = `<div class="th-empty">No task results yet.</div>`;
      return;
    }
    autopilotLiveEl.innerHTML = tasks.map(t => {
      const ok = t.status === "completed";
      const statusCls = ok ? "th-badge-ok" : "th-badge-fail";
      const statusLabel = ok ? "✓ completed" : "✗ " + t.status;
      const ts = t.timestamp_utc ? t.timestamp_utc.replace("T", " ").replace("Z", " UTC") : "";
      const keyLines = (t.key_lines || []).map(l => `<div class="th-kv">${escHtml(l)}</div>`).join("");
      const summary = t.summary && t.summary !== "Executor script completed successfully."
        ? `<div class="th-summary">${escHtml(t.summary)}</div>` : "";
      return [
        `<div class="th-card ${ok ? "th-card-ok" : "th-card-fail"}">`,
        `  <div class="th-header">`,
        `    <span class="th-id">${escHtml(t.task_id)}</span>`,
        `    <span class="th-badge ${statusCls}">${statusLabel}</span>`,
        `    <span class="th-ts">${escHtml(ts)}</span>`,
        `  </div>`,
        summary,
        keyLines ? `<div class="th-kvs">${keyLines}</div>` : "",
        `</div>`
      ].join("");
    }).join("");
  }

  async function submitChatPrompt() {
    if (!chatPromptInputEl || !chatPromptSendEl || chatState.pending) return;

    const prompt = String(chatPromptInputEl.value || "").trim();
    if (!prompt) {
      setChatStatus("Enter a prompt first.", true);
      return;
    }

    const activeFile = getActiveFile();
    const contextLabel = ideState.activeSymbol || (activeFile ? activeFile.title : "editor");
    chatState.pending = true;
    chatPromptSendEl.disabled = true;
    setChatStatus("Streaming from Ollama...");
    appendChatMessage("user", prompt, "ollama", "local-pc");
    renderResponseStream(ideState.context.worker);

    let responseText = "";
    let model = "ollama";
    let source = "local-ide";

    try {
      const response = await fetch(activeBackendBaseUrl + "/api/llm/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          prompt: buildAssistantPrompt(contextLabel, prompt),
          source: "local",
        }),
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || ""; // Keep incomplete line in buffer

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;

          try {
            const event = JSON.parse(line.slice(6));
            if (event.error) {
              throw new Error(event.error);
            }
            if (event.token) {
              responseText += event.token;
              // Progressively update the assistant message as tokens arrive
              if (chatState.messages.length > 0 && chatState.messages[chatState.messages.length - 1].role !== "assistant") {
                appendChatMessage("assistant", event.token, model, source);
              } else if (chatState.messages.length > 0 && chatState.messages[chatState.messages.length - 1].role === "assistant") {
                // Update the last message with accumulated text
                chatState.messages[chatState.messages.length - 1].text = responseText;
              } else {
                appendChatMessage("assistant", event.token, model, source);
              }
              renderResponseStream(ideState.context.worker);
              setChatStatus(`Streaming... (${responseText.length} chars)`);
            }
            if (event.done && event.text) {
              // Final message with complete text
              responseText = event.text;
              if (chatState.messages.length > 0 && chatState.messages[chatState.messages.length - 1].role === "assistant") {
                chatState.messages[chatState.messages.length - 1].text = responseText;
              }
              break;
            }
          } catch (parseErr) {
            // Skip malformed SSE events
          }
        }
      }

      if (!responseText) {
        responseText = "No response returned from Ollama.";
      }

      // Ensure final message is in chat state
      if (chatState.messages.length === 0 || chatState.messages[chatState.messages.length - 1].role !== "assistant") {
        appendChatMessage("assistant", responseText, model, source);
      } else {
        chatState.messages[chatState.messages.length - 1].text = responseText;
      }

      saveChatHistory();
      const inserted = applyAssistantCodeToEditor(responseText);
      chatPromptInputEl.value = "";
      setChatStatus(inserted ? "Ollama response inserted into code pane." : "Ollama response received.");
    } catch (err) {
      setChatStatus("Chat failed: " + String(err), true);
      appendChatMessage("assistant", `[error] ${String(err)}`, model, source);
    } finally {
      chatState.pending = false;
      chatPromptSendEl.disabled = false;
      renderResponseStream(ideState.context.worker);
    }
  }

  function normalizeBaseUrl(url) {
    return String(url || "").replace(/\/+$/, "");
  }

  function buildBackendCandidates() {
    const candidates = [];

    if (Array.isArray(cfg.backendCandidates)) {
      for (const c of cfg.backendCandidates) {
        const n = normalizeBaseUrl(c);
        if (n) candidates.push(n);
      }
    }

    const configured = normalizeBaseUrl(cfg.backendBaseUrl);
    if (configured) candidates.push(configured);

    if (location.protocol === "http:" || location.protocol === "https:") {
      candidates.push(normalizeBaseUrl(location.origin.replace(/:\d+$/, "") + ":5555"));
    }

    candidates.push("http://127.0.0.1:5555");
    candidates.push("http://localhost:5555");

    return [...new Set(candidates.filter(Boolean))];
  }

  function escHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function appendEventLines(newLines) {
    let anyNew = false;
    for (const line of newLines) {
      if (!line || seenLines.has(line)) continue;
      seenLines.add(line);
      const color = (lineIndex % 2 === 0) ? "a" : "b";
      const ts_iso = new Date().toISOString();
      const item = { line, color, ts_iso };
      eventBuffer.push(item);
      lineIndex++;
      const div = document.createElement("div");
      div.className = "log-line log-line-" + color;
      div.innerHTML = escHtml(line);
      workerLogPanelEl.appendChild(div);
      anyNew = true;
    }
    if (anyNew && !userPinned) {
      workerLogPanelEl.scrollTop = workerLogPanelEl.scrollHeight;
    }
  }

  function todayKey() {
    return "cockpit_events_" + new Date().toISOString().slice(0, 10);
  }

  function saveSession() {
    try {
      localStorage.setItem(todayKey(), JSON.stringify(eventBuffer));
    } catch (_) {}
  }

  function checkMidnightReset() {
    const day = new Date().toISOString().slice(0, 10);
    if (day !== currentDay) {
      // Save final state for the old day, then reset
      saveSession();
      eventBuffer = [];
      seenLines.clear();
      lineIndex = 0;
      currentDay = day;
      workerLogPanelEl.innerHTML = "";
    }
  }

  function loadSession() {
    try {
      const saved = JSON.parse(localStorage.getItem(todayKey()) || "[]");
      if (!Array.isArray(saved) || saved.length === 0) return;
      for (const item of saved) {
        if (!item.line || seenLines.has(item.line)) continue;
        seenLines.add(item.line);
        eventBuffer.push(item);
        lineIndex++;
        const div = document.createElement("div");
        div.className = "log-line log-line-" + (item.color || "a");
        div.innerHTML = escHtml(item.line);
        workerLogPanelEl.appendChild(div);
      }
      workerLogPanelEl.scrollTop = workerLogPanelEl.scrollHeight;
    } catch (_) {}
  }

  // Save to localStorage every hour; check for day rollover every minute
  setInterval(saveSession, 3600000);
  setInterval(checkMidnightReset, 60000);

  function parseEventTimestamp(line) {
    const token = String(line || "").split(" | ", 1)[0].trim();
    if (!token) return null;
    const normalized = token.replace("Z", "+00:00");
    const ts = Date.parse(normalized);
    return Number.isFinite(ts) ? ts : null;
  }

  function parseTokenRows(rawText) {
    const rows = [];
    for (const raw of String(rawText || "").split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const parts = line.split("|").map(s => s.trim());
      if (parts.length !== 12) continue;
      if (!parts[0].startsWith("MTASK-")) continue;
      rows.push({
        task_id: parts[0],
        ollama_total: Number(parts[7]) || 0,
        vs_total: Number(parts[8]) || 0,
        total_tokens: Number(parts[9]) || 0,
        est_cost_usd: Number(parts[10]) || 0,
        updated_utc: parts[11]
      });
    }
    rows.sort((a, b) => String(b.task_id).localeCompare(String(a.task_id)));
    return rows;
  }

  function updateAutopilotWatchdog(worker) {
    if (!enableHardReset) return;

    const recentEvents = Array.isArray(worker && worker.recent_events) ? worker.recent_events : [];
    const fingerprint = [
      (worker && worker.worker_id) || "",
      (worker && worker.mode) || "",
      (worker && worker.last_run_local) || "",
      (worker && worker.last_task_processed) || "",
      (worker && worker.note) || "",
      recentEvents.slice(-5).join("\n")
    ].join("||");

    if (fingerprint !== lastAutopilotFingerprint) {
      lastAutopilotFingerprint = fingerprint;
      lastAutopilotChangeMs = Date.now();
      return;
    }

    if ((Date.now() - lastAutopilotChangeMs) >= autopilotStaleResetMs) {
      consumeAndReload("local-stale-" + Date.now(), "autopilot_stale_120s");
    }
  }

  function consumeAndReload(nonce, reason) {
    if (hardResetInFlight) return;
    hardResetInFlight = true;
    try {
      localStorage.setItem(resetNonceKey, String(nonce));
    } catch (_err) {
      // Continue even if storage is unavailable.
    }
    saveSession();
    const nextUrl = new URL(window.location.href);
    nextUrl.searchParams.set("_hr", String(nonce));
    nextUrl.searchParams.set("_hrt", String(Date.now()));
    nextUrl.searchParams.set("_reason", String(reason || "requested"));
    window.location.replace(nextUrl.toString());
  }

  async function maybeApplyHardResetTrigger() {
    if (!enableHardReset) return;

    const resetRaw = await tryFetchLocalText(cfg.localStatePaths?.hardReset || "../../state/cockpit_hard_reset_request.json");
    if (!resetRaw) return;

    let payload;
    try {
      payload = JSON.parse(resetRaw);
    } catch (_err) {
      return;
    }

    const nonce = payload && payload.nonce ? String(payload.nonce) : "";
    if (!nonce) return;

    let lastNonce = "";
    try {
      lastNonce = String(localStorage.getItem(resetNonceKey) || "");
    } catch (_err) {
      lastNonce = "";
    }

    if (nonce && nonce !== lastNonce) {
      consumeAndReload(nonce, payload.reason || "requested");
    }
  }

  async function tryFetchLocalText(relPath) {
    const paths = [relPath, relPath.replace(/^\.\//, "")];
    for (const p of paths) {
      try {
        const res = await fetchWithTimeout(p, 2500);
        if (res.ok) {
          return await res.text();
        }
      } catch (_err) {
        // Continue trying other relative forms.
      }
    }
    return "";
  }

  async function refreshFromLocalFiles() {
    const statusRaw = await tryFetchLocalText(cfg.localStatePaths?.status || "../../state/worker_autopilot_status.json");
    const eventsRaw = await tryFetchLocalText(cfg.localStatePaths?.events || "../../state/worker_autopilot_events.log");
    const tokenRaw = await tryFetchLocalText(cfg.localStatePaths?.tokens || "../TOKEN_COUNTER_TASKS.txt");

    if (!statusRaw && !eventsRaw && !tokenRaw) {
      return false;
    }

    let status = {};
    if (statusRaw) {
      try {
        status = JSON.parse(statusRaw);
      } catch (_err) {
        status = {};
      }
    }

    const events = eventsRaw
      ? eventsRaw.split(/\r?\n/).map(s => s.trim()).filter(Boolean).slice(-40)
      : [];

    const rows = parseTokenRows(tokenRaw);
    const nowMs = Date.now();
    const lastRunMs = status.last_run_utc ? Date.parse(String(status.last_run_utc).replace("Z", "+00:00")) : NaN;
    const staleSeconds = Number.isFinite(lastRunMs) ? Math.max(0, Math.floor((nowMs - lastRunMs) / 1000)) : null;

    // Compute cadence deltas from the 4 most recent events (most-recent first)
    const recentDesc = events.slice().reverse();
    const deltas = [];
    for (let i = 0; i < Math.min(recentDesc.length - 1, 3); i += 1) {
      const a = parseEventTimestamp(recentDesc[i]);
      const b = parseEventTimestamp(recentDesc[i + 1]);
      if (Number.isFinite(a) && Number.isFinite(b)) {
        deltas.push(Math.round((a - b) / 1000));
      }
    }

    const cadence = {
      status: deltas.length >= 3 ? (deltas.every(d => d >= 55 && d <= 65) ? "pass" : "drift") : "insufficient",
      gate_3x60_pass: deltas.length >= 3 && deltas.every(d => d >= 55 && d <= 65),
      deltas_seconds: deltas,
      source: "local-file",
      reported_at_utc: new Date().toISOString()
    };

    const worker = {
      worker_id: status.worker_id || "unknown",
      mode: status.mode || "unknown",
      last_run_local: status.last_run_local || "n/a",
      last_task_processed: status.last_task_processed || "",
      note: status.note || "",
      status_source: "local-file",
      events_source: "local-file",
      stale_seconds: staleSeconds,
      recent_events: events
    };

    const tokenSummary = {
      tasks_tracked: rows.length,
      ollama_tokens_total: rows.reduce((a, r) => a + asNum(r.ollama_total), 0),
      vs_tokens_total: rows.reduce((a, r) => a + asNum(r.vs_total), 0),
      all_tokens_total: rows.reduce((a, r) => a + asNum(r.total_tokens), 0),
      estimated_cost_usd_total: rows.reduce((a, r) => a + asNum(r.est_cost_usd), 0)
    };

    renderWorkerLog(worker);
    renderCadence(cadence);
    renderSync({
      sync_error: "unknown",
      heads_match: false,
      branch: "local-file",
      local_head_short: "n/a",
      origin_head_short: "n/a",
      working_tree: "n/a",
      sync_error_source: "local-file",
      reported_at_utc: new Date().toISOString()
    });
    renderTokens({ source: "local-file", rows, summary: tokenSummary });
    renderOllama({ cost_mode: { inference_policy: "ollama_local_first", notes: "Backend offline; showing local snapshot." } }, { status: "snapshot", source_key: "local-file" });
    return true;
  }

  async function fetchWithTimeout(url, timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await fetch(url, { signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }
  }

  async function discoverBackend() {
    const candidates = buildBackendCandidates();
    for (const base of candidates) {
      try {
        const res = await fetchWithTimeout(base + "/health", 2200);
        if (!res.ok) continue;
        const data = await res.json();
        if (data && data.status === "ok") {
          activeBackendBaseUrl = base;
          return base;
        }
      } catch (_err) {
        // Try next candidate.
      }
    }
    activeBackendBaseUrl = "";
    return "";
  }

  function asNum(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }

  function setBackendStatus(ok, msg) {
    statusEl.textContent = ok ? "Backend: online" : "Backend: offline";
    statusEl.classList.toggle("status-offline", !ok);
    if (msg) statusEl.textContent += " | " + msg;
  }

  function renderDisconnected(reason) {
    const hints = [
      "COCKPIT LINK DOWN",
      "",
      "No backend endpoint responded.",
      "Expected backend: uvicorn on :5555",
      "",
      "Try:",
      "- start backend stack",
      "- verify CUSTOMIDE_CONFIG.backendBaseUrl",
      "- open page over http:// instead of file:// when possible",
      "",
      "error: " + (reason || "network_error")
    ].join("\n");

    // Append a separator to the live log rather than wiping it
    appendEventLines(["-- BACKEND OFFLINE: " + (reason || "network_error") + " --"]);
    gitPanelEl.textContent = hints;
    syncCadencePanelEl.textContent = hints;
    tokenPanelEl.textContent = hints;
    ollamaPanelEl.textContent = hints;
    if (runtimePanelEl) {
      runtimePanelEl.textContent = hints;
    }
  }

  function renderSync(sync, gitStatus) {
    const err = (sync && sync.sync_error) || "unknown";
    const gate = (sync && sync.heads_match) ? "heads_match" : "heads_diff";
    syncBadgeEl.textContent = "Sync: " + err + " | " + gate;

    const remotes = (gitStatus && gitStatus.remotes) ? gitStatus.remotes : {};
    const remoteNames = Object.keys(remotes);
    const originUrl = remotes.origin || "(not configured)";
    const ahead = (gitStatus && typeof gitStatus.ahead === "number") ? gitStatus.ahead : "n/a";
    const behind = (gitStatus && typeof gitStatus.behind === "number") ? gitStatus.behind : "n/a";
    const upstream = (gitStatus && gitStatus.upstream) ? gitStatus.upstream : "(none)";

    gitPanelEl.textContent = [
      "Git sync health",
      "- branch: " + ((gitStatus && gitStatus.branch) || (sync && sync.branch) || "unknown"),
      "- upstream: " + upstream,
      "- ahead: " + ahead,
      "- behind: " + behind,
      "- origin: " + originUrl,
      "- remotes: " + (remoteNames.length ? remoteNames.join(", ") : "none"),
      "- local_head: " + ((sync && sync.local_head_short) || "unknown"),
      "- origin_head: " + ((sync && sync.origin_head_short) || "unknown"),
      "- heads_match: " + (((sync && sync.heads_match) ? "yes" : "no")),
      "- working_tree: " + ((gitStatus && gitStatus.working_tree) || (sync && sync.working_tree) || "unknown"),
      "- sync_error: " + err,
      "- source: " + ((sync && sync.sync_error_source) || "n/a"),
      "- reported_at_utc: " + ((sync && sync.reported_at_utc) || "n/a")
    ].join("\n");

    if (gitRemoteUrlEl && remotes.origin) {
      gitRemoteUrlEl.value = remotes.origin;
    }
  }

  async function postJson(path, payload) {
    if (!activeBackendBaseUrl) {
      await discoverBackend();
    }
    if (!activeBackendBaseUrl) {
      throw new Error("no_backend_discovered");
    }
    const res = await fetch(activeBackendBaseUrl + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload || {}),
    });
    if (!res.ok) {
      let detail = "request failed";
      try {
        const body = await res.json();
        detail = body.detail || detail;
      } catch (_err) {
        // Ignore decode failures.
      }
      throw new Error(detail + " (" + res.status + ")");
    }
    return await res.json();
  }

  function setGitButtonsEnabled(enabled) {
    for (const btn of [gitConnectBtnEl, gitFetchBtnEl, gitPullBtnEl, gitPushBtnEl]) {
      if (btn) btn.disabled = !enabled;
    }
  }

  function wireGitControls() {
    if (!gitConnectBtnEl) return;

    async function runGitAction(label, action) {
      try {
        setGitButtonsEnabled(false);
        setGitOpResult(label + "...");
        await action();
        setGitOpResult(label + " complete.");
        await refreshAll(false, "full");
      } catch (err) {
        setGitOpResult(label + " failed: " + String(err), true);
      } finally {
        setGitButtonsEnabled(true);
      }
    }

    gitConnectBtnEl.addEventListener("click", async () => {
      const remoteUrl = String((gitRemoteUrlEl && gitRemoteUrlEl.value) || "").trim();
      if (!remoteUrl) {
        setGitOpResult("Enter a remote URL first.", true);
        return;
      }
      await runGitAction("Connect remote", async () => {
        await postJson("/api/git/connect", { remote_name: "origin", remote_url: remoteUrl });
      });
    });

    gitFetchBtnEl.addEventListener("click", async () => {
      await runGitAction("Fetch", async () => {
        await postJson("/api/git/fetch", { remote_name: "origin" });
      });
    });

    gitPullBtnEl.addEventListener("click", async () => {
      await runGitAction("Pull", async () => {
        await postJson("/api/git/pull", { remote_name: "origin" });
      });
    });

    gitPushBtnEl.addEventListener("click", async () => {
      await runGitAction("Push", async () => {
        await postJson("/api/git/push", { remote_name: "origin", set_upstream: true });
      });
    });
  }

  function wireChatComposer() {
    if (!chatPromptSendEl || !chatPromptInputEl) return;

    chatPromptSendEl.addEventListener("click", async () => {
      await submitChatPrompt();
    });

    chatPromptInputEl.addEventListener("keydown", async (event) => {
      if (event.key !== "Enter" || event.shiftKey) return;
      event.preventDefault();
      await submitChatPrompt();
    });
  }

  function renderCadence(cadence) {
    const deltas = (cadence && cadence.deltas_seconds) ? cadence.deltas_seconds.join(", ") : "n/a";
    syncCadencePanelEl.textContent = [
      "Worker cadence",
      "- status: " + ((cadence && cadence.status) || "unknown"),
      "- gate_3x60_pass: " + (((cadence && cadence.gate_3x60_pass) ? "yes" : "no")),
      "- deltas_seconds: " + deltas,
      "- source: " + ((cadence && cadence.source) || "n/a"),
      "- reported_at_utc: " + ((cadence && cadence.reported_at_utc) || "n/a")
    ].join("\n");
  }

  function renderWorkerLog(worker) {
    const events = (worker && worker.recent_events) ? worker.recent_events : [];
    appendEventLines(events);
  }

  function renderOperatorLoop(opLoop) {
    const panelEl = document.getElementById("opLoopPanel");
    const statusEl = document.getElementById("opLoopStatus");
    if (!panelEl) return;

    const alive = opLoop && opLoop.alive;
    const stale = opLoop && opLoop.stale_seconds != null ? opLoop.stale_seconds : null;
    const lines = (opLoop && opLoop.recent_log) ? opLoop.recent_log : [];

    if (statusEl) {
      if (alive) {
        statusEl.textContent = "● ALIVE (" + stale + "s ago)";
        statusEl.style.color = "#4ade80";
      } else if (stale != null) {
        statusEl.textContent = "⚠ STALE (" + stale + "s ago)";
        statusEl.style.color = "#f59e0b";
      } else {
        statusEl.textContent = "○ NOT STARTED";
        statusEl.style.color = "#6b7280";
      }
    }

    panelEl.innerHTML = "";
    lines.forEach(line => {
      const div = document.createElement("div");
      div.className = "log-line" +
        (line.includes("RETRY") ? " log-warn" : "") +
        (line.includes("ERROR") || line.includes("FAILED") ? " log-err" : "") +
        (line.includes("SUCCESS") || line.includes("completed") ? " log-ok" : "");
      div.textContent = line;
      panelEl.appendChild(div);
    });
    panelEl.scrollTop = panelEl.scrollHeight;
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function renderMtaskStream(stream) {
    const panelEl = document.getElementById("mtaskStreamPanel");
    const statusEl = document.getElementById("mtaskStreamStatus");
    if (!panelEl) return;

    const entries = (stream && stream.entries) || [];
    const summary = (stream && stream.summary) || {};

    if (statusEl) {
      const total = summary.total || 0;
      const done = summary.completed || 0;
      const fail = summary.failed || 0;
      const pend = summary.pending || 0;
      statusEl.innerHTML =
        '<span style="color:#cbd5e1">' + total + ' shown</span>' +
        ' · <span style="color:#4ade80">' + done + ' completed</span>' +
        ' · <span style="color:#f87171">' + fail + ' failed</span>' +
        (pend ? ' · <span style="color:#f59e0b">' + pend + ' pending</span>' : "");
    }

    if (!entries.length) {
      panelEl.innerHTML = '<div class="mtask-card">No MTASKs in stream yet.</div>';
      return;
    }

    panelEl.innerHTML = "";
    entries.forEach(e => {
      const status = (e.execution_status || "pending").toLowerCase();
      const cls = status === "completed" ? "mtask-completed" :
                  status === "failed" ? "mtask-failed" : "mtask-pending";
      const card = document.createElement("div");
      card.className = "mtask-card " + cls;

      const meta = [
        e.issued_by ? "by " + e.issued_by : "",
        e.assigned_to ? "→ " + e.assigned_to : "",
        e.priority || "",
        e.category || "",
        e.issued_at_utc || "",
      ].filter(Boolean).join(" · ");

      let html = '<div class="mtask-card-header">' +
        '<span class="mtask-id">' + escapeHtml(e.task_id) + '</span>' +
        '<span class="mtask-status ' + status + '">' + escapeHtml(status) + '</span>' +
        '<span class="mtask-meta">' + escapeHtml(meta) + '</span>' +
        '</div>';

      if (e.description) {
        html += '<div class="mtask-desc">' + escapeHtml(e.description) + '</div>';
      }

      if (e.executor_script) {
        html += '<div class="mtask-section-label">code · ' + escapeHtml(e.executor_script) + '</div>';
        html += '<pre class="mtask-code">' + escapeHtml(e.executor_excerpt || "(script not found in repo)") + '</pre>';
      } else {
        html += '<div class="mtask-section-label">code</div>' +
                '<div class="mtask-summary">(no executor script)</div>';
      }

      html += '<div class="mtask-section-label">summary' +
        (e.result_timestamp_utc ? ' · ' + escapeHtml(e.result_timestamp_utc) : "") +
        '</div>';
      if (status === "pending") {
        html += '<div class="mtask-summary">(awaiting result)</div>';
      } else {
        html += '<div class="mtask-summary">' + escapeHtml(e.result_summary || "(no summary)") + '</div>';
        if (e.stdout_excerpt) {
          html += '<pre class="mtask-code">' + escapeHtml(e.stdout_excerpt) + '</pre>';
        }
        if (e.stderr_excerpt && status === "failed") {
          html += '<pre class="mtask-code mtask-stderr">' + escapeHtml(e.stderr_excerpt) + '</pre>';
        }
      }

      card.innerHTML = html;
      panelEl.appendChild(card);
    });
  }

  function renderTokens(tokens) {
    const summary = (tokens && tokens.summary) || {};
    const rows = (tokens && tokens.rows) ? tokens.rows.slice(0, 16) : [];
    const table = rows.map(r => {
      const status = (r.execution_status || "").slice(0, 4);
      return [
        (r.task_id || "").padEnd(20, " "),
        status.padEnd(4, " "),
        String(asNum(r.ollama_calls)).padStart(5, " "),
        String(asNum(r.prompt_eval_count)).padStart(7, " "),
        String(asNum(r.eval_count)).padStart(7, " "),
        String(asNum(r.total_tokens)).padStart(8, " ")
      ].join(" | ");
    });

    tokenPanelEl.textContent = [
      "Token counters (per-MTASK · derived from result.json)",
      "- source: " + ((tokens && tokens.source) || "n/a"),
      "- tasks_tracked: " + (summary.tasks_tracked || 0),
      "- ollama_calls_total: " + (summary.ollama_calls_total || 0),
      "- prompt_eval_total: " + (summary.prompt_eval_total || 0),
      "- eval_count_total:  " + (summary.eval_count_total || 0),
      "- ollama_tokens_total: " + (summary.ollama_tokens_total || 0),
      "- output_chars_total: " + (summary.output_chars_total || 0),
      "",
      "task_id              | st   | calls |  prompt |    eval |    total",
      "-----------------------------------------------------------------",
      ...table
    ].join("\n");
  }

  function renderOllama(runtime, llm) {
    const costMode = runtime && runtime.cost_mode ? runtime.cost_mode : {};
    const llmStatus = llm ? (llm.status || "unknown") : "pending";
    const source = llm ? (llm.source_key || "n/a") : "n/a";
    llmBadgeEl.textContent = "LLM: " + llmStatus + " | source: " + source;

    ollamaPanelEl.textContent = [
      "Model lane",
      "- chat model: ollama",
      "- code model: ollama",
      "- policy: " + (costMode.inference_policy || "ollama_local_first"),
      "- note: " + (costMode.notes || "Use Ollama for both chat and coding."),
      "- llm_status: " + llmStatus,
      "- llm_source: " + source
    ].join("\n");

    if (runtimePanelEl) {
      runtimePanelEl.textContent = [
        "Problems",
        "- remote execute wired: " + (((runtime && runtime.backend && runtime.backend.execute_routes && runtime.backend.execute_routes.remote) ? "yes" : "no")),
        "- local run target: " + ((runtime && runtime.backend && runtime.backend.execute_routes && runtime.backend.execute_routes.local) || "n/a"),
        "- remote url available: " + (((runtime && runtime.worker && runtime.worker.remote_url_available) ? "yes" : "no")),
        "- current issue: none blocking",
        "- state: frontend shell active"
      ].join("\n");
    }
  }

  async function fetchJson(path) {
    if (!activeBackendBaseUrl) {
      await discoverBackend();
    }
    if (!activeBackendBaseUrl) {
      throw new Error("no_backend_discovered");
    }

    const res = await fetchWithTimeout(activeBackendBaseUrl + path, 5000);
    if (!res.ok) throw new Error(path + " failed (" + res.status + ")");
    return await res.json();
  }

  async function refreshAll(forceLlm, mode = "lower") {
    const bundle = await fetchJson("/api/status/bundle");
    const runtime = bundle.runtime || {};
    const sync = bundle.sync_health || {};
    let gitStatus = {};
    try {
      gitStatus = await fetchJson("/api/git/status");
    } catch (_err) {
      gitStatus = {};
    }
    const cadence = bundle.sync_cadence || {};
    const worker = bundle.worker_log || {};
    const tokens = bundle.token_counters || {};
    const opLoop = bundle.operator_loop || {};
    const taskHistory = bundle.task_history || {};
    const mtaskStream = bundle.mtask_stream || {};
    renderOperatorLoop(opLoop);
    renderTaskHistory(taskHistory);
    renderMtaskStream(mtaskStream);

    updateIdeState(worker, gitStatus, tokens, runtime, sync, cadence);

    setBackendStatus(true, "bundle ok");
    if (mode === "full") {
      renderSync(sync, gitStatus);
      renderCadence(cadence);
      renderProgramMeta(worker, gitStatus, runtime);
      renderEditorTabs();
      renderRouteList(worker, gitStatus);
      renderEditorSurface(worker, gitStatus, tokens, runtime);
    }

    // Only the four lower modules should auto-refresh during polling.
    renderOpenSymbols();
    renderFlowCanvas(worker, gitStatus, tokens);
    renderWorkerLog(worker);
    updateAutopilotWatchdog(worker);
    renderTokens(tokens);

    if (forceLlm) {
      try {
        const llm = await fetchJson("/api/llm/health");
        lastKnownLlm = llm;
        renderOllama(runtime, llm);
      } catch (_err) {
        lastKnownLlm = { status: "offline", source_key: "n/a" };
        renderOllama(runtime, lastKnownLlm);
      }
    } else {
      renderOllama(runtime, lastKnownLlm);
    }

    lastRefreshEl.textContent = "Last refresh: " + new Date().toLocaleTimeString();
  }

  async function boot() {
    wireGitControls();
    wireChatComposer();
    wireIdeInteractions();
    loadChatHistory();
    renderResponseStream(ideState.context.worker);
    await maybeApplyHardResetTrigger();
    loadSession();
    await discoverBackend();
    await loadSharedChatHistory();
    try {
      await refreshAll(true, "full");
      setBackendStatus(true, "endpoint: " + activeBackendBaseUrl);
    } catch (err) {
      lastErrorText = String(err);
      const fallbackOk = await refreshFromLocalFiles();
      if (fallbackOk) {
        updateAutopilotWatchdog({
          worker_id: statusEl.textContent,
          mode: "snapshot",
          last_run_local: "snapshot",
          last_task_processed: "",
          note: "snapshot mode",
          recent_events: []
        });
        setBackendStatus(false, "snapshot mode | backend down");
      } else {
        setBackendStatus(false, (activeBackendBaseUrl || "none") + " | " + lastErrorText);
        renderDisconnected(lastErrorText);
      }
    }

    setInterval(async () => {
      if (document.hidden) return;
      await maybeApplyHardResetTrigger();
      tick += 1;
      const forceLlm = (tick % llmRefreshEvery) === 0;
      try {
        await refreshAll(forceLlm, "lower");
        setBackendStatus(true, "endpoint: " + activeBackendBaseUrl);
      } catch (err) {
        lastErrorText = String(err);
        activeBackendBaseUrl = "";
        await discoverBackend();
        const fallbackOk = await refreshFromLocalFiles();
        if (fallbackOk) {
          updateAutopilotWatchdog({
            worker_id: statusEl.textContent,
            mode: "snapshot",
            last_run_local: "snapshot",
            last_task_processed: "",
            note: "snapshot mode",
            recent_events: []
          });
          setBackendStatus(false, "snapshot mode | backend down");
        } else {
          setBackendStatus(false, (activeBackendBaseUrl || "none") + " | " + lastErrorText);
          renderDisconnected(lastErrorText);
        }
      }
    }, refreshIntervalMs);
  }

  // ── Cockpit AI Chat ────────────────────────────────────────────────────
  (function initCockpitChat() {
    const threadStorageKey = "cockpit_chat_threads_v1";
    const chatMessages = document.getElementById("chatMessages");
    const chatInput    = document.getElementById("chatInput");
    const chatSend     = document.getElementById("chatSend");
    const chatClear    = document.getElementById("chatClear");
    const chatTabCockpit = document.getElementById("chatTabCockpit");
    const chatTabMessenger = document.getElementById("chatTabMessenger");
    const chatChannelTitle = document.getElementById("chatChannelTitle");
    const chatChannelTag = document.getElementById("chatChannelTag");

    let chatBusy = false;
    let activeChannel = "cockpit";

    const defaultThreads = {
      cockpit: {
        title: "Cockpit Room",
        tag: "ops-central ○",
        placeholder: "message ops-central...",
        messages: [
          { role: "ai", text: "Room standby. Connecting to OPS-CENTRAL..." }
        ]
      },
      messenger: {
        title: "Messenger",
        tag: "ole green",
        placeholder: "message ole green...",
        messages: [
          { role: "ai", text: "Messenger ready. Set CUSTOMIDE_CONFIG.messenger.url to connect." }
        ]
      }
    };

    function safeCloneThreads() {
      return {
        cockpit: {
          title: defaultThreads.cockpit.title,
          tag: defaultThreads.cockpit.tag,
          placeholder: defaultThreads.cockpit.placeholder,
          messages: defaultThreads.cockpit.messages.slice()
        },
        messenger: {
          title: defaultThreads.messenger.title,
          tag: defaultThreads.messenger.tag,
          placeholder: defaultThreads.messenger.placeholder,
          messages: defaultThreads.messenger.messages.slice()
        }
      };
    }

    let threads = safeCloneThreads();

    function loadThreads() {
      try {
        const raw = localStorage.getItem(threadStorageKey);
        if (!raw) return;
        const parsed = JSON.parse(raw);
        for (const name of ["cockpit", "messenger"]) {
          const saved = parsed && parsed[name];
          if (!saved || !Array.isArray(saved.messages)) continue;
          threads[name].messages = saved.messages
            .filter(m => m && typeof m.text === "string" && typeof m.role === "string")
            .slice(-120);
          if (threads[name].messages.length === 0) {
            threads[name].messages = defaultThreads[name].messages.slice();
          }
        }
      } catch (_err) {
        threads = safeCloneThreads();
      }
    }

    function saveThreads() {
      try {
        const slim = {
          cockpit: { messages: threads.cockpit.messages.slice(-120) },
          messenger: { messages: threads.messenger.messages.slice(-120) }
        };
        localStorage.setItem(threadStorageKey, JSON.stringify(slim));
      } catch (_err) {
        // Ignore storage failures.
      }
    }

    // Clear history
    chatClear.addEventListener("click", () => {
      const defaultMsg = activeChannel === "cockpit"
        ? "Cleared. I still have access to current cockpit state."
        : "Cleared. Messenger is ready.";
      threads[activeChannel].messages = [{ role: "ai", text: defaultMsg }];
      saveThreads();
      renderActiveThread();
    });

    chatTabCockpit.addEventListener("click", () => setActiveChannel("cockpit"));
    chatTabMessenger.addEventListener("click", () => setActiveChannel("messenger"));

    // Send on Enter (Shift+Enter = newline)
    chatInput.addEventListener("keydown", e => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        sendChat();
      }
    });
    chatSend.addEventListener("click", sendChat);

    // ── Per-pane "Ask AI" buttons + "Analyze Cockpit" ──────────────────
    // Snapshots one or all panes and immediately sends an analysis request
    // to the Cockpit AI (which speaks to Ollama via mide-chat).
    function trimText(s, maxChars) {
      const t = String(s || "").replace(/\u00a0/g, " ").trim();
      if (t.length <= maxChars) return t;
      // Keep tail (most recent state).
      return "...[truncated]...\n" + t.slice(t.length - maxChars);
    }
    function snapshotPane(paneId) {
      const el = document.getElementById(paneId);
      if (!el) return "";
      return trimText(el.innerText || el.textContent || "", 4000);
    }
    function sendCockpitText(text) {
      // Force chat to Cockpit AI tab where Ollama is wired in.
      if (typeof setActiveChannel === "function" && activeChannel !== "cockpit") {
        setActiveChannel("cockpit");
      }
      if (!cockpitWs || cockpitWs.readyState !== WebSocket.OPEN) {
        appendChatMsg("[error] room socket unavailable", "error", "cockpit");
        return false;
      }
      // Echo the user prompt locally (the WS broadcast won't echo back to sender),
      // truncated for readability.
      const preview = text.length > 240 ? text.slice(0, 240) + " …[+" + (text.length - 240) + " chars]" : text;
      appendChatMsg(preview, "user", "cockpit");
      cockpitWs.send(JSON.stringify({ text: text }));
      return true;
    }
    function analyzePane(paneId, paneLabel) {
      const snap = snapshotPane(paneId);
      const prompt =
        "Analyze the following [" + paneLabel + "] pane snapshot from the MIDE cockpit. " +
        "Identify the current health/state, any anomalies, root causes, and 2–4 concrete next " +
        "steps a software/network engineer should take. Reference specific values or lines from " +
        "the snapshot. Be concise.\n\n" +
        "[CTX " + paneLabel + "]\n```\n" + (snap || "(empty)") + "\n```";
      sendCockpitText(prompt);
    }
    function analyzeCockpit() {
      const panes = [
        ["autopilotLive",     "Autopilot Live"],
        ["workerLogPanel",    "Autopilot Events"],
        ["opLoopPanel",       "Operator Loop"],
        ["gitPanel",          "Git Sync"],
        ["syncCadencePanel",  "Sync Cadence"],
        ["tokenPanel",        "Token Counters"],
        ["ollamaPanel",       "Ollama / Cost Mode"],
        ["mtaskStreamPanel",  "MTASK Stream"],
      ];
      // Smaller per-pane budget when bundling all of them.
      const blocks = panes.map(([id, label]) => {
        const el = document.getElementById(id);
        const raw = el ? (el.innerText || el.textContent || "") : "";
        const trimmed = trimText(raw, 1200);
        return "[CTX " + label + "]\n```\n" + (trimmed || "(empty)") + "\n```";
      });
      const prompt =
        "Full MIDE cockpit health analysis. Below are snapshots of all live panes. " +
        "Produce: (1) overall health verdict (green/yellow/red) with one-line reason; " +
        "(2) a prioritized list of the top 3–5 issues found, each with the pane name, " +
        "evidence quoted from the snapshot, root-cause hypothesis, and a concrete fix " +
        "(command, config, or code change); (3) anything that looks healthy and can be " +
        "ignored. Be concise and specific.\n\n" +
        blocks.join("\n\n");
      sendCockpitText(prompt);
    }
    document.querySelectorAll(".ask-ai-btn[data-pane]").forEach(btn => {
      btn.addEventListener("click", () => {
        const paneId = btn.getAttribute("data-pane");
        const label = btn.getAttribute("data-pane-label") || paneId;
        analyzePane(paneId, label);
      });
    });
    const analyzeBtn = document.getElementById("analyzeCockpitBtn");
    if (analyzeBtn) analyzeBtn.addEventListener("click", analyzeCockpit);

    function renderActiveThread() {
      chatMessages.innerHTML = "";
      const items = threads[activeChannel].messages || [];
      for (const msg of items) {
        const div = document.createElement("div");
        div.className = "chat-msg chat-msg-" + msg.role;
        div.textContent = msg.text;
        chatMessages.appendChild(div);
      }
      chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    function setActiveChannel(channel) {
      activeChannel = channel;
      const meta = threads[channel];
      chatChannelTitle.textContent = meta.title;
      chatChannelTag.textContent = meta.tag;
      chatInput.placeholder = meta.placeholder;
      chatTabCockpit.classList.toggle("chat-tab-active", channel === "cockpit");
      chatTabMessenger.classList.toggle("chat-tab-active", channel === "messenger");
      renderActiveThread();
      chatInput.focus();
    }

    function appendChatMsg(text, role, channel) {
      const targetChannel = channel || activeChannel;
      const list = threads[targetChannel].messages;
      list.push({ role, text: String(text) });
      if (list.length > 120) list.splice(0, list.length - 120);
      saveThreads();

      if (targetChannel !== activeChannel) return null;
      const div = document.createElement("div");
      div.className = "chat-msg chat-msg-" + role;
      div.textContent = text;
      chatMessages.appendChild(div);
      chatMessages.scrollTop = chatMessages.scrollHeight;
      return div;
    }

    const ROOM_NAME = "OPS-CENTRAL";
    const ROOM_USER = "UBUNTU";
    const ROOM_AI = "LARIEL";
    const ROOM_PORT = 7070;
    let cockpitWs = null;
    let cockpitReconnectMs = 1500;

    function getRoomWsUrl() {
      const scheme = window.location.protocol === "https:" ? "wss" : "ws";
      const host = window.location.hostname || "127.0.0.1";
      return `${scheme}://${host}:${ROOM_PORT}/ws/${encodeURIComponent(ROOM_NAME)}/${encodeURIComponent(ROOM_USER)}`;
    }

    function extractHm(tsIso) {
      const ts = String(tsIso || "");
      if (ts.length >= 16 && ts[10] === "T") return ts.substring(11, 16);
      return new Date().toTimeString().slice(0, 5);
    }

    function removeThinking(channel) {
      const list = threads[channel].messages;
      if (list.length > 0) {
        const last = list[list.length - 1];
        if (last && last.role === "ai chat-thinking") {
          list.pop();
          saveThreads();
        }
      }
      if (channel === activeChannel && chatMessages.lastElementChild && chatMessages.lastElementChild.className.includes("chat-thinking")) {
        chatMessages.lastElementChild.remove();
      }
    }

    function handleRoomMessage(data) {
      if (!data || typeof data !== "object") return;
      const kind = String(data.kind || "chat");
      const sender = String(data.sender || "SYSTEM");

      if (kind === "presence") {
        try {
          const users = JSON.parse(String(data.text || "[]"));
          if (Array.isArray(users)) {
            threads.cockpit.tag = `ops-central ● ${users.length}`;
            if (activeChannel === "cockpit") chatChannelTag.textContent = threads.cockpit.tag;
          }
        } catch (_err) {
          // ignore malformed presence payload
        }
        return;
      }

      if (kind === "typing") {
        removeThinking("cockpit");
        appendChatMsg(`[${extractHm(data.ts)}] ${sender}: ...`, "ai chat-thinking", "cockpit");
        return;
      }

      removeThinking("cockpit");

      if (kind === "join" || kind === "leave") {
        appendChatMsg(`[${extractHm(data.ts)}] SYSTEM: ${String(data.text || "")}`, "ai", "cockpit");
        return;
      }

      const line = `[${extractHm(data.ts)}] ${sender}: ${String(data.text || "")}`;
      if (sender === ROOM_USER) {
        appendChatMsg(line, "user", "cockpit");
      } else if (sender === ROOM_AI || kind === "ai") {
        appendChatMsg(line, "ai", "cockpit");
      } else {
        appendChatMsg(line, "ai", "cockpit");
      }
    }

    function connectCockpitRoom() {
      const wsUrl = getRoomWsUrl();

      try {
        cockpitWs = new WebSocket(wsUrl);
      } catch (_err) {
        setTimeout(connectCockpitRoom, cockpitReconnectMs);
        return;
      }

      cockpitWs.addEventListener("open", () => {
        cockpitReconnectMs = 1500;
        threads.cockpit.tag = "ops-central ●";
        if (activeChannel === "cockpit") chatChannelTag.textContent = threads.cockpit.tag;
        appendChatMsg(`CONNECTED: ${ROOM_USER} -> ${ROOM_NAME}`, "ai", "cockpit");
      });

      cockpitWs.addEventListener("message", evt => {
        let data;
        try {
          data = JSON.parse(evt.data);
        } catch (_err) {
          return;
        }
        handleRoomMessage(data);
      });

      cockpitWs.addEventListener("close", () => {
        cockpitWs = null;
        threads.cockpit.tag = "ops-central ○";
        if (activeChannel === "cockpit") chatChannelTag.textContent = threads.cockpit.tag;
        cockpitReconnectMs = Math.min(cockpitReconnectMs * 2, 15000);
        setTimeout(connectCockpitRoom, cockpitReconnectMs);
      });

      cockpitWs.addEventListener("error", () => {
        if (cockpitWs) cockpitWs.close();
      });
    }

    async function sendMessenger(raw) {
      const messengerCfg = cfg.messenger || {};
      const endpoint = String(messengerCfg.url || "").trim();
      if (!endpoint) {
        throw new Error("Messenger endpoint is not configured.");
      }

      const headers = { "Content-Type": "application/json" };
      if (messengerCfg.authHeader) {
        headers.Authorization = messengerCfg.authHeader;
      }

      const payload = {
        message: raw,
        text: raw,
        channel: "main",
        from: "cockpit",
        model: messengerCfg.model || "messenger-adapter",
        timestamp: new Date().toISOString()
      };

      const resp = await fetch(endpoint, {
        method: "POST",
        headers,
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(90000)
      });

      if (!resp.ok) {
        return "[HTTP " + resp.status + "] " + await resp.text();
      }

      const data = await resp.json();
      // Return null so the send side doesn't echo the ack — reply comes via WS
      return null;
    }

    // ── WebSocket listener: receive messages from Ole Green ────────────
    (function connectRelayWs() {
      const messengerCfg = cfg.messenger || {};
      const httpUrl = String(messengerCfg.url || "").trim();
      if (!httpUrl) return;

      // Derive ws:// URL from the http URL (same host, port+1)
      let wsUrl;
      try {
        const u = new URL(httpUrl);
        wsUrl = "ws://" + u.hostname + ":" + (parseInt(u.port || "8787") + 1);
      } catch (_) {
        wsUrl = "ws://127.0.0.1:8788";
      }

      let ws = null;
      let retryDelay = 2000;

      function connect() {
        try {
          ws = new WebSocket(wsUrl);
        } catch (err) {
          setTimeout(connect, retryDelay);
          return;
        }

        ws.addEventListener("open", () => {
          ws.send(JSON.stringify({ join: "main" }));
          retryDelay = 2000;
          // Update tag to show connected
          if (activeChannel === "messenger" && chatChannelTag) {
            chatChannelTag.textContent = "ole green \u25CF";
          }
        });

        ws.addEventListener("message", evt => {
          let data;
          try { data = JSON.parse(evt.data); } catch (_) { return; }

          // Ignore our own join-ack and ignore messages we sent
          if (data.event === "joined") return;
          const sender = String(data.from || data.username || "");
          if (sender === "cockpit") return;

          const text = String(
            data.text || data.body || data.message || data.content || JSON.stringify(data)
          ).trim();
          if (!text) return;

          const label = sender ? sender + ": " + text : text;
          appendChatMsg(label, "ai", "messenger");
        });

        ws.addEventListener("close", () => {
          ws = null;
          if (chatChannelTag && activeChannel === "messenger") {
            chatChannelTag.textContent = "ole green \u25CB";
          }
          retryDelay = Math.min(retryDelay * 2, 30000);
          setTimeout(connect, retryDelay);
        });

        ws.addEventListener("error", () => ws && ws.close());
      }

      connect();
    })();

    async function sendChat() {
      if (chatBusy) return;
      const raw = chatInput.value.trim();
      if (!raw) return;

      chatInput.value = "";
      chatSend.disabled = true;
      chatBusy = true;

      const sendingChannel = activeChannel;
      const thinkingEl = appendChatMsg("thinking...", "ai chat-thinking", sendingChannel);

      try {
        if (sendingChannel === "cockpit") {
          removeThinking(sendingChannel);
          if (!cockpitWs || cockpitWs.readyState !== WebSocket.OPEN) {
            appendChatMsg("[error] room socket unavailable", "error", sendingChannel);
          } else {
            cockpitWs.send(JSON.stringify({ text: raw }));
          }
        } else {
          const text = await sendMessenger(raw);
          if (thinkingEl && thinkingEl.remove) thinkingEl.remove();
          if (threads[sendingChannel].messages.length > 0) {
            const last = threads[sendingChannel].messages[threads[sendingChannel].messages.length - 1];
            if (last && last.role === "ai chat-thinking") {
              threads[sendingChannel].messages.pop();
              saveThreads();
            }
          }
          // null means sent OK, reply will arrive via WebSocket
          if (text !== null) {
            appendChatMsg(text, "error", sendingChannel);
          }
        }
      } catch (err) {
        removeThinking(sendingChannel);
        appendChatMsg("[error] " + String(err), "error", sendingChannel);
      } finally {
        chatBusy = false;
        chatSend.disabled = false;
        chatInput.focus();
      }
    }

    loadThreads();
    connectCockpitRoom();
    setActiveChannel("cockpit");
  })();
  // ── End Cockpit AI Chat ────────────────────────────────────────────────

  boot();
})();
