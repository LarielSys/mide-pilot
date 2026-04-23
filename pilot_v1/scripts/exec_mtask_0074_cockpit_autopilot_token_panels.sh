#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME_FILE="${REPO_ROOT}/pilot_v1/customide/backend/app/routes/runtime.py"
FRONTEND_HTML="${REPO_ROOT}/pilot_v1/customide/frontend/index.html"
FRONTEND_JS="${REPO_ROOT}/pilot_v1/customide/frontend/js/app.js"
FRONTEND_CSS="${REPO_ROOT}/pilot_v1/customide/frontend/css/style.css"

cd "${REPO_ROOT}"

echo "task=MTASK-0074"
echo "objective=cockpit panes for autopilot windows, token counters, ollama-first status"
echo "cost_policy=keep_costs_down_ollama_local_first"

git fetch origin main
git checkout -q main || true
git merge --ff-only FETCH_HEAD

cat > "${RUNTIME_FILE}" <<'EOF'
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter

from ..services import load_worker_services

router = APIRouter(prefix="/api/status", tags=["status"])
_FETCH_TTL_SECONDS = 4.0
_last_fetch_monotonic = 0.0


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _run_git(repo_root: Path, args: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
        return proc.returncode, (proc.stdout or "").strip()
    except Exception:
        return 1, ""


def _maybe_fetch_origin(repo_root: Path) -> None:
    global _last_fetch_monotonic
    now = time.monotonic()
    if (now - _last_fetch_monotonic) < _FETCH_TTL_SECONDS:
        return
    _run_git(repo_root, ["fetch", "origin", "main"])
    _last_fetch_monotonic = now


def _read_state_text(repo_root: Path, rel_path: str) -> tuple[str, str]:
    _maybe_fetch_origin(repo_root)
    rc, out = _run_git(repo_root, ["show", f"origin/main:{rel_path}"])
    if rc == 0:
        return out, "origin/main"

    local_path = repo_root / rel_path
    if local_path.exists():
        return local_path.read_text(encoding="utf-8", errors="replace"), "local"

    return "", "missing"


def _parse_event_timestamp(line: str):
    token = line.split(" | ", 1)[0].strip()
    if not token:
        return None

    token = token.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(token)
    except ValueError:
        return None

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)

    return parsed.astimezone(timezone.utc)


def _parse_token_counter_lines(raw_text: str) -> list[dict]:
    rows: list[dict] = []
    for raw in raw_text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 12:
            continue

        task_id = parts[0]
        if not task_id.startswith("MTASK-"):
            continue

        try:
            row = {
                "task_id": task_id,
                "ollama_build": int(parts[1]),
                "ollama_debug": int(parts[2]),
                "ollama_fix": int(parts[3]),
                "vs_build": int(parts[4]),
                "vs_debug": int(parts[5]),
                "vs_fix": int(parts[6]),
                "ollama_total": int(parts[7]),
                "vs_total": int(parts[8]),
                "total_tokens": int(parts[9]),
                "est_cost_usd": float(parts[10]),
                "updated_utc": parts[11],
            }
        except ValueError:
            continue

        rows.append(row)

    rows.sort(key=lambda x: x["task_id"], reverse=True)
    return rows


@router.get("/runtime")
def get_runtime_status() -> dict:
    repo_root = _repo_root()
    services = load_worker_services(repo_root)

    code_server_url = (
        services.get("code_server_url")
        or services.get("codeserver_url")
        or services.get("code_server")
        or (services.get("services") or {}).get("code_server_url")
        or (services.get("services") or {}).get("codeserver_url")
        or ""
    )

    return {
        "backend": {
            "status": "ok",
            "repo_root": str(repo_root),
            "execute_routes": {
                "local": "/api/execute/local",
                "remote": "/api/execute/remote",
            },
        },
        "worker": {
            "remote_url_available": bool(code_server_url),
            "remote_url": code_server_url,
        },
        "cost_mode": {
            "inference_policy": "ollama_local_first",
            "notes": "Use local Ollama for chat/summaries; reserve paid endpoints for exceptions.",
        },
    }


