(async function main() {
  const cfg = window.CUSTOMIDE_CONFIG || { backendBaseUrl: "http://127.0.0.1:5555" };
  const refreshIntervalMs = Number(cfg.refreshIntervalMs || 2500);
  const llmRefreshEvery = 5;
  let tick = 0;
  let activeBackendBaseUrl = "";
  let lastErrorText = "";

  const statusEl = document.getElementById("backendStatus");
  const llmBadgeEl = document.getElementById("llmHealthBadge");
  const syncBadgeEl = document.getElementById("syncHealthBadge");
  const lastRefreshEl = document.getElementById("lastRefresh");
  const autopilotSummaryEl = document.getElementById("autopilotSummary");
  const workerLogPanelEl = document.getElementById("workerLogPanel");
  const gitPanelEl = document.getElementById("gitPanel");
  const syncCadencePanelEl = document.getElementById("syncCadencePanel");
  const tokenPanelEl = document.getElementById("tokenPanel");
  const ollamaPanelEl = document.getElementById("ollamaPanel");

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

    autopilotSummaryEl.textContent = hints;
    workerLogPanelEl.textContent = hints;
    gitPanelEl.textContent = hints;
    syncCadencePanelEl.textContent = hints;
    tokenPanelEl.textContent = hints;
    ollamaPanelEl.textContent = hints;
  }

  function renderSync(sync) {
    const err = (sync && sync.sync_error) || "unknown";
    const gate = (sync && sync.heads_match) ? "heads_match" : "heads_diff";
    syncBadgeEl.textContent = "Sync: " + err + " | " + gate;

    gitPanelEl.textContent = [
      "Git sync health",
      "- branch: " + ((sync && sync.branch) || "unknown"),
      "- local_head: " + ((sync && sync.local_head_short) || "unknown"),
      "- origin_head: " + ((sync && sync.origin_head_short) || "unknown"),
      "- heads_match: " + (((sync && sync.heads_match) ? "yes" : "no")),
      "- working_tree: " + ((sync && sync.working_tree) || "unknown"),
      "- sync_error: " + err,
      "- source: " + ((sync && sync.sync_error_source) || "n/a"),
      "- reported_at_utc: " + ((sync && sync.reported_at_utc) || "n/a")
    ].join("\n");
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
    autopilotSummaryEl.textContent = [
      "Worker summary",
      "- worker: " + ((worker && worker.worker_id) || "n/a"),
      "- mode: " + ((worker && worker.mode) || "unknown"),
      "- last_run_local: " + ((worker && worker.last_run_local) || "n/a"),
      "- stale_seconds: " + ((worker && typeof worker.stale_seconds === "number") ? worker.stale_seconds : "n/a"),
      "- last_task: " + ((worker && worker.last_task_processed) || ""),
      "- note: " + ((worker && worker.note) || ""),
      "- status_source: " + ((worker && worker.status_source) || "n/a"),
      "- events_source: " + ((worker && worker.events_source) || "n/a")
    ].join("\n");

    workerLogPanelEl.textContent = events.length ? events.join("\n") : "(no events)";
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
      "Inference policy",
      "- mode: " + (costMode.inference_policy || "ollama_local_first"),
      "- note: " + (costMode.notes || "Prefer local Ollama for low cost."),
      "- llm_status: " + llmStatus,
      "- llm_source: " + source,
      "- refresh_interval_ms: " + refreshIntervalMs
    ].join("\n");
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

  async function refreshAll(forceLlm) {
    const bundle = await fetchJson("/api/status/bundle");
    const runtime = bundle.runtime || {};
    const sync = bundle.sync_health || {};
    const cadence = bundle.sync_cadence || {};
    const worker = bundle.worker_log || {};
    const tokens = bundle.token_counters || {};

    setBackendStatus(true, "bundle ok");
    renderSync(sync);
    renderCadence(cadence);
    renderWorkerLog(worker);
    renderTokens(tokens);

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
    await discoverBackend();
    try {
      await refreshAll(true);
      setBackendStatus(true, "endpoint: " + activeBackendBaseUrl);
    } catch (err) {
      lastErrorText = String(err);
      const fallbackOk = await refreshFromLocalFiles();
      if (fallbackOk) {
        setBackendStatus(false, "snapshot mode | backend down");
      } else {
        setBackendStatus(false, (activeBackendBaseUrl || "none") + " | " + lastErrorText);
        renderDisconnected(lastErrorText);
      }
    }

    setInterval(async () => {
      if (document.hidden) return;
      tick += 1;
      const forceLlm = (tick % llmRefreshEvery) === 0;
      try {
        await refreshAll(forceLlm);
        setBackendStatus(true, "endpoint: " + activeBackendBaseUrl);
      } catch (err) {
        lastErrorText = String(err);
        activeBackendBaseUrl = "";
        await discoverBackend();
        const fallbackOk = await refreshFromLocalFiles();
        if (fallbackOk) {
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
