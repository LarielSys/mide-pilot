# MIDE2 Complete Project Spec

Date: 2026-05-09
Status: Canonical specification
Project: MIDE2 (greenfield rebuild)

## 0. What This Project Is

MIDE2 is a new autonomous cockpit + IDE platform.
It is not a refactor of old MIDE. Old code remains separate.

Primary goal:
- Build a real-time operations cockpit and a VS-style IDE page where an autonomous worker picks up MTASKs and executes them under strict policy controls.

## 1. Language and Stack (Explicit)

This is the language decision so tooling does not guess:

- Backend Orchestrator / Worker Services: Python 3.11+
- Frontend UI (Cockpit + IDE page): TypeScript + React
- Styling/UI framework: CSS with component library (implementation choice later)
- Runtime Containerization: Docker Compose
- LLM Runtime: Docker Ollama only
- Data/Event layer: Redis (streams/pubsub) or NATS (final pick during implementation)
- Source Control: Git

Not in scope for phase 1:
- C++ desktop app
- Java desktop app
- VB desktop app
- Multi-provider LLM routing

## 2. Mandatory Runtime Policy

- Ubuntu Docker Ollama is the single LLM endpoint for this project.
- Required models:
  - qwen2.5-coder:7b
  - qwen2.5vl:7b
- No silent fallback to other providers or local alternate hosts.
- No silent model-name substitutions.

## 3. Product Surfaces

1. Cockpit page (operations)
- Real-time pane dashboard.
- Button to open IDE page.

2. IDE page (VS-style)
- Left: Explorer tree/search.
- Center: File editor tabs/splits.
- Bottom: Terminal/Problems/Output/Debug.
- Right: AI chat + MTASK status + patch/retry/result panels.

## 4. AI Connectivity Requirement

AI must be connected to all pane streams from startup.
AI is a workflow observer and actor, not chat-only.

AI must be able to:
- Read pane events and orchestration state.
- Infer workflow status and anomalies.
- Propose or execute scoped actions tied to MTASK context.

## 5. Core Architecture

Services:
- cockpit-ui
- ide-ui
- orchestrator-api
- mtask-queue + lease-coordinator
- autonomous-worker-runtime
- heartbeat-service
- watchdog-service
- artifact-writer-service
- ollama-service

Flow:
- UI -> orchestrator -> queue/events/worker -> artifacts
- Worker -> filesystem/terminal adapters -> patch/results
- Orchestrator/worker -> ollama-service

## 6. Pane Layout Contract

Cockpit panes:
- Pane A: Autopilot + heartbeat (pinned)
- Pane B: Command/orchestration state
- Pane C: AI reasoning timeline
- Pane D: Model/inference health
- Pane E: Service telemetry
- Pane F: Retrieval/context
- Pane G: Alerts/exceptions
- Pane H: Audit/replay

IDE right rail:
- AI chat
- Active MTASK
- Retry trace
- Patch preview
- Result status

## 7. Autopilot and Heartbeat Rules

Hard rules:
- Autopilot cannot be turned off from normal UI actions.
- Heartbeat must be continuously visible in autopilot pane.
- Backup watchdog timeout is hard-coded at 300 seconds.
- If heartbeat is missing for 300 consecutive seconds:
  - force restart heartbeat service
  - force restart autopilot service

State model:
- LIVE, DEGRADED, CRITICAL, RECOVERING, HARD-FAIL

## 8. MTASK Governance

### 8.1 Naming

Worker-facing IDs:
- mtaskwk1-0001
- mtaskwk2-0001

Also required:
- Global canonical task ID for uniqueness.

### 8.2 Lease and Ownership

- Task must be claimed before execution.
- Lease heartbeat required while running.
- Expired lease allows reassignment.

### 8.3 Error Gate (Hard Scheduler Rule)

A worker cannot start a new MTASK if it has an unresolved erroneous MTASK.

Required retry trace:
- rty1
- rty2

Execution order:
- error -> rty1-running -> rty2-running (if needed) -> completed
- if still unresolved after rty2: blocked-critical (escalation, no next task)

Only after completed may worker claim next MTASK.

## 9. Autonomous IDE Worker Contract

Worker loop:
1. Listen for eligible MTASK.
2. Preflight check:
   - Ollama reachable
   - Required model available
   - Workspace/path permission valid
   - No unresolved error gate block
3. Claim lease.
4. Execute task using file/terminal tools.
5. Emit retry or result status.
6. Persist allowed artifacts.
7. Release lease and return to queue.

## 10. Git Persistence Policy

Allowed classes only:
- MTASKS
- RESULTS
- RETRIES
- PATCHES

Never saved:
- sleeping logs
- runtime noise logs
- ad hoc debug chatter not promoted to allowed artifacts

## 11. Multi-Computer Coordination

Dependency/install and lateral program work must use lock keys:
- lock key dimensions: program + version + OS + architecture + environment target
- one writer per lock key at a time
- other workers wait or use read-only/cache paths

## 12. New Project Folder Requirement

All new work starts in Ubuntu folder:
- ~/mide2

Old MIDE code remains separate.

Bootstrap:
```bash
mkdir -p ~/mide2
cd ~/mide2
git init
mkdir -p services/cockpit-ui services/ide-ui services/orchestrator services/worker services/heartbeat services/watchdog infra scripts artifacts
mkdir -p artifacts/mtasks artifacts/results artifacts/retries artifacts/patches
```

## 13. Delivery Phases

Phase 1
- Orchestrator + queue + lease + heartbeat + watchdog skeleton.

Phase 2
- Cockpit UI shell + IDE UI shell with required layout.

Phase 3
- Autonomous worker execution loop.

Phase 4
- Policy enforcement (error gate, retries, heartbeat restart, git allowlist).

Phase 5
- Multi-worker and failure-path validation.

## 14. Acceptance Criteria

System is ready only when all are true:
- VS-style IDE layout implemented as specified.
- Autonomous MTASK pickup active.
- Error gate blocks next task until repair completed.
- Retry trace states rty1/rty2 are recorded.
- 300s heartbeat timeout force-restarts heartbeat and autopilot.
- AI sees all pane streams.
- Docker Ollama is only LLM runtime.
- Git contains only MTASK/RESULT/RETRY/PATCH artifacts.
- Sleeping logs are absent from git.

## 15. Source of Truth

Primary project spec:
- MIDE2_COMPLETE_SPEC.md (this file)

Supporting handoff:
- MIDE2_THOROUGH_HANDOFF.md

If they conflict, this file wins for implementation decisions.
