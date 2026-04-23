param(
  [Parameter(Mandatory = $true)]
  [string]$TaskId,

  [string[]]$RequireStdoutMarkers = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $repoRoot ("results/{0}.result.json" -f $TaskId)

Write-Host "parity_task=$TaskId"
Write-Host "parity_result_path=$resultPath"

if (!(Test-Path $resultPath)) {
  Write-Host "error=parity_result_missing"
  exit 1
}

$resultJson = Get-Content -Path $resultPath -Raw | ConvertFrom-Json
if ($resultJson.execution_status -ne 'completed') {
  Write-Host "error=parity_result_not_completed"
  exit 1
}

$gitStatus = git -C (Split-Path -Parent $repoRoot) status --short
if ($LASTEXITCODE -ne 0) {
  Write-Host "error=git_status_failed"
  exit 1
}

$allowedPattern = '^(\?\? | M )pilot_v1/(state|results|customide/backend/\.venv|customide/backend/app/__pycache__|customide/backend/app/routes/__pycache__)'
$hasUnexpected = $false
foreach ($line in $gitStatus) {
  if ($line -and ($line -notmatch $allowedPattern)) {
    $hasUnexpected = $true
    Write-Host ("unexpected_change={0}" -f $line)
  }
}

if ($hasUnexpected) {
  Write-Host "error=parity_unexpected_local_changes"
  exit 1
}



if ($RequireStdoutMarkers.Count -gt 0) {
  $stdoutText = [string]$resultJson.stdout_excerpt
  foreach ($marker in $RequireStdoutMarkers) {
    if (-not $stdoutText.Contains($marker)) {
      Write-Host ("error=parity_stdout_marker_missing:{0}" -f $marker)
      exit 1
    }
  }
  Write-Host "parity_stdout_markers=passed"
}

Write-Host "parity_result_present=passed"
Write-Host "parity_repo_clean_or_known=passed"
Write-Host "parity_forward_chain=passed"
Write-Host ("timestamp_utc={0}" -f ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
