# MIDE - Two Machine Pilot

## Goal
Stand up MIDE as a supervisor-controlled orchestration workspace using:

1. Main node: Windows machine (operator + Main IDE)
2. Worker node: Ubuntu machine (execution agent)

## Architecture Source Of Truth (Moss)
MIDE uses the Moss system architecture as the canonical map of the system because it can connect, branch, and label moving parts.

Main IDE orchestration should compare active program state against Moss architecture labels before assigning worker execution.

## Task Center And Instruction Naming
For the current phase, Git is the task center (task transport, audit trail, approvals, and ledger state).

Main IDE instructions are called mtasks (Moss tasks).

In v1 files, existing JSON filenames and folders still use task naming for compatibility.

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
