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

> Auto-populated by MTASK-0034 → `pilot_v1/config/worker1_services.json`

| Service | URL | Notes |
|---------|-----|-------|
| site_kb_server | `https://jawed-lapel-dispersed.ngrok-free.dev` | Base server |
| Ollama health | `…/api/ollama/health` | qwen2.5 status |
| Ollama generate | `…/api/ollama/generate` | POST, streaming |
| Ollama chat | `…/api/ollama/chat` | POST, streaming |
| Weather compare | `…/api/weather/compare` | Existing demo |
| code-server | _populated by MTASK-0034_ | VS Code in browser |
| SSH (ngrok TCP) | _populated by MTASK-0032_ | IDE bridge |

---

## MTASK Execution Log

<!-- AUTO-UPDATED: 2026-04-22T18:06:08Z -->

## MTASK Status

| Task | Status | Summary | Timestamp |
|------|--------|---------|-----------|
| MTASK-0031 | [WAIT] pending | Awaiting Worker 1 | - |
| MTASK-0032 | [WAIT] pending | Awaiting Worker 1 | - |
| MTASK-0033 | [WAIT] pending | Awaiting Worker 1 | - |
| MTASK-0034 | [WAIT] pending | Awaiting Worker 1 | - |

---
_Last watcher check: 2026-04-22T18:06:08Z_

---

## Implementation Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | MOSS Architecture + Diagram | ✅ Complete |
| 2 | Worker 1 Setup (MTASK-0031–0034) | 🟡 In Progress |
| 3 | IDE_Backend_Windows (FastAPI) | ⏳ Pending |
| 4 | IDE_Frontend_Windows (editor UI) | ⏳ Pending |
| 5 | Ollama integration (proxy to Ubuntu) | ⏳ Pending |
| 6 | Script execution UI | ⏳ Pending |
| 7 | Remote IDE view (right pane) | ⏳ Pending |
| 8 | SSH bridge + file browser | ⏳ Pending |
| 9 | Polish + keyboard shortcuts | ⏳ Pending |

---

## Decisions Log

| Date | Decision | Reason |
|------|----------|--------|
| 2026-04-22 | Windows IDE proxies to Ubuntu Ollama | No local Ollama needed on Windows |
| 2026-04-22 | code-server for right pane | Full VS Code UI in browser, embeddable |
| 2026-04-22 | SSH via ngrok TCP tunnel | No direct network access between machines |
| 2026-04-22 | qwen2.5 as primary model | Already running on Worker 1, user confirmed |
| 2026-04-22 | Continue extension for code-server | Best Ollama integration for VS Code |

---

## Troubleshooting History

> Auto-appended by watcher when auto-retries are triggered.

_No issues yet._

---

## Key Files

```
MIDE/
├── pilot_v1/
│   ├── tasks/
│   │   ├── MTASK-0031.json   ← Ollama proxy routes
│   │   ├── MTASK-0032.json   ← SSH bootstrap
│   │   ├── MTASK-0033.json   ← code-server install
│   │   └── MTASK-0034.json   ← ngrok + verification
│   ├── scripts/
│   │   ├── exec_mtask_0031_ollama_proxy.sh
│   │   ├── exec_mtask_0032_ssh_bootstrap.sh
│   │   ├── exec_mtask_0033_codeserver_install.sh
│   │   ├── exec_mtask_0034_codeserver_ngrok_verify.sh
│   │   └── watch_customide.ps1     ← Windows 2-min auto-watcher
│   ├── specs/customide_ollama/
│   │   └── architecture.moss       ← MOSS spec v2.0
│   ├── gui/
│   │   └── customide_visualization.html  ← Interactive diagram
│   └── config/
│       └── worker1_services.json   ← Populated by MTASK-0034
└── CUSTOMIDE_PROJECT.md            ← This file
```




