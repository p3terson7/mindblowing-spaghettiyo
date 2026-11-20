#requires -Version 5.1
[CmdletBinding()]
param([string]$DataFolder = '', [switch]$Apply, [switch]$AppStopped)
$ErrorActionPreference = 'Stop'
if ($Apply -and -not $AppStopped) { throw 'Stop SAPHIR on ALL computers, then supply -Apply -AppStopped. Preview needs neither switch.' }
$distributionRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lib/LocalAppCache.ps1')
$cacheRoot = Get-SaphirLocalAppRoot
$cacheMutex = Enter-SaphirCacheMutex -CacheRoot $cacheRoot
try {
    # Select only the manifest's verified current release. Do not start a
    # backend, open a browser, or fall back to an older active release.
    $release = Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath (Join-Path $distributionRoot 'deployment/current.json') -CacheRoot $cacheRoot
    $migrationScript = Join-Path $release.ReleasePath 'scripts/backfill-compensation.ps1'
    $applicationRoot = Join-Path $release.ReleasePath 'app'
    if (-not [IO.File]::Exists($migrationScript)) { throw 'The current release does not include the compensation migration. Publish a full updated release first.' }
    if (-not $DataFolder) { $DataFolder = [string]$release.DataFolderPath }
    Write-Host "Using published release: $($release.ReleaseId)"
    Write-Host "DATA: $DataFolder"
    & $migrationScript -DataFolder $DataFolder -ApplicationRoot $applicationRoot -Apply:$Apply -AppStopped:$AppStopped
} finally { Exit-SaphirCacheMutex $cacheMutex }
