(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");
  const outputEl = document.getElementById("execOutput");
  const dashboardEl = document.getElementById("dashboard");

  const btnRefresh = document.getElementById("btnRefreshStatus");
  const btnLocal = document.getElementById("btnRunLocal");
  const btnRemote = document.getElementById("btnRunRemote");

  const localInput = document.getElementById("localCommand");
  const remoteInput = document.getElementById("remoteCommand");

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

  btnRefresh.addEventListener("click", async () => {
    try {
      setBusy(true, "Refreshing status...");
      await fetchRuntimeStatus();
      await checkBackend();
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
      await checkBackend();
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
      await checkBackend();
    } catch (err) {
      outputEl.textContent = "remote run failed: " + err;
    } finally {
      setBusy(false);
    }
  });

  const backendOk = await checkBackend();
  if (backendOk) {
    try {
      await fetchRuntimeStatus();
    } catch (err) {
      outputEl.textContent = "status bootstrap failed: " + err;
    }
  } else {
    statusEl.textContent += " | Run pilot_v1/customide/scripts/start_local_stack.sh";
  }
})();
