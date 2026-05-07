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
        git -C $RepoRoot pull origin main --no-rebase --quiet 2>&1 | Out-Null
        git -C $RepoRoot push origin main 2>&1 | Out-Null
        Write-Log "GIT PUSH: $message"
        return $true
    }
    return $false
}

function Issue-RetryTask($result) {
    $taskId   = $result.task_id

    # Find original base task (strip any existing -RETRYn suffix)
    $origBase = $taskId -replace "(-RETRY\d+)+$", ""
    $retryNum = Get-RetryNumber $origBase
    $retryId  = "$origBase-RETRY$retryNum"
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
    # Script bodies stored as variables (heredocs not valid inside hashtables in PS)
    $script_0098 = "#!/usr/bin/env bash`nset -euo pipefail`necho task=MTASK-0098`necho objective=restart_site_kb_server`necho timestamp_utc=`$(date -u +`"%Y-%m-%dT%H:%M:%SZ`")`nKB_PORT=8091`nREPO_ROOT=/home/larieladmin/mide-pilot`nCURRENT=`$(curl -s -o /dev/null -w `"%{http_code}`" http://127.0.0.1:`${KB_PORT} 2>/dev/null || echo 000)`necho current_port`${KB_PORT}=`${CURRENT}`nKB_PID=`$(pgrep -f site_kb 2>/dev/null | head -1 || echo none)`necho kb_pid=`${KB_PID}`nKB_APP=`$(find `"`$REPO_ROOT`" -name app.py -o -name server.py 2>/dev/null | xargs grep -l 8091 2>/dev/null | head -1 || echo ``)`nif [[ -n `"`$KB_APP`" ]]; then`n  pkill -f site_kb 2>/dev/null || true`n  sleep 2`n  cd `"`$(dirname `"`$KB_APP`")`"`n  nohup python3 `"`$(basename `"`$KB_APP`")`" > /tmp/site_kb_server.log 2>&1 &`n  sleep 5`n  NEW_STATUS=`$(curl -s -o /dev/null -w `"%{http_code}`" http://127.0.0.1:`${KB_PORT} 2>/dev/null || echo 000)`n  echo port`${KB_PORT}_after_start=`${NEW_STATUS}`n  if [[ `"`$NEW_STATUS`" == 200 || `"`$NEW_STATUS`" == 302 || `"`$NEW_STATUS`" == 404 ]]; then echo site_kb_status=UP; else echo site_kb_status=FAIL_HTTP_`${NEW_STATUS}; fi`nelse`n  echo site_kb_status=NO_APP_FOUND`nfi`necho snapshot=complete"

    # Pipeline definition: after X completes, issue Y
    # script_body = $null means the executor script already exists on disk
    $pipeline = @{
        "MTASK-0097" = @{
            id          = "MTASK-0098"
            objective   = "code-server is UP (MTASK-0097). Restart site_kb_server on port 8091: find its entrypoint, kill stale, start detached, verify HTTP response."
            script      = "exec_mtask_0098_restart_site_kb_server.sh"
            script_body = $script_0098
        }
        "MTASK-0098" = @{
            id          = "MTASK-0099"
            objective   = "Recovery complete. Run full stack verification: check all services (5555, 5570, 11434, 8092, 8091), confirm ngrok tunnel, update worker1_services.json with current status."
            script      = "exec_mtask_0099_full_stack_verify.sh"
            script_body = $null
        }
        # ── Tunnel setup chain ────────────────────────────────────────────────
        "MTASK-0103" = @{
            id          = "MTASK-0104"
            objective   = "Diagnose current ngrok tunnel status and Ollama availability (native + Docker). Report all active ngrok tunnels, Docker Ollama containers, native Ollama port 11434 status, and itheia-llm proxy status. Write diagnosis to worker1_services.json."
            script      = "exec_mtask_0104_diagnose_ollama_tunnel.sh"
            script_body = $null
            promote_status = "approved_to_execute"
        }
        "MTASK-0104" = @{
            id          = "MTASK-0105"
            objective   = "Set up a persistent ngrok tunnel for Ollama API so the website chat page can connect. Auto-detect Docker vs native Ollama port, start ngrok on it, retrieve public URL, install systemd service ngrok-ollama for persistence, and write public URL to pilot_v1/state/worker1_services.json."
            script      = "exec_mtask_0105_setup_ollama_tunnel.sh"
            script_body = $null
            promote_status = "approved_to_execute"
        }
        "MTASK-0105" = @{
            id          = "MTASK-0106"
            objective   = "Final end-to-end verification of the Ollama ngrok tunnel. Read the public URL from worker1_services.json, verify /api/tags returns 200, run a live /api/generate test, and write the verified website chat URL into worker1_services.json tunnel_verification block."
            script      = "exec_mtask_0106_verify_ollama_tunnel.sh"
            script_body = $null
            promote_status = "approved_to_execute"
        }
        # ── Token counter + chat.html fix chain ───────────────────────────────
        "MTASK-0106" = @{
            id          = "MTASK-0109"
            objective   = "Pull latest main (fix commit) and restart cockpit FastAPI backend on port 5555. Verify GET /api/status/token-counters returns rows > 0 and correct source. Report rows_count, source, any startup tracebacks."
            script      = "exec_mtask_0109_restart_cockpit_verify_tokens.sh"
            script_body = $null
            promote_status = "approved_to_execute"
        }
        "MTASK-0109" = @{
            id          = "MTASK-0110"
            objective   = "Update larielsystems/chat.html: set CHAT_BACKEND constant to the tunnel base URL read from pilot_v1/state/worker1_services.json (tunnel_verification.website_chat_url minus the /api/chat path suffix). Verify the constant is correct in the file and report the new value."
            script      = "exec_mtask_0110_update_chat_backend_url.sh"
            script_body = $null
            promote_status = "approved_to_execute"
        }
    }

    if (-not $pipeline.ContainsKey($completedId)) {
        # Strip retry suffix and try the base task ID
        $baseCompletedId = $completedId -replace "(-RETRY\d+)+$", ""
        if (-not $pipeline.ContainsKey($baseCompletedId)) {
            Write-Log "NO PIPELINE ENTRY for ${completedId} -- operator input needed for next step"
            return
        }
        $completedId = $baseCompletedId
    }

    $next = $pipeline[$completedId]
    $taskFile   = "$TasksDir\$($next.id).json"
    $scriptFile = "$ScriptsDir\$($next.script)"

    if (Test-Path $taskFile) {
        $existing = Get-Content $taskFile -Raw | ConvertFrom-Json
        if ($existing.status -eq "pending") {
            $existing.status = "approved_to_execute"
            $existing | ConvertTo-Json -Depth 10 | Set-Content $taskFile
            Write-Log "NEXT TASK $($next.id) promoted from pending -> approved_to_execute"
        } else {
            Write-Log "NEXT TASK $($next.id) already exists (status=$($existing.status)), skipping"
        }
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

Write-Log "=== OPERATOR LOOP STARTED | poll=${PollSeconds}s | repo=${RepoRoot} ==="
$state = Get-Processed

while ($true) {
    # 1. Pull latest from GitHub - fetch then merge, auto-resolve conflicts by taking remote
    git -C $RepoRoot fetch origin 2>&1 | Out-Null
    $mergeOut = git -C $RepoRoot merge origin/main -X theirs --no-edit 2>&1
    if ($mergeOut -match "fatal") {
        Write-Log "GIT MERGE ERROR: $mergeOut"
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
            $baseId = $id -replace "(-RETRY\d+)+$", ""
            $retryCount = ($state.processed | Where-Object { $_ -match "^${baseId}-RETRY\d+$" }).Count
            if ($retryCount -lt 2) {
                Write-Log "  -> FAILED: issuing retry (${retryCount} previous retries)"
                Issue-RetryTask $result
            } else {
                Write-Log "  -> FAILED: max retries reached for ${id} -- operator input needed"
            }
        }

        # Mark processed
        $state.processed += $id
        Save-Processed $state
    }

    # Heartbeat — write live timestamp to state so cockpit and Ubuntu can see Windows loop is alive
    $hbTs = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $hbFile = "$RepoRoot\pilot_v1\state\operator_loop_live.txt"
    "operator_loop windows-main $hbTs" | Set-Content $hbFile
    git -C $RepoRoot add "pilot_v1/state/operator_loop_live.txt" 2>&1 | Out-Null
    $hbDiff = git -C $RepoRoot diff --cached --stat 2>&1
    if ($hbDiff -match "operator_loop_live") {
        git -C $RepoRoot commit -m "operator: heartbeat windows-main $hbTs" 2>&1 | Out-Null
        git -C $RepoRoot push origin main 2>&1 | Out-Null
    }

    Write-Log "poll: sleeping ${PollSeconds}s..."
    Start-Sleep -Seconds $PollSeconds
}
