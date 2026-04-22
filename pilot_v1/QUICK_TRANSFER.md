# Quick Transfer (No More Copy/Paste)

Use these PowerShell scripts from Windows Main to move task/result JSON files directly to and from Ubuntu.

## One-time setup
1. Ensure OpenSSH client is installed on Windows (`scp` command available).
2. Ensure Ubuntu has target folder:
   - `/home/larieladmin/Documents/itheia-llm/MIDE/pilot_v1`
3. Run bootstrap copy once:

```powershell
powershell -ExecutionPolicy Bypass -File "c:\AI Assistant\MIDE\pilot_v1\scripts\push-bootstrap.ps1"
```

## Push a task to Ubuntu worker

```powershell
powershell -ExecutionPolicy Bypass -File "c:\AI Assistant\MIDE\pilot_v1\scripts\push-task.ps1" -TaskId "TASK-0001"
```

## Pull a result from Ubuntu worker

```powershell
powershell -ExecutionPolicy Bypass -File "c:\AI Assistant\MIDE\pilot_v1\scripts\pull-result.ps1" -TaskId "TASK-0001"
```

## Typical loop
1. Main writes task JSON in `tasks/`.
2. Run `push-task.ps1`.
3. Ubuntu worker executes task and writes `results/TASK-XXXX.result.json`.
4. Run `pull-result.ps1`.
5. Main approves/rejects and updates ledger.
