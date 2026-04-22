# MIDE Pilot v1 (Two Machines, No-Code Workflow)

## Purpose
Run a practical Main IDE -> Worker IDE loop with explicit approval gates and auditable records, using files and commands only.

## Machines
1. Main: windows-main
2. Worker: ubuntu-worker-01

## Workflow
1. Main creates a task file in tasks/
2. Worker executes only within the task contract
3. Worker writes result file in results/
4. Main reviews and writes approval file in approvals/
5. Main updates state/ledger.json

## Rules
1. Exclusive file locks
2. Quarantine worker after 3 failures
3. No apply without main approval
4. Override requires admin policy

## First Task (Recommended)
Use TASK-0001 to validate Ubuntu chat backend health and endpoint behavior.

### Suggested task objective
"Validate /health and /api/chat endpoints from Ubuntu worker and return status plus evidence."

### Required evidence
1. health endpoint output
2. api/chat POST output
3. command transcript

## Why this v1 works
1. Immediate execution with zero new service code
2. Clear authority boundaries
3. Full audit trail for each task
4. Easy transition later to automated control plane
