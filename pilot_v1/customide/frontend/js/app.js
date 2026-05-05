(async function main() {
  const cfg = window.CUSTOMIDE_CONFIG || { backendBaseUrl: "http://127.0.0.1:5555" };
  const enableHardReset = new URLSearchParams(window.location.search).get("hard_reset") === "1";
  const refreshIntervalMs = Number(cfg.refreshIntervalMs || 2500);
  const llmRefreshEvery = 5;
  let tick = 0;
  let activeBackendBaseUrl = "";
  let lastErrorText = "";

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
  const autopilotSummaryEl = document.getElementById("autopilotSummary");
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
        path: "frontend/css/style.css",
        title: "style.css",
        breadcrumb: "mide-workspace / frontend / css / style.css",
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
    if (!autopilotSummaryEl) return;

    const activeFile = getActiveFile();
    const chatSteps = chatState.messages.map((message, index) => ({
      title: message.role === "assistant" ? "Ollama response" : "Prompt sent",
      body: message.text,
      note: message.role === "assistant"
        ? `model: ${message.model || "ollama"} · source: ${message.source || "local-ide"}`
        : `source: ${message.source || "local-ide"} · context: ${ideState.activeSymbol || (activeFile ? activeFile.title : "editor")}`,
      index,
    }));

    const steps = chatSteps.length > 0
      ? chatSteps
      : [{
          title: "Chat ready",
          body: "Send a prompt to start the conversation.",
          note: `context: ${ideState.activeSymbol || (activeFile ? activeFile.title : "editor")}`,
        }];

    autopilotSummaryEl.innerHTML = steps.map((step, index) => {
      return [
        `<div class="stream-step">`,
        `<div class="stream-index">${index + 1}</div>`,
        `<div class="stream-content">`,
        `<div class="stream-title">${escHtml(step.title)}</div>`,
        `<div class="stream-note">${escHtml(step.note)}</div>`,
        `<div class="stream-body">${escHtml(step.body)}</div>`,
        `</div>`,
        `</div>`
      ].join("");
    }).join("");

    // Keep latest message visible, GPT/VS-style.
    autopilotSummaryEl.scrollTop = autopilotSummaryEl.scrollHeight;
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

    if (autopilotSummaryEl) {
      autopilotSummaryEl.textContent = hints;
    }
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

  function renderTokens(tokens) {
    const summary = (tokens && tokens.summary) || {};
    const rows = (tokens && tokens.rows) ? tokens.rows.slice(0, 12) : [];
    const table = rows.map(r => {
      return [
        (r.task_id || "").padEnd(12, " "),
        String(asNum(r.ollama_total)).padStart(7, " "),
        String(asNum(r.vs_total)).padStart(7, " "),
        String(asNum(r.total_tokens)).padStart(8, " ")
      ].join(" | ");
    });

    tokenPanelEl.textContent = [
      "Token counters (cost-down cockpit)",
      "- source: " + ((tokens && tokens.source) || "n/a"),
      "- tasks_tracked: " + (summary.tasks_tracked || 0),
      "- ollama_tokens_total: " + (summary.ollama_tokens_total || 0),
      "- vs_tokens_total: " + (summary.vs_tokens_total || 0),
      "- all_tokens_total: " + (summary.all_tokens_total || 0),
      "- estimated_cost_usd_total: " + (summary.estimated_cost_usd_total || 0),
      "",
      "task_id      | ollama |      vs |    total",
      "--------------------------------------------",
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

    if (mode === "full") {
      renderTokens(tokens);
    }

    if (forceLlm) {
      try {
        const llm = await fetchJson("/api/llm/health");
        renderOllama(runtime, llm);
      } catch (_err) {
        renderOllama(runtime, { status: "offline", source_key: "n/a" });
      }
    } else {
      renderOllama(runtime, null);
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

  boot();
})();
