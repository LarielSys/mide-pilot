(async function main() {
  const statusEl = document.getElementById("backendStatus");
  const remoteFrame = document.getElementById("remoteFrame");

  try {
    const res = await fetch("http://127.0.0.1:5555/health");
    if (!res.ok) throw new Error("backend not healthy");
    const d = await res.json();
    statusEl.textContent = "Backend: " + (d.status || "unknown");
  } catch (_err) {
    statusEl.textContent = "Backend: offline (expected until local run)";
  }

  // Placeholder remote URL; MTASK-0039 wires real service config consumption.
  remoteFrame.src = "about:blank";
})();
