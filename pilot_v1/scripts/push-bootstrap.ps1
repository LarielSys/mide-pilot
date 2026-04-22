param(
  [string]$User = "larieladmin",
  [string]$RemoteHost = "47.17.251.15",
  [string]$RemoteRoot = "/home/larieladmin/Documents/itheia-llm/MIDE",
  [string]$LocalPilot = "c:\AI Assistant\MIDE\pilot_v1",
  [string]$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
)

if (-not (Test-Path $LocalPilot)) {
  Write-Error "Local pilot folder not found: $LocalPilot"
  exit 1
}

$remoteSpec = "${User}@${RemoteHost}:$RemoteRoot/"
Write-Host "Copying pilot_v1 to $remoteSpec"
$scpExe = (Get-Command scp.exe -ErrorAction Stop).Source
$scpArgs = @("-r")
if (Test-Path $KeyPath) {
  $scpArgs += @("-i", $KeyPath)
}
$scpArgs += @($LocalPilot, $remoteSpec)
& $scpExe @scpArgs
if ($LASTEXITCODE -ne 0) {
  Write-Error "scp failed while pushing pilot folder"
  exit $LASTEXITCODE
}

Write-Host "Done. pilot_v1 copied to Ubuntu."