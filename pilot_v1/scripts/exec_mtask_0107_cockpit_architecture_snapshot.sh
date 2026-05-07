#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TASK_ID="MTASK-0107"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
COCKPIT_DIR="${REPO_ROOT}/pilot_v1/customide"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
OUT_FILE="${STATE_DIR}/cockpit_architecture.md"

echo "task=${TASK_ID}"
echo "worker_id=${WORKER_ID}"
echo "worker_name=${WORKER_NAME}"

# ── Validate cockpit exists ─────────────────────────────────────────────
if [[ ! -d "${COCKPIT_DIR}" ]]; then
  echo "error=cockpit_dir_missing:${COCKPIT_DIR}"
  exit 1
fi

# ── Build architecture document ─────────────────────────────────────────
{
cat << HEADER
# CustomIDE Cockpit — Architecture Snapshot
Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Worker: ${WORKER_NAME} (${WORKER_ID})

---

## Overview

The CustomIDE Cockpit is a browser-based IDE dashboard with three Docker-containerized services:
- **Frontend** — static HTML/JS/CSS served on port 5570
- **Backend** — FastAPI (Python) on port 5555 providing data APIs
- **Ollama** — Local LLM (host-networked) on port 11434 using GPU

---

## Directory Tree

HEADER

find "${COCKPIT_DIR}" -not -path "*/.venv/*" -not -path "*/__pycache__/*" \
  -not -path "*/.git/*" -not -name "*.pyc" -not -name "*.log" \
  | sort | sed "s|${REPO_ROOT}/||" | head -80

echo ""
echo "---"
echo ""
echo "## Docker Compose Services"
echo ""
echo '```yaml'
cat "${COCKPIT_DIR}/docker-compose.yml"
echo '```'
echo ""

echo "---"
echo ""
echo "## Backend API Routes"
echo ""
echo "Source: \`pilot_v1/customide/backend/app/routes/\`"
echo ""

for route_file in "${COCKPIT_DIR}/backend/app/routes/"*.py; do
  basename_f="$(basename "${route_file}")"
  echo "### ${basename_f}"
  # Extract route decorators
  (grep -E '@router\.(get|post|put|delete|patch)' "${route_file}" 2>/dev/null || true) | \
    sed 's/.*@router\.\(.*\)(\(.*\))/  \1 \2/' | head -20
  echo ""
done

echo "---"
echo ""
echo "## Frontend Key Files"
echo ""
for f in index.html js/app.js js/config.js js/panels.js; do
  fp="${COCKPIT_DIR}/frontend/${f}"
  if [[ -f "${fp}" ]]; then
    size=$(wc -l < "${fp}")
    echo "- \`frontend/${f}\` — ${size} lines"
  fi
done
echo ""

echo "---"
echo ""
echo "## Chat Flow"
echo ""
echo '```'
echo "Browser (app.js:sendChat)"
echo "  → POST http://localhost:5555/api/llm/chat"
echo "      { prompt, model, source }"
echo "  → backend/app/routes/shared_llm.py"
echo "      reads CUSTOMIDE_OLLAMA_BASE_URL + CUSTOMIDE_OLLAMA_MODEL"
echo "  → POST http://172.17.0.1:11434/api/generate"
echo "      { model: qwen2.5:14b, prompt, stream: false }"
echo "  ← { text, degraded, error, model, source }"
echo "  ← Browser renders data.text in chat pane"
echo '```'
echo ""

echo "---"
echo ""
echo "## Cockpit Panes & Data Sources"
echo ""
echo "All pane data is served from \`GET /api/status/bundle\`"
echo ""
echo "| Pane | Backend Key | Source |"
echo "|------|------------|--------|"
echo "| Runtime / Worker | \`runtime\` | hardcoded + env vars |"
echo "| Sync Health | \`sync_health\` | \`git show origin/main:pilot_v1/state/...\` |"
echo "| Sync Cadence | \`sync_cadence\` | state files via git |"
echo "| Worker Log / Events | \`worker_log\` | \`worker_autopilot_events.log\` (newest-first, top 40) |"
echo "| Token Counters | \`token_counters\` | state JSON files |"
echo ""

echo "---"
echo ""
echo "## State Files (pilot_v1/state/)"
echo ""
ls "${STATE_DIR}"/*.json "${STATE_DIR}"/*.log "${STATE_DIR}"/*.txt 2>/dev/null | \
  while read -r f; do
    base="$(basename "${f}")"
    sz="$(du -h "${f}" | cut -f1)"
    modified="$(date -r "${f}" "+%Y-%m-%d %H:%M")"
    echo "- \`${base}\` — ${sz} — ${modified}"
  done
echo ""

echo "---"
echo ""
echo "## Ollama Models Available"
echo ""
curl -s http://localhost:11434/api/tags 2>/dev/null | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('models',[]):
    print(f\"- {m['name']} ({m.get('size',0)//1024//1024} MB)\")
" 2>/dev/null || echo "- (could not reach Ollama at localhost:11434)"
echo ""

echo "---"
echo ""
echo "## Active Docker Containers"
echo ""
echo '```'
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(docker not available)"
echo '```'
echo ""

echo "---"
echo "_architecture_snapshot=written_"
echo "_cockpit_architecture_md=exists_"

} > "${OUT_FILE}"

echo "architecture_snapshot=written"
echo "output=${OUT_FILE}"
echo "lines=$(wc -l < "${OUT_FILE}")"
echo "cockpit_architecture_md=exists"
