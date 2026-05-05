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

## Frontend/Backend Down (Mandatory Triage)
When CustomIDE appears down, always run this sequence in order.

1. Check listeners first (not service names):
```bash
ss -tulpn | grep -E "5570|5555" || true
```
2. If ports are listening, test endpoints:
```bash
curl -fsS http://127.0.0.1:5555/health
curl -I http://127.0.0.1:5570
```
3. If ports are not listening, check for user services:
```bash
systemctl --user list-unit-files --type=service | grep -Ei "frontend|backend|customide|worker" || true
```
4. If expected frontend/backend units do not exist, treat stack as Python process managed and restart with script:
```bash
cd ~/mide-pilot
bash pilot_v1/customide/scripts/start_local_stack.sh
```
5. If script-based restart fails, run direct Python starts:
```bash
cd ~/mide-pilot/pilot_v1/customide/frontend
nohup python3 -m http.server 5570 > frontend.log 2>&1 &

cd ~/mide-pilot/pilot_v1/customide/backend
nohup python3 -m uvicorn app.main:app --host 127.0.0.1 --port 5555 > backend.log 2>&1 &
```
6. Re-verify listeners and health:
```bash
ss -tulpn | grep -E "5570|5555"
curl -fsS http://127.0.0.1:5555/health
```

Decision rule:
- Do not spend more than one check cycle on missing service names.
- If units are absent, pivot immediately to Python process restart.
