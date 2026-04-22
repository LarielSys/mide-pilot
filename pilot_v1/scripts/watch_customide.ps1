#!/usr/bin/env pwsh
# CustomIDE Auto-Watcher for Windows IDE
# Polls MIDE git repo every 2 minutes, checks MTASK results,
# auto-troubleshoots failures, and updates the project MD log.
# Run: pwsh -File watch_customide.ps1

param(
    [int]$IntervalSeconds = 120,
    [string]$MideRoot = "C:\AI Assistant\MIDE",
    [string]$ProjectMd = "C:\AI Assistant\MIDE\CUSTOMIDE_PROJECT.md"
)

$TASKS_TO_WATCH = @("MTASK-0031","MTASK-0032","MTASK-0033","MTASK-0034")
$MAX_RETRIES = 3
$retryCount = @{}
$TASKS_TO_WATCH | ForEach-Object { $retryCount[$_] = 0 }

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "TASK"  { "Cyan" }
        default { "White" }
    }
    Write-Host "[$ts] [$Level] $Msg" -ForegroundColor $color
}

function Get-TaskResult {
    param([string]$TaskId)
    $path = Join-Path $MideRoot "pilot_v1\results\$TaskId.result.json"
    if (Test-Path $path) {
        try { return Get-Content $path | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Get-TaskDefinition {
    param([string]$TaskId)
    $path = Join-Path $MideRoot "pilot_v1\tasks\$TaskId.json"
    if (Test-Path $path) {
        try { return Get-Content $path | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Dispatch-RetryTask {
    param([string]$TaskId, [int]$Attempt)
    Write-Log "AUTO-TROUBLESHOOT: Dispatching retry for $TaskId (attempt $Attempt)" "WARN"

    # Create a retry task variant
    $retryId = "$TaskId-RETRY$Attempt"
    $origDef = Get-TaskDefinition -TaskId $TaskId
    if (-not $origDef) { Write-Log "Cannot find task definition for $TaskId" "ERROR"; return }

    $retryDef = @{
        task_id        = $retryId
        display_name   = "RETRY $Attempt: $($origDef.display_name)"
        status         = "approved_to_execute"
        required_worker_id = "ubuntu-worker-01"
        executor_script = $origDef.executor_script
        description    = "[AUTO-RETRY attempt $Attempt] $($origDef.description)"
        original_task  = $TaskId
        retry_attempt  = $Attempt
        created_at     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }

    $retryPath = Join-Path $MideRoot "pilot_v1\tasks\$retryId.json"
    $retryDef | ConvertTo-Json -Depth 5 | Set-Content $retryPath

    Push-Location $MideRoot
    git add "pilot_v1/tasks/$retryId.json" 2>$null
    git commit -m "auto-retry: $retryId (watcher auto-troubleshoot)" 2>$null
    git push origin main 2>$null
    Pop-Location

    Write-Log "Retry task $retryId dispatched to Worker 1" "WARN"
}

function Update-ProjectMd {
    param([hashtable]$StatusMap)

    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $lines = @()
    $lines += "<!-- AUTO-UPDATED: $ts -->"
    $lines += ""
    $lines += "## MTASK Status"
    $lines += ""
    $lines += "| Task | Status | Summary | Timestamp |"
    $lines += "|------|--------|---------|-----------|"

    foreach ($taskId in $TASKS_TO_WATCH) {
        $r = $StatusMap[$taskId]
        if ($r) {
            $icon = switch ($r.execution_status) {
                "completed" { "✅" }
                "failed"    { "❌" }
                default     { "🟡" }
            }
            $lines += "| $taskId | $icon $($r.execution_status) | $($r.summary) | $($r.timestamp_utc) |"
        } else {
            $lines += "| $taskId | ⏳ pending | Awaiting Worker 1 | — |"
        }
    }

    $lines += ""
    $lines += "---"
    $lines += "_Last watcher check: $ts_"

    # Read existing MD, replace the status block
    if (Test-Path $ProjectMd) {
        $existing = Get-Content $ProjectMd -Raw
        # Replace between ## MTASK Status and next --- (or EOF)
        $newBlock = $lines -join "`n"
        if ($existing -match "(?s)<!-- AUTO-UPDATED:.*?---\n_Last watcher check:.*?_") {
            $existing = $existing -replace "(?s)<!-- AUTO-UPDATED:.*?---\n_Last watcher check:.*?_", $newBlock
        } else {
            $existing = $existing + "`n`n" + $newBlock
        }
        $existing | Set-Content $ProjectMd
    }
}

function Pull-Repo {
    Push-Location $MideRoot
    $out = git pull origin main 2>&1
    Pop-Location
    return $out
}

# ─── MAIN WATCH LOOP ────────────────────────────────────────────────────────
Write-Log "CustomIDE Watcher started. Interval: ${IntervalSeconds}s. Watching: $($TASKS_TO_WATCH -join ', ')" "OK"
Write-Log "MIDE root: $MideRoot" "INFO"
Write-Log "Project MD: $ProjectMd" "INFO"
Write-Log "Press Ctrl+C to stop." "INFO"
Write-Log "─────────────────────────────────────────────────────" "INFO"

$completedTasks = @{}
$cycle = 0

while ($true) {
    $cycle++
    Write-Log "──── CYCLE $cycle ────────────────────────────────────" "INFO"

    # Pull latest from git
    Write-Log "Pulling repo..." "INFO"
    $pullOut = Pull-Repo
    Write-Log "Git pull: $($pullOut[-1])" "INFO"

    $statusMap = @{}
    $allDone = $true
    $anyFailed = $false

    foreach ($taskId in $TASKS_TO_WATCH) {
        if ($completedTasks[$taskId]) {
            Write-Log "$taskId — already completed ✅" "OK"
            $statusMap[$taskId] = $completedTasks[$taskId]
            continue
        }

        $result = Get-TaskResult -TaskId $taskId
        $statusMap[$taskId] = $result

        if (-not $result) {
            Write-Log "$taskId — ⏳ pending (no result yet)" "TASK"
            $allDone = $false
        } elseif ($result.execution_status -eq "completed") {
            Write-Log "$taskId — ✅ completed: $($result.summary)" "OK"
            $completedTasks[$taskId] = $result
        } elseif ($result.execution_status -eq "failed") {
            Write-Log "$taskId — ❌ FAILED: $($result.summary)" "ERROR"
            $anyFailed = $true
            $allDone = $false

            $retryCount[$taskId]++
            if ($retryCount[$taskId] -le $MAX_RETRIES) {
                Dispatch-RetryTask -TaskId $taskId -Attempt $retryCount[$taskId]
            } else {
                Write-Log "$taskId — Max retries ($MAX_RETRIES) reached. Manual intervention needed." "ERROR"
            }
        } else {
            Write-Log "$taskId — status: $($result.execution_status)" "WARN"
            $allDone = $false
        }
    }

    # Update project MD
    Update-ProjectMd -StatusMap $statusMap

    # Commit watcher update to MD
    Push-Location $MideRoot
    git add "CUSTOMIDE_PROJECT.md" 2>$null | Out-Null
    git diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        git commit -m "watcher: project MD updated cycle $cycle" 2>$null | Out-Null
        git push origin main 2>$null | Out-Null
        Write-Log "Project MD committed (cycle $cycle)" "INFO"
    }
    Pop-Location

    if ($allDone -and -not $anyFailed) {
        Write-Log "═══════════════════════════════════════════════════" "OK"
        Write-Log "ALL TASKS COMPLETE. Worker 1 setup finished! 🎉" "OK"
        Write-Log "═══════════════════════════════════════════════════" "OK"
        Write-Log "Check worker1_services.json for all endpoint URLs." "OK"
        break
    }

    Write-Log "Next check in ${IntervalSeconds}s..." "INFO"
    Start-Sleep -Seconds $IntervalSeconds
}
