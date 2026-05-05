# Incident Report: Autopilot Repair Followed by Stack Outage (2026-04-23)

## Executive Summary
A real operational wall occurred during stale-autopilot recovery.

Autopilot recovery tasks were executed and logged as successful, but the CustomIDE backend and frontend later had no listeners on ports 5555 and 5570. The stack was running as ad-hoc processes, not supervised services, so once those processes died there was no automatic restart path.

## What Happened (Timeline)
1. MTASK-0088 was picked up and executed with delayed detached autopilot restart strategy.
2. MTASK-0089 was picked up and completed (cockpit hard reset request).
3. MTASK-0090 was picked up and completed with the same delayed detached autopilot restart strategy.
4. After this point, state froze at the MTASK-0090 timestamp during the incident window.
5. Later operator checks confirmed backend/frontend user services did not exist and neither port was listening.

## Log Evidence
- Event log shows MTASK-0090 picked up and completed at the same timestamp:
  - MIDE/pilot_v1/state/worker_autopilot_events.log:4008
  - MIDE/pilot_v1/state/worker_autopilot_events.log:4009
- Autopilot runtime log confirms MTASK-0090 candidate and execution of delayed restart executor:
  - MIDE/pilot_v1/state/worker_mtask_autopilot.log:6545
  - MIDE/pilot_v1/state/worker_mtask_autopilot.log:6548
- MTASK-0090 result confirms strategy was delayed detached restart, not backend/frontend restart:
  - MIDE/pilot_v1/results/MTASK-0090.result.json
- The restart executor used by MTASK-0090 only targets worker autopilot service/process:
  - MIDE/pilot_v1/scripts/exec_mtask_0072_safe_restart_autopilot_once.sh
- Stack restart tasks (MTASK-0081 and MTASK-0085) did restart backend/frontend successfully earlier in the day:
  - MIDE/pilot_v1/results/MTASK-0081.result.json
  - MIDE/pilot_v1/results/MTASK-0085.result.json

## Root Cause Assessment
Primary cause:
- Backend/frontend were not managed by persistent systemd user units. They were launched as normal background processes and therefore had no supervision or auto-restart guarantee after interruption.

Contributing causes:
- Recovery focus was on stale autopilot and git-sync correctness, which did not include a persistent guarantee for ports 5555/5570.
- Operational checks initially assumed service names that were not installed (`worker-frontend.service`, `worker-backend.service`).
- The stack start path (`start_local_stack.sh`) starts both processes in background but does not register them with a process supervisor.

Not supported by evidence:
- MTASK-0090 script itself does not directly kill backend/frontend. It restarts only autopilot.

## Why It Felt Like Everything Crashed
From operator perspective, this was effectively a full outage because:
- Cockpit health depends on backend availability.
- Frontend/backend had no self-healing supervision.
- Service check commands targeting non-existent units returned hard failures, increasing incident ambiguity.

## Immediate Recovery That Worked
Manual process start restored service:
- frontend on 5570 via local static server
- backend on 5555 via uvicorn

## Preventive Actions (Recommended)
1. Install persistent user services for backend and frontend with restart policy (`Restart=always`).
2. Add a single health watchdog task that verifies listeners on 5555/5570 and restarts if absent.
3. Add one source-of-truth runbook command for stack status that checks both process and port state.
4. Keep autopilot recovery and stack recovery as separate playbooks, but trigger stack verification after autopilot restarts.

## Current Status at Time of Documentation
- Autopilot recovered and resumed task processing.
- Frontend/backend can be restored manually and were observed running after manual restart.
- Structural risk remains until persistent supervision is implemented for 5555/5570.
