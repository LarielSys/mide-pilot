# MIDE - Two Machine Pilot

## Goal
Stand up MIDE as a supervisor-controlled orchestration workspace using:

1. Main node: Windows machine (operator + Main IDE)
2. Worker node: Ubuntu machine (execution agent)

## v1 Rules (Locked)
1. Main IDE is sole orchestrator
2. Exclusive file locks
3. Worker quarantine after 3 failures
4. Single-admin override by default
5. Optional two-person override for sensitive operations

## Pilot Outcome
At pilot completion, you should be able to:

1. Dispatch bounded tasks from Windows to Ubuntu
2. Receive task outputs, logs, and validation evidence
3. Approve or reject results before apply
4. Keep an auditable history of all approved changes

## Start Here
1. Read [TWO_MACHINE_BOOTSTRAP.md](TWO_MACHINE_BOOTSTRAP.md)
2. Fill machine profiles in [profiles/windows-main.json](profiles/windows-main.json) and [profiles/ubuntu-worker.json](profiles/ubuntu-worker.json)
3. Run the connectivity and health checklist in the bootstrap file
