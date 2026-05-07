# CustomIDE Project — Living Documentation

> Auto-managed by `watch_customide.ps1`. Do not edit the MTASK Status block manually.

## Overview

A VS Code–like IDE running on Windows with:
- **Dual-pane view**: Left = local code editor, Right = Ubuntu Worker 1 (code-server)
- **Shared AI**: Windows IDE proxies to Ubuntu's `qwen2.5` via Ollama (no local model needed)
- **Script execution**: Read/apply/execute scripts locally or on Worker 1 via SSH
- **MIDE integration**: Shares the same Worker 1 autopilot infrastructure
- **Architecture**: Defined in MOSS format → compiled to interactive diagram

---

## Architecture

| Artifact | Path |
|----------|------|
| MOSS Spec (v2.0) | `pilot_v1/specs/customide_ollama/architecture.moss` |
| Interactive Diagram | `pilot_v1/gui/customide_visualization.html` |

### Component Summary

| Component | Location | Role |
|-----------|----------|------|
| IDE_Frontend_Windows | `c:\AI Assistant\customide\frontend` | VS Code-like dual-pane UI |
| IDE_Backend_Windows | `c:\AI Assistant\customide\backend` (port 5555) | FastAPI coordinator |
| Ollama_Proxy | Ubuntu via ngrok `/api/ollama/*` | qwen2.5 AI (Windows proxies to Ubuntu) |
| SSH_Worker1_Bridge | SSH tunnel via ngrok TCP | Remote script execution, file access |
| code-server | Ubuntu port 8092, via ngrok | Remote IDE view (right pane) |
| Script_Execution_Engine | IDE_Backend_Windows | Read/validate/execute scripts local+remote |
| Git_Integration | Local `.git` | Version control |
| MIDE_Worker_Autopilot | Ubuntu systemd service | Autonomous MTASK execution |

---

## Worker 1 Service Endpoints

> Auto-populated by MTASK-0034 + MTASK-0105/0106 → `pilot_v1/state/worker1_services.json`

| Service | URL | Notes | Status |
|---------|-----|-------|--------|
| Ollama (Docker) | `http://127.0.0.1:11434` | Local qwen2.5-coder:14b | Being tunneled |
| Ollama ngrok tunnel | _MTASK-0105 will populate_ | Public Ollama endpoint for website chat | ⏳ Pending |
| Ollama /api/chat | `{tunnel}/api/chat` | Chat streaming endpoint | ⏳ Pending |
| Ollama /api/generate | `{tunnel}/api/generate` | Generation streaming endpoint | ⏳ Pending |
| itheia-llm | `http://127.0.0.1:8082` | Backup proxy option | UP |
| code-server | `http://127.0.0.1:8092` | VS Code in browser | UP |
| SSH (ngrok TCP) | _via ngrok_ | IDE bridge | UP |

---

## MTASK Execution Log

<!-- AUTO-UPDATED: 2026-05-06T00:00:00Z -->

## MTASK Status

| Task | Status | Summary | Timestamp |
|------|--------|---------|-----------|
| MTASK-0103 | [OK] completed | All 5 services verified UP. | 2026-05-05T03:30:54Z |
| MTASK-0104 | ⏳ pending | Diagnose ngrok + Ollama (native + Docker). | 2026-05-06T00:00:00Z |
| MTASK-0105 | ⏳ pending | Set up persistent ngrok tunnel for Ollama. | 2026-05-06T00:00:00Z |
| MTASK-0106 | ⏳ pending | Verify tunnel end-to-end, write website URLs. | 2026-05-06T00:00:00Z |

---
_Last update: 2026-05-06 (Tunnel setup chain queued, awaiting Docker Ollama completion)_

---

## Implementation Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | MOSS Architecture + Diagram | ✅ Complete |
| 2 | Worker 1 Setup (MTASK-0031–0034) | ✅ Complete |
| 3 | Stack Health Verification (MTASK-0035–0103) | ✅ Complete |
| 4 | **Ollama Tunnel for Website (MTASK-0104–0106)** | 🟡 **In Progress** |
| 5 | Website Chat Integration (MTASK-0107 planned) | ⏳ Pending |
| 6 | IDE_Backend_Windows (FastAPI) | ⏳ Pending |
| 7 | IDE_Frontend_Windows (editor UI) | ⏳ Pending |
| 8 | Script execution UI | ⏳ Pending |
| 9 | Remote IDE view (right pane) | ⏳ Pending |
| 10 | SSH bridge + file browser | ⏳ Pending |

---

## Decisions Log

| Date | Decision | Reason |
|------|----------|--------|
| 2026-04-22 | Windows IDE proxies to Ubuntu Ollama | No local Ollama needed on Windows |
| 2026-04-22 | code-server for right pane | Full VS Code UI in browser, embeddable |
| 2026-04-22 | SSH via ngrok TCP tunnel | No direct network access between machines |
| 2026-04-22 | qwen2.5 as primary model | Already running on Worker 1, user confirmed |
| 2026-04-22 | Continue extension for code-server | Best Ollama integration for VS Code |
| 2026-05-06 | Ollama tunnel for Bluehost website chat | Website (Bluehost) needs external ngrok URL for CORS |
| 2026-05-06 | Docker Ollama on Ubuntu | Isolated container, persistent, clean separation |
| 2026-05-06 | operator_loop.ps1 restarts (60s poll) | Autonomous 0104→0105→0106 execution chain |

---

## Troubleshooting History

> Auto-appended by watcher when auto-retries are triggered.

_No issues yet._

---

## Next Steps

1. **Ubuntu Docker Ollama**: Finish containerizing qwen2.5-coder:14b
2. **Start operator_loop.ps1** on Windows (run once, stays alive):
   ```powershell
   cd "C:\AI Assistant\MIDE"
   .\pilot_v1\scripts\operator_loop.ps1
   ```
3. **Autonomous execution**: MTASK-0104 → 0105 → 0106 (no further input needed)
4. **Website integration**: Update chat.html with final ngrok URL (MTASK-0107)

---

## Key Files

```
MIDE/
├── pilot_v1/
│   ├── tasks/
│   │   ├── MTASK-0104.json   ← [NEW] Diagnose Ollama tunnel status
│   │   ├── MTASK-0105.json   ← [NEW] Set up ngrok tunnel for Ollama
│   │   ├── MTASK-0106.json   ← [NEW] Verify tunnel + write website URLs
│   │   └── (earlier: 0031-0103)
│   ├── scripts/
│   │   ├── exec_mtask_0104_diagnose_ollama_tunnel.sh        ← [NEW]
│   │   ├── exec_mtask_0105_setup_ollama_tunnel.sh           ← [NEW]
│   │   ├── exec_mtask_0106_verify_ollama_tunnel.sh          ← [NEW]
│   │   ├── operator_loop.ps1              ← [UPDATED] Extended pipeline 0104→0106
│   │   └── worker_mtask_autopilot.sh      ← Ubuntu autonomy loop
│   ├── state/
│   │   └── worker1_services.json          ← Updated by MTASK-0105/0106
│   ├── specs/customide_ollama/
│   │   └── architecture.moss              ← MOSS spec v2.0
│   ├── gui/
│   │   └── customide_visualization.html   ← Interactive diagram
│   └── config/
│       └── worker1_services.json          ← Endpoint registry
└── CUSTOMIDE_PROJECT.md                   ← This file
```
















