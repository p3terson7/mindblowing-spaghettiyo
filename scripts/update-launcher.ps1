# This worker only installs launcher files. It never touches shared DATA.
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
$localRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SAPHIR'
$logRoot = Join-Path $localRoot 'runtime/logs'
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    . (Join-Path $PSScriptRoot 'lib/LauncherUpdate.ps1')
    $origin = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'launcher-origin.json')) | ConvertFrom-Json -ErrorAction Stop
    $distribution = [string]$origin.distributionRoot
    if (-not [IO.Path]::IsPathRooted($distribution)) { throw 'The published launcher origin must be an absolute path.' }
    $result = Update-SaphirLauncherFromDistribution -DistributionRoot $distribution -LauncherRoot (Join-Path $localRoot 'launcher')
    [IO.Directory]::CreateDirectory($logRoot) | Out-Null
    Add-Content -LiteralPath (Join-Path $logRoot 'launcher-update.log') -Value ((Get-Date -Format o) + ' ' + $result) -Encoding UTF8
} catch {
    try {
        [IO.Directory]::CreateDirectory($logRoot) | Out-Null
        Add-Content -LiteralPath (Join-Path $logRoot 'launcher-update.log') -Value ((Get-Date -Format o) + ' failed: ' + $_.Exception.Message) -Encoding UTF8
    } catch { }
    # Installing a launcher is optional to app readiness. Log the real error
    # and leave the existing bundle/pointer available; retry on the next start.
    exit 1
}