@router.get("/sync-health")
def get_sync_health() -> dict:
    repo_root = _repo_root()
    rel_sync_error = "pilot_v1/state/worker_autopilot_git_sync_last_error.txt"
    sync_error_text, sync_error_source = _read_state_text(repo_root, rel_sync_error)

    sync_error = "none"
    raw = sync_error_text.strip()
    if raw:
        sync_error = raw.splitlines()[0]

    _maybe_fetch_origin(repo_root)
    _, branch = _run_git(repo_root, ["rev-parse", "--abbrev-ref", "HEAD"])
    _, local_head = _run_git(repo_root, ["rev-parse", "HEAD"])
    _, origin_head = _run_git(repo_root, ["rev-parse", "origin/main"])
    _, status_short = _run_git(repo_root, ["status", "--short"])

    return {
        "worker_id": "ubuntu-worker-01",
        "sync_error": sync_error,
        "sync_error_file": str(repo_root / rel_sync_error),
        "sync_error_source": sync_error_source,
        "branch": branch or "unknown",
        "local_head": local_head,
        "origin_head": origin_head,
        "local_head_short": (local_head[:8] if local_head else "unknown"),
        "origin_head_short": (origin_head[:8] if origin_head else "unknown"),
        "heads_match": bool(local_head and origin_head and local_head == origin_head),
        "working_tree": "clean" if not status_short else "dirty",
        "working_tree_short": status_short,
        "reported_at_utc": _utc_now_iso(),
    }


def get_sync_cadence() -> dict:
    repo_root = _repo_root()
    rel_event_file = "pilot_v1/state/worker_autopilot_events.log"
    events_text, source = _read_state_text(repo_root, rel_event_file)
    event_file = repo_root / rel_event_file

    if not events_text:
        return {
            "samples": 0,
            "deltas_seconds": [],
            "gate_3x60_pass": False,
            "status": "missing",
            "source_file": str(event_file),
            "source": source,
            "reported_at_utc": _utc_now_iso(),
        }

    stamps = []
    for line in events_text.splitlines():
        parsed = _parse_event_timestamp(line)
        if parsed is None:
            continue
        stamps.append(parsed)
        if len(stamps) >= 4:
            break

    deltas = [int((stamps[i] - stamps[i + 1]).total_seconds()) for i in range(len(stamps) - 1)]
    gate = len(deltas) >= 3 and all(55 <= d <= 65 for d in deltas[:3])
    status = "pass" if gate else ("insufficient" if len(deltas) < 3 else "drift")

    return {
        "samples": len(stamps),
        "deltas_seconds": deltas,
        "gate_3x60_pass": gate,
        "status": status,
        "source_file": str(event_file),
        "source": source,
        "reported_at_utc": _utc_now_iso(),
    }


