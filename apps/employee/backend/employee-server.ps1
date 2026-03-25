$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path $scriptDir "../../..")).Path
$unifiedServerScript = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/admin-server.ps1"

if (-not (Test-Path -Path $unifiedServerScript)) {
    throw "Unified backend script not found: $unifiedServerScript"
}

Write-Host "The employee backend has been merged into the unified backend. Starting the shared server..."
& $unifiedServerScript
