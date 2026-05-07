# CustomIDE Cockpit — Architecture Snapshot
Generated: 2026-05-07T02:04:18Z
Worker: ubuntu-atlas-01 (ubuntu-worker-01)

---

## Overview

The CustomIDE Cockpit is a browser-based IDE dashboard with three Docker-containerized services:
- **Frontend** — static HTML/JS/CSS served on port 5570
- **Backend** — FastAPI (Python) on port 5555 providing data APIs
- **Ollama** — Local LLM (host-networked) on port 11434 using GPU

---

## Directory Tree

pilot_v1/customide
pilot_v1/customide/backend
pilot_v1/customide/backend/app
pilot_v1/customide/backend/app/__init__.py
pilot_v1/customide/backend/app/main.py
pilot_v1/customide/backend/app/__pycache__
pilot_v1/customide/backend/app/routes
pilot_v1/customide/backend/app/routes/config.py
pilot_v1/customide/backend/app/routes/execute.py
pilot_v1/customide/backend/app/routes/git.py
pilot_v1/customide/backend/app/routes/health.py
pilot_v1/customide/backend/app/routes/__init__.py
pilot_v1/customide/backend/app/routes/messenger.py
pilot_v1/customide/backend/app/routes/ollama_proxy.py
pilot_v1/customide/backend/app/routes/__pycache__
pilot_v1/customide/backend/app/routes/runtime.py
pilot_v1/customide/backend/app/routes/shared_llm.py
pilot_v1/customide/backend/app/services.py
pilot_v1/customide/backend/app/settings.py
pilot_v1/customide/backend/Dockerfile
pilot_v1/customide/backend/README.md
pilot_v1/customide/backend/requirements.txt
pilot_v1/customide/backend/.venv
pilot_v1/customide/docker-compose.yml
pilot_v1/customide/frontend
pilot_v1/customide/frontend/css
pilot_v1/customide/frontend/css/style.css
pilot_v1/customide/frontend/Dockerfile
pilot_v1/customide/frontend/index.html
pilot_v1/customide/frontend/js
pilot_v1/customide/frontend/js/app.js
pilot_v1/customide/frontend/js/config.js
pilot_v1/customide/frontend/README.md
pilot_v1/customide/INCIDENT_2026-04-23_AUTOPILOT_STACK_OUTAGE.md
pilot_v1/customide/LOCAL_LLM_PLAYBOOK.txt
pilot_v1/customide/MOSS_ARCHITECTURE_WORKFLOW.md
pilot_v1/customide/ollama
pilot_v1/customide/ollama/docker-compose.yml
pilot_v1/customide/OLLAMA_VERSION_COORDINATOR.md
pilot_v1/customide/scripts
pilot_v1/customide/scripts/start_local_stack.sh
pilot_v1/customide/WINDOWS_UBUNTU_PARITY_RUNBOOK.md

---

## Docker Compose Services

```yaml
# MIDE Cockpit full stack
# Start: docker compose up -d
# Stop:  docker compose down

services:

  # ── Ollama LLM runtime (GPU-dedicated, host network) ────────────────────
  # network_mode: host is required because the nvidia runtime does not
  # integrate with user-defined Docker bridge networks. Ollama binds
  # directly to the host's port 11434.
  ollama:
    image: ollama/ollama:latest
    container_name: mide-ollama
    restart: unless-stopped
    runtime: nvidia
    network_mode: host
    volumes:
      - ollama:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0:11434
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
      # To pin a specific GPU by UUID:
      # - NVIDIA_VISIBLE_DEVICES=GPU-dc07154d-a52e-2970-7237-e6f52c1de5ea

  # ── CustomIDE Backend (FastAPI) ─────────────────────────────────────────
  backend:
    build:
      context: ./backend
    image: mide-backend:latest
    container_name: mide-backend
    restart: unless-stopped
    ports:
      - "5555:5555"
    volumes:
      - /home/larieladmin/mide-pilot/pilot_v1/config:/pilot_v1/customide/pilot_v1/config:ro
      - /home/larieladmin/mide-pilot/pilot_v1/state:/pilot_v1/customide/pilot_v1/state
      - /home/larieladmin/mide-pilot/.git:/pilot_v1/customide/.git:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - CUSTOMIDE_APP_HOST=0.0.0.0
      # Reach Ollama on the host via host-gateway (since ollama uses host networking)
      - CUSTOMIDE_OLLAMA_BASE_URL=http://172.17.0.1:11434
      - CUSTOMIDE_OLLAMA_MODEL=qwen2.5:14b

  # ── CustomIDE Frontend (static) ─────────────────────────────────────────
  frontend:
    build:
      context: ./frontend
    image: mide-frontend:latest
    container_name: mide-frontend
    restart: unless-stopped
    ports:
      - "5570:5570"

volumes:
  ollama:
    external: true
```

