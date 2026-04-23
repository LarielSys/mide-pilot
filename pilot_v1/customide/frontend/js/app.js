(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");
  const outputEl = document.getElementById("execOutput");
  const dashboardEl = document.getElementById("dashboard");
  const btnRefresh = document.getElementById("btnRefreshStatus");
  const btnLocal = document.getElementById("btnRunLocal");
  const btnRemote = document.getElementById("btnRunRemote");

  const cfg = window.CUSTOMIDE_CONFIG || {
    backendBaseUrl: "http://127.0.0.1:5555",
    workerServicesPath: "../../config/worker1_services.json"
  };

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
    try {
      const res = await fetch(cfg.backendBaseUrl + "/api/status/runtime");
      if (!res.ok) throw new Error("runtime status failed");
      const data = await res.json();
      renderDashboard(data);

      if (data.worker && data.worker.remote_url) {
        remoteFrame.src = data.worker.remote_url;
      }

      return data;
    } catch (_err) {
      renderDashboard({
        backend: { status: "offline", execute_routes: {} },
        worker: { remote_url_available: false, remote_url: "" }
      });
      return null;
    }
  }

  async function runLocal() {
    const payload = {
      command: "echo local-ok",
      cwd: "."
    };
    const res = await fetch(cfg.backendBaseUrl + "/api/execute/local", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    outputEl.textContent = JSON.stringify(data, null, 2);
  }

  async function runRemote() {
    const payload = {
      command: "echo remote-ok",
      host: "127.0.0.1",
      user: "invalid-user"
    };
    const res = await fetch(cfg.backendBaseUrl + "/api/execute/remote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    outputEl.textContent = JSON.stringify(data, null, 2);
  }

  btnRefresh.addEventListener("click", () => {
    fetchRuntimeStatus().catch((err) => {
      outputEl.textContent = "status refresh failed: " + err;
    });
  });

  btnLocal.addEventListener("click", () => {
    runLocal().catch((err) => {
      outputEl.textContent = "local run failed: " + err;
    });
  });

  btnRemote.addEventListener("click", () => {
    runRemote().catch((err) => {
      outputEl.textContent = "remote run failed: " + err;
    });
  });

  const backendOk = await checkBackend();
  await fetchRuntimeStatus();
  if (!backendOk) {
    statusEl.textContent += " | Run pilot_v1/customide/scripts/start_local_stack.sh";
  }
})();
