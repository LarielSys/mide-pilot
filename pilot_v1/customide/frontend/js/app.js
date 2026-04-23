(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");
  const outputEl = document.getElementById("execOutput");
  const dashboardEl = document.getElementById("dashboard");
  const llmBadgeEl = document.getElementById("llmHealthBadge");
  const syncBadgeEl = document.getElementById("syncHealthBadge");
  const syncDebugPanelEl = document.getElementById("syncDebugPanel");
  const syncCadencePanelEl = document.getElementById("syncCadencePanel");

  function renderLlmBadge(data) {
    if (!llmBadgeEl) return;
    const status = (data && data.status) || "unknown";
    const source = (data && data.source_key) || "n/a";
    llmBadgeEl.textContent = "LLM: " + status + " | source: " + source;
  }

  function renderSyncCadence(data) {
    if (!syncCadencePanelEl) return;
    const deltas = (data && data.deltas_seconds) ? data.deltas_seconds.join(", ") : "n/a";
    const gate = (data && data.gate_3x60_pass) ? "pass" : "pending";
    const status = (data && data.status) || "unknown";
    syncCadencePanelEl.textContent = "Sync cadence\n- deltas_seconds: " + deltas + "\n- gate_3x60_pass: " + gate + "\n- status: " + status;
  }

  function renderSyncBadge(data) {
    if (syncDebugPanelEl) {
      const syncError = (data && data.sync_error) || "unknown";
      const syncFile = (data && data.sync_error_file) || "n/a";
      syncDebugPanelEl.textContent = "Sync debug\n- sync_error: " + syncError + "\n- sync_error_file: " + syncFile;
    }
    if (!syncBadgeEl) return;
    const value = (data && data.sync_error) || "unknown";
    syncBadgeEl.textContent = "Sync: " + value;
  }

  async function fetchStatusBundle() {
    const res = await fetch(cfg.backendBaseUrl + "/api/status/bundle");
    if (!res.ok) throw new Error("status bundle failed");
    return await res.json();
  }

  async function refreshSyncHealth() {
    const res = await fetch(cfg.backendBaseUrl + "/api/status/sync-health");
    if (!res.ok) throw new Error("sync health failed");
    const data = await res.json();
    renderSyncBadge(data);
    return data;
  }

  async function refreshFromBundle() {
    const bundle = await fetchStatusBundle();
    if (bundle && bundle.runtime) renderDashboard(bundle.runtime);
    if (bundle && bundle.runtime && bundle.runtime.worker && bundle.runtime.worker.remote_url) {
      remoteFrame.src = bundle.runtime.worker.remote_url;
    }
    if (bundle && bundle.sync_health) renderSyncBadge(bundle.sync_health);
    if (bundle && bundle.sync_cadence) renderSyncCadence(bundle.sync_cadence);
    return bundle;
  }

  async function refreshLlmHealth() {
    const res = await fetch(cfg.backendBaseUrl + "/api/llm/health");
    if (!res.ok) throw new Error("llm health failed");
    const data = await res.json();
    renderLlmBadge(data);
    return data;
  }

  const btnRefresh = document.getElementById("btnRefreshStatus");
  const btnLocal = document.getElementById("btnRunLocal");
  const btnRemote = document.getElementById("btnRunRemote");
  const btnAskLocalLLM = document.getElementById("btnAskLocalLLM");
  const btnAskRemoteLLM = document.getElementById("btnAskRemoteLLM");

  const localInput = document.getElementById("localCommand");
  const remoteInput = document.getElementById("remoteCommand");
  const sharedPrompt = document.getElementById("sharedPrompt");

  const cfg = window.CUSTOMIDE_CONFIG || {
    backendBaseUrl: "http://127.0.0.1:5555",
  };

  function renderJson(data) {
    outputEl.textContent = JSON.stringify(data, null, 2);
  }

  function setBusy(isBusy, label) {
    btnLocal.disabled = isBusy;
    btnRemote.disabled = isBusy;
    btnRefresh.disabled = isBusy;
    btnAskLocalLLM.disabled = isBusy;
    btnAskRemoteLLM.disabled = isBusy;
    if (isBusy) {
      statusEl.textContent = label || "Running...";
    }
  }

  function renderDashboard(data) {
    const remote = data && data.worker ? data.worker : {};
    const backend = data && data.backend ? data.backend : {};
    const remoteUrl = remote.remote_url || "(not available yet)";

    dashboardEl.textContent = [
      "Runtime Dashboard",
      "- Backend: " + (backend.status || "unknown"),
      "- Local execute: " + ((backend.execute_routes || {}).local || "missing"),
      "- Remote execute: " + ((backend.execute_routes || {}).remote || "missing"),
      "- Shared LLM: /api/llm/chat",
      "- Remote URL available: " + (remote.remote_url_available ? "yes" : "no"),
      "- Remote URL: " + remoteUrl
    ].join("\n");
  }

  async function checkBackend() {
    try {
      const res = await fetch(cfg.backendBaseUrl + "/health");
      if (!res.ok) throw new Error("health failed");
      const data = await res.json();
      statusEl.textContent = "Backend: " + (data.status || "ok");
      return true;
    } catch (_err) {
      statusEl.textContent = "Backend: offline (start uvicorn on :5555)";
      return false;
    }
  }

  async function fetchRuntimeStatus() {
    const res = await fetch(cfg.backendBaseUrl + "/api/status/runtime");
    if (!res.ok) {
      throw new Error("runtime status failed");
    }

    const data = await res.json();
    renderDashboard(data);

    if (data.worker && data.worker.remote_url) {
      remoteFrame.src = data.worker.remote_url;
    }

    return data;
  }

  async function runLocal() {
    const payload = {
      command: localInput.value.trim(),
      cwd: ".",
      timeout_seconds: 20,
    };

    if (!payload.command) {
      throw new Error("Local command is empty");
    }

    const res = await fetch(cfg.backendBaseUrl + "/api/execute/local", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.detail || "Local execution failed");
    }

    renderJson(data);
  }

  async function runRemote() {
    const payload = {
      command: remoteInput.value.trim(),
      use_worker_config: true,
      timeout_seconds: 25,
    };

    if (!payload.command) {
      throw new Error("Remote command is empty");
    }

    const res = await fetch(cfg.backendBaseUrl + "/api/execute/remote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.detail || "Remote execution failed");
    }

    renderJson(data);
  }

  async function askSharedLlm(source) {
    const prompt = sharedPrompt.value.trim();
    if (!prompt) {
      throw new Error("Shared prompt is empty");
    }

    const res = await fetch(cfg.backendBaseUrl + "/api/llm/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt, source }),
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.detail || "Shared LLM call failed");
    }

    renderJson(data);
  }

  btnRefresh.addEventListener("click", async () => {
    try {
      setBusy(true, "Refreshing status...");
      const bundle = await fetchStatusBundle();
      if (bundle && bundle.runtime) renderDashboard(bundle.runtime);
      if (bundle && bundle.runtime && bundle.runtime.worker && bundle.runtime.worker.remote_url) {
        remoteFrame.src = bundle.runtime.worker.remote_url;
      }
      if (bundle && bundle.sync_health) renderSyncBadge(bundle.sync_health);
      await checkBackend();
      await refreshLlmHealth();
      await refreshSyncHealth();
    } catch (err) {
      outputEl.textContent = "status refresh failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  btnLocal.addEventListener("click", async () => {
    try {
      setBusy(true, "Running local command...");
      await runLocal();
      await refreshFromBundle();
      await checkBackend();
      await refreshLlmHealth();
    } catch (err) {
      outputEl.textContent = "local run failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  btnRemote.addEventListener("click", async () => {
    try {
      setBusy(true, "Running remote command...");
      await runRemote();
      await refreshFromBundle();
      await checkBackend();
      await refreshLlmHealth();
    } catch (err) {
      outputEl.textContent = "remote run failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  btnAskLocalLLM.addEventListener("click", async () => {
    try {
      setBusy(true, "Asking shared LLM from local IDE...");
      await askSharedLlm("local-ide");
      await refreshFromBundle();
      await checkBackend();
      await refreshLlmHealth();
    } catch (err) {
      outputEl.textContent = "shared llm local failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  btnAskRemoteLLM.addEventListener("click", async () => {
    try {
      setBusy(true, "Asking shared LLM from remote IDE...");
      await askSharedLlm("remote-ide");
      await refreshFromBundle();
      await checkBackend();
      await refreshLlmHealth();
    } catch (err) {
      outputEl.textContent = "shared llm remote failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  const backendOk = await checkBackend();
  if (backendOk) {
    try {
      await refreshFromBundle();
      await refreshLlmHealth();
    } catch (err) {
      outputEl.textContent = "status bootstrap failed: " + err;
    }
  } else {
    statusEl.textContent += " | Run pilot_v1/customide/scripts/start_local_stack.sh";
  }
})();
