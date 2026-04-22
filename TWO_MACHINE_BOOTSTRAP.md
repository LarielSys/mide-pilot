# Two-Machine Bootstrap

## Topology
1. Windows Main IDE (controller)
2. Ubuntu Worker IDE/Agent (executor)

## Phase 1: Machine Identity and Reachability
1. Confirm Windows can SSH into Ubuntu
2. Confirm Ubuntu can return logs and command output
3. Confirm time sync on both machines (for auditable event ordering)

## Phase 2: Control Plane (Minimal)
1. Create task envelope format
2. Create status event format
3. Create result bundle format
4. Store all task/result records in a local ledger file on Windows

### Minimal Task Envelope Fields
1. task_id
2. objective
3. allowed_paths
4. blocked_paths
5. required_validation
6. priority
7. timeout_seconds
8. dependencies
9. risk_level

## Phase 3: Worker Execution Contract
For every task, Ubuntu worker must return:

1. execution_status
2. command_transcript
3. touched_files
4. proposed_changes
5. validation_results
6. error_summary
7. confidence_and_risk_note

## Phase 4: Approval Gate
1. Main IDE reviews result bundle
2. Main IDE checks scope compliance and validation evidence
3. Main IDE approves or rejects
4. Only approved work is applied to canonical state

## Phase 5: Safety Controls
1. Enforce exclusive file locks before dispatch
2. Quarantine worker after 3 consecutive failures
3. Require admin password for any override action
4. Log every override with reason and timestamp

## Phase 6: Telemetry
1. Text telemetry is required for every task
2. Snapshot telemetry optional in v1, mandatory in v2 pane view
3. Any text/snapshot mismatch creates a manual review hold

## Phase 7: First Pilot Tasks
Use these in order:

1. Read-only repository scan
2. Single-file low-risk edit task
3. Dependency check task
4. Unit test task
5. Multi-step fix with explicit approval gate

## Exit Criteria for Pilot
1. 10 tasks completed
2. 0 unauthorized file edits
3. 100% approval-gated apply flow
4. Quarantine flow validated at least once (simulated)
5. Full task audit trail present for all completed tasks