---

## Backend API Routes

Source: `pilot_v1/customide/backend/app/routes/`

### config.py
  get "/services"

### execute.py
  post "/local"
  post "/remote"

### git.py
  get "/status"
  post "/connect"
  post "/fetch"
  post "/pull"
  post "/push"

### health.py
  get ""

### __init__.py

### messenger.py
  post ""

### ollama_proxy.py
  get "/health"
  post "/generate"

### runtime.py
  get "/runtime"
  get "/sync-health"
  get "/worker-log"
  get "/token-counters"
  get "/bundle"

### shared_llm.py
  get "/health"
  post "/chat"

---

## Frontend Key Files

- `frontend/index.html` — 111 lines
- `frontend/js/app.js` — 1755 lines
- `frontend/js/config.js` — 21 lines

---

## Chat Flow

```
Browser (app.js:sendChat)
  → POST http://localhost:5555/api/llm/chat
      { prompt, model, source }
  → backend/app/routes/shared_llm.py
      reads CUSTOMIDE_OLLAMA_BASE_URL + CUSTOMIDE_OLLAMA_MODEL
  → POST http://172.17.0.1:11434/api/generate
      { model: qwen2.5:14b, prompt, stream: false }
  ← { text, degraded, error, model, source }
  ← Browser renders data.text in chat pane
```

---

## Cockpit Panes & Data Sources

All pane data is served from `GET /api/status/bundle`

| Pane | Backend Key | Source |
|------|------------|--------|
| Runtime / Worker | `runtime` | hardcoded + env vars |
| Sync Health | `sync_health` | `git show origin/main:pilot_v1/state/...` |
| Sync Cadence | `sync_cadence` | state files via git |
| Worker Log / Events | `worker_log` | `worker_autopilot_events.log` (newest-first, top 40) |
| Token Counters | `token_counters` | state JSON files |

---

## State Files (pilot_v1/state/)

- `cockpit_hard_reset_request.json` — 4.0K — 2026-04-26 21:45
- `customide_stack_health.json` — 4.0K — 2026-05-06 19:29
- `ledger.json` — 12K — 2026-04-22 14:57
- `MTASK-0072.restart.log` — 4.0K — 2026-04-23 15:17
- `MTASK-0072.restart_queued.txt` — 4.0K — 2026-04-23 14:58
- `MTASK-0092.restart_queued.txt` — 4.0K — 2026-04-23 15:23
- `operator_loop.log` — 4.0K — 2026-05-04 23:13
- `operator_loop_processed.json` — 8.0K — 2026-05-04 23:09
- `PILOT_CERTIFICATION.json` — 4.0K — 2026-04-22 10:48
- `shared_llm_chat_history.json` — 20K — 2026-05-04 23:13
- `website_system_data.json` — 4.0K — 2026-05-06 21:56
- `worker1_services.json` — 4.0K — 2026-05-06 21:51
- `worker_autopilot_events.log` — 1.2M — 2026-05-06 22:03
- `worker_autopilot_heartbeat_epoch.txt` — 4.0K — 2026-05-06 22:03
- `worker_autopilot_live.txt` — 4.0K — 2026-05-06 22:03
- `worker_autopilot_status.json` — 4.0K — 2026-05-06 22:03
- `worker_mtask_autopilot.log` — 524K — 2026-05-06 22:04
- `worker_ops_note.txt` — 4.0K — 2026-04-21 22:37
- `worker_registry.json` — 4.0K — 2026-04-22 14:20

---

## Ollama Models Available

- qwen2.5:14b (8571 MB)
- qwen2.5:7b (4466 MB)
- kimi-k2.6:cloud (0 MB)

---

## Active Docker Containers

```
NAMES           IMAGE                                STATUS                 PORTS
mide-backend    mide-backend:latest                  Up 12 minutes          0.0.0.0:5555->5555/tcp, [::]:5555->5555/tcp
mide-frontend   mide-frontend:latest                 Up 53 minutes          0.0.0.0:5570->5570/tcp, [::]:5570->5570/tcp
mide-ollama     ollama/ollama:latest                 Up 2 hours             
open-webui      ghcr.io/open-webui/open-webui:main   Up 2 hours (healthy)   0.0.0.0:3000->8080/tcp, [::]:3000->8080/tcp
ollama          ollama/ollama                        Up 2 hours             
portainer       portainer/portainer-ce               Up 2 hours             8000/tcp, 9443/tcp, 0.0.0.0:9000->9000/tcp, [::]:9000->9000/tcp
```

---
_architecture_snapshot=written_
_cockpit_architecture_md=exists_
