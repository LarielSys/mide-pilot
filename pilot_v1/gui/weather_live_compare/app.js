const apiBaseEl = document.getElementById("apiBase");
const cityAEl = document.getElementById("cityA");
const cityBEl = document.getElementById("cityB");
const unitsEl = document.getElementById("units");
const healthStatusEl = document.getElementById("healthStatus");
const outputEl = document.getElementById("output");

const healthBtn = document.getElementById("healthBtn");
const compareBtn = document.getElementById("compareBtn");

function normalizeBase(url) {
  return url.trim().replace(/\/+$/, "");
}

function setHealth(text, ok = null) {
  healthStatusEl.textContent = text;
  healthStatusEl.classList.remove("ok", "err");
  if (ok === true) healthStatusEl.classList.add("ok");
  if (ok === false) healthStatusEl.classList.add("err");
}

async function checkHealth() {
  const base = normalizeBase(apiBaseEl.value);
  setHealth("Health: checking...");
  try {
    const resp = await fetch(`${base}/health`, { method: "GET" });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    setHealth(`Health: ok (${data.worker_id || "worker"})`, true);
  } catch (err) {
    setHealth(`Health: failed (${err.message})`, false);
  }
}

async function compareWeather() {
  const base = normalizeBase(apiBaseEl.value);
  const payload = {
    city_a: cityAEl.value.trim(),
    city_b: cityBEl.value.trim(),
    units: unitsEl.value
  };

  outputEl.textContent = "Waiting for Worker 1 response...";

  try {
    const resp = await fetch(`${base}/compare`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });

    const text = await resp.text();
    if (!resp.ok) {
      outputEl.textContent = `HTTP ${resp.status}\n${text}`;
      return;
    }

    try {
      const json = JSON.parse(text);
      outputEl.textContent = JSON.stringify(json, null, 2);
    } catch {
      outputEl.textContent = text;
    }
  } catch (err) {
    outputEl.textContent = `Request failed: ${err.message}`;
  }
}

healthBtn.addEventListener("click", checkHealth);
compareBtn.addEventListener("click", compareWeather);
