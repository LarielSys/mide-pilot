# Main Operator Loop

## Purpose
Define the exact operating loop for the Windows Main IDE acting as the supervisor in the two-machine MIDE pilot.

## Moss Alignment Rule
Moss architecture is the canonical system map.

Before dispatch, Main IDE compares requested program changes against Moss-connected components, branches, and labels to prevent drift and route execution to the correct worker scope.

Instruction unit naming: mtask (Moss task).

In v1 repository paths, mtask artifacts are stored in existing task/result/approval JSON structures for backward compatibility.

## Main IDE Responsibilities
The Main IDE is responsible for:

1. Defining objectives
2. Breaking work into bounded tasks
3. Assigning task scope
4. Reviewing worker results
5. Approving or rejecting outcomes
6. Updating canonical state

The Main IDE does not delegate authority. It delegates execution only.

## Standard Main Loop
### 1. Identify the next objective
Before issuing any task, answer:

1. What is the immediate goal?
2. Which machine should do it?
3. What files/paths are allowed?
4. What validation evidence is required?

### 2. Create a task contract
Write a task JSON file that includes:

1. Task ID
2. Objective
3. Allowed paths
4. Blocked paths
5. Required validation
6. Dependencies
7. Timeout
8. Risk level

Note: In operating language this is an mtask contract, even if the file path uses task naming.

### 3. Commit and push task state
Main commits the new task to shared Git state and pushes it.

### 4. Wait for worker result
Do not assume completion.
Wait for:

1. Result JSON
2. Validation evidence
3. Error summary if failed

### 5. Review result against task contract
Check:

1. Was the scope followed?
2. Were blocked paths untouched?
3. Is evidence complete?
4. Did validation pass?
5. Does the result preserve architecture and order?

### 6. Decide
Possible decisions:

1. Approve
2. Reject
3. Request revision
4. Quarantine worker after repeated failure

### 7. Record canonical outcome
If approved:

1. Write approval file
2. Update ledger
3. Push canonical state

If rejected:

1. Record reason
2. Do not update canonical outcome as completed

## Review Rules
1. Never approve missing evidence
2. Never approve out-of-scope edits
3. Never approve architecture drift for convenience
4. Never skip the ledger update after approval

## Failure Handling
### Worker failure
If the worker fails:

1. Record failure
2. Request revision or reissue task
3. Quarantine after 3 consecutive failures

### Ambiguous result
If the result is unclear:

1. Reject as incomplete
2. Request clearer evidence
3. Do not assume success

## Main Operator Checklist
Before issuing a task:
1. Objective clear
2. Scope bounded
3. Validation defined
4. Dependencies known

Before approving a result:
1. Evidence present
2. Scope respected
3. Validation passed
4. Canonical state ready to update

## Immediate Use In Pilot
Use this loop every time the Windows Main node coordinates the Ubuntu Worker node.

This is the supervisor behavior baseline for MIDE v1.
