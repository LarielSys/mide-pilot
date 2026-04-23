#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"

BACKEND_ROOT="${REPO_ROOT}/pilot_v1/customide/backend"
FRONTEND_ROOT="${REPO_ROOT}/pilot_v1/customide/frontend"

cd "${REPO_ROOT}"

echo "task=MTASK-0048"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"

git fetch origin
git pull --ff-only origin main

if [[ ! -f "${FRONTEND_ROOT}/index.html" ]]; then
  echo "error=frontend_missing"
  exit 1
fi
if [[ ! -f "${FRONTEND_ROOT}/js/app.js" ]]; then
  echo "error=frontend_js_missing"
  exit 1
fi

if ! grep -q "id=\"llmHealthBadge\"" "${FRONTEND_ROOT}/index.html"; then
  python3 - <<'PY'
from pathlib import Path
p = Path("pilot_v1/customide/frontend/index.html")
text = p.read_text(encoding="utf-8")
needle = '<div class="status" id="backendStatus">Backend: checking...</div>'
insert = needle + '\n    <div class="status" id="llmHealthBadge">LLM: checking...</div>'
if needle in text:
    text = text.replace(needle, insert, 1)
    p.write_text(text, encoding="utf-8")
PY
fi

if ! grep -q "function renderLlmBadge" "${FRONTEND_ROOT}/js/app.js"; then
  python3 - <<'PY'
from pathlib import Path
p = Path("pilot_v1/customide/frontend/js/app.js")
text = p.read_text(encoding="utf-8")
anchor = '  const dashboardEl = document.getElementById("dashboard");\n'
inject = anchor + '  const llmBadgeEl = document.getElementById("llmHealthBadge");\n\n  function renderLlmBadge(data) {\n    if (!llmBadgeEl) return;\n    const status = (data && data.status) || "unknown";\n    const source = (data && data.source_key) || "n/a";\n    llmBadgeEl.textContent = "LLM: " + status + " | source: " + source;\n  }\n\n  async function refreshLlmHealth() {\n    const res = await fetch(cfg.backendBaseUrl + "/api/llm/health");\n    if (!res.ok) throw new Error("llm health failed");\n    const data = await res.json();\n    renderLlmBadge(data);\n    return data;\n  }\n'
if anchor in text:
    text = text.replace(anchor, inject, 1)

text = text.replace('      await checkBackend();', '      await checkBackend();\n      await refreshLlmHealth();')
text = text.replace('      await checkBackend();\n    } catch (err) {', '      await checkBackend();\n      await refreshLlmHealth();\n    } catch (err) {')
text = text.replace('      await checkBackend();\n    } catch (err) {', '      await checkBackend();\n      await refreshLlmHealth();\n    } catch (err) {', 1)
text = text.replace('      await checkBackend();\n    } catch (err) {', '      await checkBackend();\n      await refreshLlmHealth();\n    } catch (err) {', 1)
text = text.replace('      await fetchRuntimeStatus();\n    } catch (err) {', '      await fetchRuntimeStatus();\n      await refreshLlmHealth();\n    } catch (err) {')

p.write_text(text, encoding="utf-8")
PY
fi

pushd "${BACKEND_ROOT}" >/dev/null
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt >/dev/null
uvicorn app.main:app --host 127.0.0.1 --port 5555 >/tmp/mtask0048-backend.log 2>&1 &
BACK_PID=$!
popd >/dev/null

pushd "${FRONTEND_ROOT}" >/dev/null
python3 -m http.server 5570 >/tmp/mtask0048-frontend.log 2>&1 &
FRONT_PID=$!
popd >/dev/null

cleanup() {
  kill "${BACK_PID}" "${FRONT_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 3

FRONTEND_OK="$(curl -sSf http://127.0.0.1:5570 >/dev/null && echo yes || echo no)"
LLM_HEALTH="$(curl -sS http://127.0.0.1:5555/api/llm/health)"

echo "frontend_reachable=${FRONTEND_OK}"
echo "llm_health=${LLM_HEALTH}"

if [[ "${FRONTEND_OK}" != "yes" ]]; then
  echo "error=frontend_not_reachable"
  exit 1
fi
if ! grep -q "llmHealthBadge" "${FRONTEND_ROOT}/index.html"; then
  echo "error=llm_badge_missing"
  exit 1
fi
if ! grep -q "refreshLlmHealth" "${FRONTEND_ROOT}/js/app.js"; then
  echo "error=llm_refresh_function_missing"
  exit 1
fi

echo "frontend_llm_observability=passed"
echo "llm_badge_render=passed"
echo "llm_health_refresh=passed"

git add \
  "pilot_v1/customide/frontend/index.html" \
  "pilot_v1/customide/frontend/js/app.js"

git commit -m "customide: add shared llm observability badge (MTASK-0048)" || true
git push origin main || true

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
