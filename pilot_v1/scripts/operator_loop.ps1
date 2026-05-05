# MIDE Autonomous Operator Loop
# Runs on Windows, polls GitHub every 60s, reads results, issues next mtasks automatically.
# Start: .\pilot_v1\scripts\operator_loop.ps1
# Stop: Ctrl+C or close terminal

param(
    [string]$RepoRoot = "C:\AI Assistant\MIDE",
    [int]$PollSeconds = 60
)

Set-Location $RepoRoot

$ProcessedLog  = "$RepoRoot\pilot_v1\state\operator_loop_processed.json"
$OperatorLog   = "$RepoRoot\pilot_v1\state\operator_loop.log"
$TasksDir      = "$RepoRoot\pilot_v1\tasks"
$ResultsDir    = "$RepoRoot\pilot_v1\results"
$ScriptsDir    = "$RepoRoot\pilot_v1\scripts"

function Write-Log($msg) {
    $ts = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $OperatorLog -Value $line
}

function Get-Processed {
    if (Test-Path $ProcessedLog) {
        return (Get-Content $ProcessedLog | ConvertFrom-Json)
    }
    return @{ processed = @() }
}

function Save-Processed($data) {
    $data | ConvertTo-Json -Depth 5 | Set-Content $ProcessedLog
}

function Get-NextTaskNumber {
    $existing = Get-ChildItem $TasksDir -Filter "MTASK-*.json" |
        Where-Object { $_.Name -match "^MTASK-(\d+)\.json$" } |
        ForEach-Object { [int]$Matches[1] } |
        Sort-Object -Descending
    return ($existing | Select-Object -First 1) + 1
}

function Get-RetryNumber($taskId) {
    $base = $taskId -replace "-RETRY\d+$", ""
    $existing = Get-ChildItem $TasksDir -Filter "${base}-RETRY*.json" |
        ForEach-Object { 
            if ($_.Name -match "RETRY(\d+)") { [int]$Matches[1] } 
        } | Sort-Object -Descending
    $last = $existing | Select-Object -First 1
    if ($null -eq $last) { return 1 }
    return $last + 1
}

function Push-ToGit($message) {
    git -C $RepoRoot add pilot_v1/tasks/ pilot_v1/scripts/ 2>&1 | Out-Null
    $diff = git -C $RepoRoot diff --cached --stat 2>&1
    if ($diff -match "\d+ file") {
        git -C $RepoRoot commit -m $message 2>&1 | Out-Null
        git -C $RepoRoot pull origin main --rebase --quiet 2>&1 | Out-Null
        git -C $RepoRoot push origin main 2>&1 | Out-Null
        Write-Log "GIT PUSH: $message"
        return $true
    }
    return $false
}

function Issue-RetryTask($result) {
    $taskId   = $result.task_id
    $retryNum = Get-RetryNumber $taskId
    $retryId  = "$taskId-RETRY$retryNum"

    # Find original task to clone
    $origBase = $taskId -replace "-RETRY\d+$", ""
    $origFile = "$TasksDir\${origBase}.json"
    if (-not (Test-Path $origFile)) {
        Write-Log "RETRY SKIPPED: Cannot find original task file $origFile"
        return
    }

    $orig = Get-Content $origFile | ConvertFrom-Json
    $orig.task_id = $retryId
    $orig.timestamp_utc = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    $orig.objective = "RETRY${retryNum}: " + $orig.objective

    $retryFile = "$TasksDir\${retryId}.json"
    $orig | ConvertTo-Json -Depth 10 | Set-Content $retryFile
    Write-Log "RETRY CREATED: $retryId (reason: $($result.summary))"

    Push-ToGit "operator-loop: $retryId auto-retry"
}

