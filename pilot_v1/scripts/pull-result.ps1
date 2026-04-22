param(
  [Parameter(Mandatory = $true)]
  [string]$TaskId,
  [string]$User = "larieladmin",
  [string]$RemoteHost = "47.17.251.15",
  [string]$RemoteBase = "/home/larieladmin/Documents/itheia-llm/MIDE/pilot_v1",
  [string]$LocalBase = "c:\AI Assistant\MIDE\pilot_v1",
  [string]$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
)

$localResultsDir = Join-Path $LocalBase "results"
if (-not (Test-Path $localResultsDir)) {
  New-Item -ItemType Directory -Path $localResultsDir | Out-Null
}

$remoteFile = "${User}@${RemoteHost}:$RemoteBase/results/$TaskId.result.json"
$localFile = Join-Path $localResultsDir ("$TaskId.result.json")

Write-Host "Pulling $remoteFile to $localFile"
$scpExe = (Get-Command scp.exe -ErrorAction Stop).Source
$scpArgs = @()
if (Test-Path $KeyPath) {
  $scpArgs += @("-i", $KeyPath)
}
$scpArgs += @($remoteFile, $localFile)
& $scpExe @scpArgs
if ($LASTEXITCODE -ne 0) {
  Write-Error "scp failed while pulling result"
  exit $LASTEXITCODE
}

Write-Host "Done. Result pulled from Ubuntu worker."