param(
    [switch]$Background,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$params = @{}
if ($Background) { $params.Background = $true }
if ($Force) { $params.Force = $true }

Write-Host "The employee backend has been merged into the unified app backend."
& (Join-Path -Path $scriptDir -ChildPath "start-app.ps1") @params
