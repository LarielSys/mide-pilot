param(
    [int]$Port = 8765,
    [string]$Root = "C:\AI Assistant"
)

if (-not (Test-Path $Root)) {
    Write-Error "Root path not found: $Root"
    exit 1
}

$python = "c:/AI Assistant/.venv/Scripts/python.exe"
if (-not (Test-Path $python)) {
    Write-Error "Python executable not found: $python"
    exit 1
}

Set-Location $Root
Write-Host "Serving $Root at http://localhost:$Port/"
& $python -m http.server $Port --directory $Root