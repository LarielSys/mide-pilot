param(
    [int]$IntervalSeconds = 120,
    [string]$MideRoot = "C:\AI Assistant\MIDE"
)

$TaskA = "MTASK-0038"
$TaskB = "MTASK-0039"

function Log([string]$msg, [string]$level = "INFO") {
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    Write-Host ("[$ts] [$level] " + $msg)
}

function Get-Result([string]$taskId) {
    $path = Join-Path $MideRoot ("pilot_v1\results\" + $taskId + ".result.json")
    if (Test-Path $path) {
        try { return Get-Content $path | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

$seen38 = $false
$seen39 = $false
$cycle = 0

Log ("Watcher started for " + $TaskA + " -> " + $TaskB + " every " + $IntervalSeconds + "s") "OK"

while ($true) {
    $cycle++
    Push-Location $MideRoot
    git pull --ff-only origin main 2>$null | Out-Null
    Pop-Location

    $r38 = Get-Result $TaskA
    $r39 = Get-Result $TaskB

    if ($r38 -and -not $seen38) {
        $seen38 = $true
        Log ($TaskA + " result detected: " + $r38.execution_status + " | " + $r38.summary) "OK"
    }

    if ($seen38 -and -not $seen39) {
        if ($r39) {
            $seen39 = $true
            Log ($TaskB + " result detected: " + $r39.execution_status + " | " + $r39.summary) "OK"
        } else {
            Log ($TaskA + " done; waiting for " + $TaskB + " pickup...") "INFO"
        }
    }

    if (-not $seen38 -and -not $r38) {
        Log ("No result yet for " + $TaskA + " (cycle " + $cycle + ")") "INFO"
    }

    if ($seen38 -and $seen39) {
        Log ("Both tasks observed. Monitor exiting.") "OK"
        break
    }

    Start-Sleep -Seconds $IntervalSeconds
}
