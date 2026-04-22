(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");
  const outputEl = document.getElementById("execOutput");
  const btnLocal = document.getElementById("btnRunLocal");
  const btnRemote = document.getElementById("btnRunRemote");

  const cfg = window.CUSTOMIDE_CONFIG || {
    backendBaseUrl: "http://127.0.0.1:5555",
    workerServicesPath: "../../config/worker1_services.json"
  };

  async function checkBackend() {
    try {
      const res = await fetch(cfg.backendBaseUrl + "/health");
      if (!res.ok) throw new Error("health failed");
      const data = await res.json();
      statusEl.textContent = "Backend: " + (data.status || "ok");
    } catch (_err) {
      statusEl.textContent = "Backend: offline (start uvicorn on :5555)";
    }
  }

  async function resolveRemoteUrl() {
    try {
      const res = await fetch(cfg.workerServicesPath);
      if (!res.ok) throw new Error("services json fetch failed");
      const data = await res.json();
      const candidates = [
        data.code_server_url,
        data.codeserver_url,
        data.code_server,
        data.services && data.services.code_server_url,
        data.services && data.services.codeserver_url
      ];
      const url = candidates.find((v) => typeof v === "string" && v.trim().length > 0);
      if (url) {
        remoteFrame.src = url;
        return true;
      }
    } catch (_err) {
      // keep fallback below
    }

    remoteFrame.src = "about:blank";
    return false;
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

  await checkBackend();
  const remoteOk = await resolveRemoteUrl();
  if (!remoteOk) {
    statusEl.textContent += " | Remote: waiting for code-server URL";
  }
})();
