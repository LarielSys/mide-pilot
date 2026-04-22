param(
  [Parameter(Mandatory = $true)]
  [string]$TaskId,
  [string]$User = "larieladmin",
  [string]$RemoteHost = "47.17.251.15",
  [string]$RemoteBase = "/home/larieladmin/Documents/itheia-llm/MIDE/pilot_v1",
  [string]$LocalBase = "c:\AI Assistant\MIDE\pilot_v1",
  [string]$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
)

$localTask = Join-Path $LocalBase ("tasks\" + $TaskId + ".json")
if (-not (Test-Path $localTask)) {
  Write-Error "Task file not found: $localTask"
  exit 1
}

$remoteTarget = "${User}@${RemoteHost}:$RemoteBase/tasks/"
Write-Host "Pushing $localTask to $remoteTarget"
$scpExe = (Get-Command scp.exe -ErrorAction Stop).Source
$scpArgs = @()
if (Test-Path $KeyPath) {
  $scpArgs += @("-i", $KeyPath)
}
$scpArgs += @($localTask, $remoteTarget)
& $scpExe @scpArgs
if ($LASTEXITCODE -ne 0) {
  Write-Error "scp failed while pushing task"
  exit $LASTEXITCODE
}

Write-Host "Done. Task pushed to Ubuntu worker."