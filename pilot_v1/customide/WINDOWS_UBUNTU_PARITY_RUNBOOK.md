# Windows/Ubuntu Parallel Workflow Runbook

## Goal
Keep Windows troubleshooting in lockstep with Ubuntu autopilot progression using forward-only MTASK execution.

## Source of Truth
- Ubuntu result artifacts in `pilot_v1/results/MTASK-*.result.json`
- Canonical chain baseline starts at highest completed MTASK ID

## Forward-Only Rule
1. Do not rerun historical MTASK base scripts once a later retry is completed.
2. Add new work as the next MTASK ID (or explicit retry of the current MTASK).
3. Every debug/fix step must be represented by an MTASK task file.

## Ubuntu Execution
1. Push task JSON and executor script.
2. Let worker autopilot execute assigned MTASK.
3. Confirm result JSON contains `execution_status=completed`.

## Windows Mirror Validation
Run after each Ubuntu result:

```powershell
powershell -ExecutionPolicy Bypass -File pilot_v1/scripts/check_mtask_parity.ps1 -TaskId MTASK-XXXX
```

Expected output markers:
- `parity_result_present=passed`
- `parity_repo_clean_or_known=passed`
- `parity_forward_chain=passed`

## Recovery
If Ubuntu fails:
1. Create retry MTASK with explicit fix objective.
2. Link dependency to failed MTASK.
3. Re-run parity checker after retry result arrives.
