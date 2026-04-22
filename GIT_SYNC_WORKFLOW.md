# MIDE Git Sync Workflow

## Purpose
Use Git as the transport layer between:

1. Windows Main IDE
2. Ubuntu Worker IDE

This avoids direct SSH/SCP dependence while preserving a shared task/result/approval workflow.

## Role Split
### Windows Main
Responsible for:
1. Creating task files
2. Reviewing worker results
3. Writing approval decisions
4. Maintaining canonical state

### Ubuntu Worker
Responsible for:
1. Pulling latest task state
2. Executing only approved tasks
3. Writing result files
4. Never applying canonical changes without Main approval

## Repository Zones
Suggested shared folders:

1. `MIDE/pilot_v1/tasks/`
2. `MIDE/pilot_v1/results/`
3. `MIDE/pilot_v1/approvals/`
4. `MIDE/pilot_v1/state/`

## Standard Loop
### Step 1: Main creates task
Windows Main:
1. Create a task JSON file in `tasks/`
2. Commit with a message like:
   - `main: add TASK-0002`
3. Push to shared remote

### Step 2: Worker pulls and executes
Ubuntu Worker:
1. Pull latest changes
2. Read approved task file
3. Execute only within the task scope
4. Write result JSON in `results/`
5. Commit with a message like:
   - `worker: add TASK-0002 result`
6. Push to shared remote

### Step 3: Main reviews and decides
Windows Main:
1. Pull latest changes
2. Review `results/TASK-XXXX.result.json`
3. Write `approvals/TASK-XXXX.approval.json`
4. Update canonical ledger if approved
5. Commit with a message like:
   - `main: approve TASK-0002`
6. Push to shared remote

## Rules
1. Main is the source of truth
2. Worker does not skip approval
3. Task scope must be explicit
4. Results must include evidence
5. Approved changes only become canonical state

## Why This Works
1. No dependence on inbound SSH/SCP
2. Shared state stays inspectable and auditable
3. Works with your current two-machine setup
4. Easy to replace later with a real orchestration transport layer

## Immediate Next Step
After this workflow is accepted, define:
1. Main operator loop
2. Worker operating prompt
3. TASK-0002 using Git-based exchange
