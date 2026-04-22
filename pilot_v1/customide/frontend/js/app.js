(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");

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

  await checkBackend();
  const remoteOk = await resolveRemoteUrl();
  if (!remoteOk) {
    statusEl.textContent += " | Remote: waiting for code-server URL";
  }
})();