function Issue-NextTask($completedId) {
    # Pipeline definition: after X completes, issue Y
    # Add entries here as the project grows
    $pipeline = @{
        "MTASK-0097" = @{
            id        = "MTASK-0098"
            objective = "code-server is UP (MTASK-0097). Now restart site_kb_server on port 8091 and verify. Check if site_kb_server process exists, find its start script, restart detached, confirm HTTP 200 on port 8091."
            script    = "exec_mtask_0098_restart_site_kb_server.sh"
            script_body = @'
#!/usr/bin/env bash
set -euo pipefail
echo "task=MTASK-0098"
echo "objective=restart_site_kb_server"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

KB_PORT=8091
REPO_ROOT="/home/larieladmin/mide-pilot"

# Check what is on port 8091
CURRENT=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${KB_PORT} 2>/dev/null || echo "000")
echo "current_port${KB_PORT}=${CURRENT}"

# Find site_kb_server start script
KB_SCRIPT=$(find "$REPO_ROOT" -name "*.sh" -o -name "*.py" 2>/dev/null | xargs grep -l "site_kb\|8091\|knowledge" 2>/dev/null | head -5 || echo "")
echo "kb_scripts_found=${KB_SCRIPT}"

# Look for a running process
KB_PID=$(pgrep -f "site_kb\|8091" 2>/dev/null | head -1 || echo "none")
echo "kb_pid=${KB_PID}"

# Try to find and start the server
KB_APP=$(find "$REPO_ROOT" -name "app.py" -o -name "server.py" -o -name "main.py" 2>/dev/null | xargs grep -l "8091\|site_kb" 2>/dev/null | head -1 || echo "")
if [[ -n "$KB_APP" ]]; then
  pkill -f "site_kb\|8091" 2>/dev/null || true
  sleep 2
  cd "$(dirname "$KB_APP")"
  nohup python3 "$(basename "$KB_APP")" > /tmp/site_kb_server.log 2>&1 &
  KB_NEW_PID=$!
  echo "kb_server_started_pid=${KB_NEW_PID}"
  sleep 5
  NEW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${KB_PORT} 2>/dev/null || echo "000")
  echo "port${KB_PORT}_after_start=${NEW_STATUS}"
  if [[ "$NEW_STATUS" == "200" || "$NEW_STATUS" == "302" || "$NEW_STATUS" == "404" ]]; then
    echo "site_kb_status=UP"
  else
    echo "site_kb_status=FAIL_HTTP_${NEW_STATUS}"
    echo "log_tail=$(tail -10 /tmp/site_kb_server.log 2>/dev/null || echo none)"
  fi
else
  echo "site_kb_status=NO_APP_FOUND"
  echo "diagnosis=need_to_locate_or_identify_kb_server_entrypoint"
fi
echo "snapshot=complete"
'@
        }
        "MTASK-0098" = @{
            id        = "MTASK-0099"
            objective = "Both code-server and site_kb_server recovery attempted. Run full stack verification: check all 5 services (customide backend 5555, frontend 5570, ollama 11434, code-server 8092, site_kb 8091), confirm ngrok tunnel covers correct ports, update worker1_services.json with current status."
            script    = "exec_mtask_0099_full_stack_verify.sh"
            script_body = $null  # will build when needed
        }
    }

    if (-not $pipeline.ContainsKey($completedId)) {
        Write-Log "NO PIPELINE ENTRY for $completedId — operator input needed for next step"
        return
    }

    $next = $pipeline[$completedId]
    $taskFile   = "$TasksDir\$($next.id).json"
    $scriptFile = "$ScriptsDir\$($next.script)"

    if (Test-Path $taskFile) {
        Write-Log "NEXT TASK $($next.id) already exists, skipping"
        return
    }

    # Write executor script if body provided
    if ($null -ne $next.script_body) {
        $next.script_body | Set-Content $scriptFile
        Write-Log "SCRIPT WRITTEN: $($next.script)"
    }

    # Write task JSON
    @{
        task_id              = $next.id
        created_by           = "windows-main"
        worker_name          = "ubuntu-atlas-01"
        assigned_to          = "ubuntu-worker-01"
        required_worker_id   = "ubuntu-worker-01"
        objective            = $next.objective
        executor_script      = "pilot_v1/scripts/$($next.script)"
        moss_labels          = @("moss/customide", "worker/operations")
        priority             = "high"
        risk_level           = "low"
        automation_mode      = "auto"
        admin_override_allowed = $false
        allowed_paths        = @("pilot_v1/results", "pilot_v1/state", "pilot_v1/config")
        blocked_paths        = @("pilot_v1/tasks", "pilot_v1/approvals")
        required_validation  = @("snapshot=complete")
        dependencies         = @()
        timeout_seconds      = 180
        status               = "approved_to_execute"
        issued_by            = "operator-loop-windows"
        timestamp_utc        = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json -Depth 10 | Set-Content $taskFile

    Write-Log "NEXT TASK ISSUED: $($next.id)"
    Push-ToGit "operator-loop: $($next.id) auto-issued after $completedId"
}

# ── MAIN LOOP ──────────────────────────────────────────────────────────────────

Write-Log "=== OPERATOR LOOP STARTED | poll=${PollSeconds}s | repo=$RepoRoot ==="
$state = Get-Processed

while ($true) {
    # 1. Pull latest from GitHub
    $pullOut = git -C $RepoRoot pull origin main --rebase --quiet 2>&1
    if ($pullOut -match "error|fatal") {
        Write-Log "GIT PULL ERROR: $pullOut"
    }

    # 2. Scan results for unprocessed files
    $results = Get-ChildItem $ResultsDir -Filter "*.result.json" |
        Sort-Object LastWriteTime

    foreach ($file in $results) {
        $id = $file.BaseName -replace "\.result$", ""
        if ($state.processed -contains $id) { continue }

        $result = Get-Content $file.FullName | ConvertFrom-Json
        $status = $result.execution_status

        Write-Log "NEW RESULT: $id | status=$status"

        if ($status -eq "completed") {
            Write-Log "  -> SUCCESS: issuing next task in pipeline"
            Issue-NextTask $id
        }
        elseif ($status -eq "failed") {
            $retryCount = ($state.processed | Where-Object { $_ -match "^${id}-RETRY" }).Count
            if ($retryCount -lt 2) {
                Write-Log "  -> FAILED: issuing retry ($retryCount previous retries)"
                Issue-RetryTask $result
            } else {
                Write-Log "  -> FAILED: max retries reached for $id — operator input needed"
            }
        }

        # Mark processed
        $state.processed += $id
        Save-Processed $state
    }

    Write-Log "poll: sleeping ${PollSeconds}s..."
    Start-Sleep -Seconds $PollSeconds
}
