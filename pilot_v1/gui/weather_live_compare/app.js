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
  setHealth("Health: checking...");
  try {
    const resp = await fetch("/api/weather/health", { method: "GET" });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    setHealth(`Health: ok (${data.worker_id || "worker"})`, true);
  } catch (err) {
    setHealth(`Health: failed (${err.message})`, false);
  }
}

async function compareWeather() {
  const payload = {
    city_a: cityAEl.value.trim(),
    city_b: cityBEl.value.trim(),
    units: unitsEl.value
  };

  outputEl.textContent = "Waiting for Worker 1 response...";

  try {
    const resp = await fetch("/api/weather/compare", {
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
      const d = JSON.parse(text);
      outputEl.innerHTML = renderComparison(d);
    } catch {
      outputEl.textContent = text;
    }
  } catch (err) {
    outputEl.textContent = `Request failed: ${err.message}`;
  }
}

function conditionLabel(code) {
  const map = { "0": "Clear", "1": "Mainly Clear", "2": "Partly Cloudy", "3": "Overcast",
    "45": "Foggy", "48": "Icy Fog", "51": "Light Drizzle", "53": "Drizzle", "55": "Heavy Drizzle",
    "61": "Light Rain", "63": "Rain", "65": "Heavy Rain", "71": "Light Snow", "73": "Snow",
    "75": "Heavy Snow", "80": "Showers", "81": "Heavy Showers", "95": "Thunderstorm" };
  return map[String(code)] || `Code ${code}`;
}

function renderComparison(d) {
  const a = d.city_a, b = d.city_b, c = d.comparison;
  const units = unitsEl.value === "imperial" ? { temp: "°F", wind: "mph" } : { temp: "°C", wind: "km/h" };
  const delta = (val, unit) => val > 0
    ? `<span class="delta pos">+${val} ${unit}</span>`
    : `<span class="delta neg">${val} ${unit}</span>`;

  return `
    <div class="compare-grid">
      <div class="city-card">
        <div class="city-name">${a.name}</div>
        <div class="temp">${a.temp_c}${units.temp}</div>
        <div class="meta">${conditionLabel(a.condition)}</div>
        <div class="meta">Humidity: ${a.humidity_pct}%</div>
        <div class="meta">Wind: ${a.wind_kph} ${units.wind}</div>
      </div>
      <div class="vs">VS</div>
      <div class="city-card">
        <div class="city-name">${b.name}</div>
        <div class="temp">${b.temp_c}${units.temp}</div>
        <div class="meta">${conditionLabel(b.condition)}</div>
        <div class="meta">Humidity: ${b.humidity_pct}%</div>
        <div class="meta">Wind: ${b.wind_kph} ${units.wind}</div>
      </div>
    </div>
    <div class="deltas">
      <div class="delta-row">Temperature difference: ${delta(c.temp_delta_c, units.temp)}</div>
      <div class="delta-row">Humidity difference: ${delta(c.humidity_delta_pct, "%")}</div>
      <div class="delta-row">Wind difference: ${delta(c.wind_delta_kph, units.wind)}</div>
      <div class="delta-row summary">${c.summary}</div>
    </div>`;
}

healthBtn.addEventListener("click", checkHealth);
compareBtn.addEventListener("click", compareWeather);
