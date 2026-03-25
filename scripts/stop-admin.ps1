$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

Write-Host "The admin backend has been merged into the unified app backend."
& (Join-Path -Path $scriptDir -ChildPath "stop-app.ps1")