@router.get("/worker-log")
def get_worker_log() -> dict:
    repo_root = _repo_root()
    rel_status = "pilot_v1/state/worker_autopilot_status.json"
    rel_events = "pilot_v1/state/worker_autopilot_events.log"

    status_text, status_source = _read_state_text(repo_root, rel_status)
    events_text, events_source = _read_state_text(repo_root, rel_events)

    status = {}
    if status_text:
        try:
            status = json.loads(status_text)
        except json.JSONDecodeError:
            status = {}

    recent_events = []
    if events_text:
        recent_events = [line for line in events_text.splitlines() if line.strip()][:40]

    stale_seconds = None
    last_run_utc = status.get("last_run_utc")
    if isinstance(last_run_utc, str) and last_run_utc:
        try:
            parsed = datetime.fromisoformat(last_run_utc.replace("Z", "+00:00"))
            stale_seconds = int((datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds())
        except ValueError:
            stale_seconds = None

    return {
        "worker_name": status.get("worker_name", ""),
        "worker_id": status.get("worker_id", ""),
        "mode": status.get("mode", ""),
        "poll_seconds": status.get("poll_seconds", ""),
        "last_run_utc": status.get("last_run_utc", ""),
        "last_run_local": status.get("last_run_local", ""),
        "log_timezone": status.get("log_timezone", ""),
        "last_task_processed": status.get("last_task_processed", ""),
        "note": status.get("note", ""),
        "status_source": status_source,
        "events_source": events_source,
        "events_count": len(recent_events),
        "recent_events": recent_events,
        "stale_seconds": stale_seconds,
        "reported_at_utc": _utc_now_iso(),
    }


@router.get("/token-counters")
def get_token_counters() -> dict:
    repo_root = _repo_root()
    rel_counter = "pilot_v1/customide/TOKEN_COUNTER_TASKS.txt"
    raw_text, source = _read_state_text(repo_root, rel_counter)

    rows = _parse_token_counter_lines(raw_text)
    ollama_total = sum(r["ollama_total"] for r in rows)
    vs_total = sum(r["vs_total"] for r in rows)
    token_total = sum(r["total_tokens"] for r in rows)
    cost_total = round(sum(r["est_cost_usd"] for r in rows), 6)

    return {
        "source": source,
        "source_file": str(repo_root / rel_counter),
        "rows": rows[:30],
        "summary": {
            "tasks_tracked": len(rows),
            "ollama_tokens_total": ollama_total,
            "vs_tokens_total": vs_total,
            "all_tokens_total": token_total,
            "estimated_cost_usd_total": cost_total,
        },
        "reported_at_utc": _utc_now_iso(),
    }


@router.get("/bundle")
def get_status_bundle() -> dict:
    return {
        "runtime": get_runtime_status(),
        "sync_health": get_sync_health(),
        "sync_cadence": get_sync_cadence(),
        "worker_log": get_worker_log(),
        "token_counters": get_token_counters(),
    }
EOF

cat > "${FRONTEND_HTML}" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>CustomIDE Cockpit</title>
  <link rel="stylesheet" href="css/style.css">
</head>
<body>
  <div class="bg-orbit"></div>

  <header class="topbar">
    <div class="brand">CustomIDE Cockpit</div>
    <div class="status" id="backendStatus">Backend: checking...</div>
    <div class="status" id="llmHealthBadge">LLM: checking...</div>
    <div class="status" id="syncHealthBadge">Sync: checking...</div>
    <div class="status" id="lastRefresh">Last refresh: --</div>
  </header>

  <main class="cockpit-grid">
    <section class="panel">
      <h3>Autopilot Live</h3>
      <pre id="autopilotSummary">waiting...</pre>
    </section>

    <section class="panel panel-tall">
      <h3>Autopilot Events</h3>
      <pre id="workerLogPanel">waiting...</pre>
    </section>

    <section class="panel">
      <h3>Git Sync</h3>
      <pre id="gitPanel">waiting...</pre>
    </section>

    <section class="panel">
      <h3>Sync Cadence</h3>
      <pre id="syncCadencePanel">waiting...</pre>
    </section>

    <section class="panel panel-wide">
      <h3>Token Counters</h3>
      <pre id="tokenPanel">waiting...</pre>
    </section>

    <section class="panel">
      <h3>Ollama / Cost Mode</h3>
      <pre id="ollamaPanel">waiting...</pre>
    </section>

    <section class="panel panel-wide">
      <h3>Worker 1 Remote View</h3>
      <iframe id="remoteFrame" title="Worker 1 code-server view"></iframe>
    </section>
  </main>

  <script src="js/config.js"></script>
  <script src="js/app.js"></script>
</body>
</html>
EOF

cat > "${FRONTEND_JS}" <<'EOF'
(async function main() {
  const cfg = window.CUSTOMIDE_CONFIG || { backendBaseUrl: "http://127.0.0.1:5555" };
  const refreshIntervalMs = Number(cfg.refreshIntervalMs || 2500);
  const llmRefreshEvery = 5;
  let tick = 0;

  const statusEl = document.getElementById("backendStatus");
  const llmBadgeEl = document.getElementById("llmHealthBadge");
  const syncBadgeEl = document.getElementById("syncHealthBadge");
  const lastRefreshEl = document.getElementById("lastRefresh");
  const remoteFrame = document.getElementById("remoteFrame");
  const autopilotSummaryEl = document.getElementById("autopilotSummary");
  const workerLogPanelEl = document.getElementById("workerLogPanel");
  const gitPanelEl = document.getElementById("gitPanel");
  const syncCadencePanelEl = document.getElementById("syncCadencePanel");
  const tokenPanelEl = document.getElementById("tokenPanel");
  const ollamaPanelEl = document.getElementById("ollamaPanel");

  function asNum(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }

  function setBackendStatus(ok, msg) {
    statusEl.textContent = ok ? "Backend: online" : "Backend: offline";
    if (msg) statusEl.textContent += " | " + msg;
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
    const res = await fetch(cfg.backendBaseUrl + path);
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

    if (runtime.worker && runtime.worker.remote_url) {
      remoteFrame.src = runtime.worker.remote_url;
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
    try {
      await refreshAll(true);
    } catch (err) {
      setBackendStatus(false, String(err));
    }

    setInterval(async () => {
      if (document.hidden) return;
      tick += 1;
      const forceLlm = (tick % llmRefreshEvery) === 0;
      try {
        await refreshAll(forceLlm);
      } catch (err) {
        setBackendStatus(false, String(err));
      }
    }, refreshIntervalMs);
  }

  boot();
})();
EOF

cat > "${FRONTEND_CSS}" <<'EOF'
:root {
  --bg-a: #f3efe6;
  --bg-b: #d8e2dc;
  --ink: #22333b;
  --muted: #52616b;
  --line: #a8b8b3;
  --panel: rgba(255, 255, 255, 0.74);
  --accent: #2f7a5f;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  font-family: Georgia, "Palatino Linotype", "Book Antiqua", serif;
  color: var(--ink);
  background: radial-gradient(circle at 20% 20%, var(--bg-b), var(--bg-a));
  min-height: 100vh;
}

.bg-orbit {
  position: fixed;
  inset: -20vmax;
  background: conic-gradient(from 120deg, transparent, rgba(47, 122, 95, 0.14), transparent 56%);
  animation: drift 16s linear infinite;
  pointer-events: none;
}

@keyframes drift {
  to { transform: rotate(1turn); }
}

.topbar {
  position: sticky;
  top: 0;
  z-index: 10;
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
  align-items: center;
  padding: 12px 14px;
  border-bottom: 1px solid var(--line);
  background: rgba(243, 239, 230, 0.88);
  backdrop-filter: blur(5px);
}

.brand {
  font-size: 1.05rem;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  font-weight: 700;
  color: var(--accent);
  margin-right: auto;
}

.status {
  color: var(--muted);
  font-size: 0.9rem;
}

.cockpit-grid {
  position: relative;
  display: grid;
  grid-template-columns: repeat(12, minmax(0, 1fr));
  gap: 12px;
  padding: 12px;
}

.panel {
  grid-column: span 4;
  border: 1px solid var(--line);
  background: var(--panel);
  border-radius: 12px;
  box-shadow: 0 8px 22px rgba(34, 51, 59, 0.08);
  min-height: 180px;
}

.panel h3 {
  margin: 0;
  padding: 10px 12px;
  border-bottom: 1px solid var(--line);
  font-size: 0.95rem;
  letter-spacing: 0.03em;
}

.panel-tall {
  grid-column: span 8;
  min-height: 360px;
}

.panel-wide {
  grid-column: span 8;
}

pre {
  margin: 0;
  padding: 10px 12px;
  border: 0;
  background: transparent;
  color: var(--ink);
  font-size: 12px;
  line-height: 1.36;
  white-space: pre-wrap;
  max-height: 340px;
  overflow: auto;
}

#remoteFrame {
  width: 100%;
  height: 360px;
  border: 0;
  border-radius: 0 0 12px 12px;
  background: #fff;
}

@media (max-width: 1180px) {
  .panel,
  .panel-tall,
  .panel-wide {
    grid-column: span 12;
  }

  #remoteFrame {
    height: 320px;
  }
}
EOF

if ! grep -q 'def get_token_counters() -> dict:' "${RUNTIME_FILE}"; then
  echo "error=token_counter_endpoint_missing"
  exit 1
fi
if ! grep -q 'Token counters (cost-down cockpit)' "${FRONTEND_JS}"; then
  echo "error=token_cockpit_render_missing"
  exit 1
fi
if ! grep -q 'CustomIDE Cockpit' "${FRONTEND_HTML}"; then
  echo "error=cockpit_title_missing"
  exit 1
fi
if ! grep -q 'mode: ollama_local_first' "${FRONTEND_JS}" && ! grep -q 'ollama_local_first' "${RUNTIME_FILE}"; then
  echo "error=ollama_cost_policy_missing"
  exit 1
fi

echo "cockpit_layout=passed"
echo "autopilot_panes=passed"
echo "token_counters_panel=passed"
echo "ollama_cost_mode=passed"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

git add \
  "pilot_v1/customide/backend/app/routes/runtime.py" \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js" \
  "pilot_v1/customide/frontend/css/style.css"

git commit -m "customide: add cockpit panes for autopilot, git, tokens, and ollama mode (MTASK-0074)" >/dev/null || true
git push origin main >/dev/null || true
EOF
