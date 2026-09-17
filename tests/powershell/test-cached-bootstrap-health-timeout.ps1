$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Ensure-TestDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-TestBootstrap {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$BootstrapPath
    )

    $output = @(& $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $BootstrapPath -NonInteractive 2>&1)
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-bootstrap-health-{0}" -f [Guid]::NewGuid().ToString("N"))
$distributionRoot = Join-Path -Path $testRoot -ChildPath "distribution"
$distributionScripts = Join-Path -Path $distributionRoot -ChildPath "scripts"
$releasePath = Join-Path -Path $testRoot -ChildPath "cache/versions/current"
$launchMarker = Join-Path -Path $testRoot -ChildPath "launches.txt"
$repairMarker = Join-Path -Path $testRoot -ChildPath "repair.txt"
$previousCacheRoot = [string]$env:SAPHIR_APP_CACHE_ROOT
$previousRuntimeRoot = [string]$env:SAPHIR_RUNTIME_ROOT
$previousLaunchMarker = [string]$env:SAPHIR_BOOTSTRAP_TEST_MARKER
$previousRepairMarker = [string]$env:SAPHIR_BOOTSTRAP_TEST_REPAIR_MARKER
$previousReleasePath = [string]$env:SAPHIR_BOOTSTRAP_TEST_RELEASE_PATH
$previousListenerState = [string]$env:SAPHIR_BOOTSTRAP_TEST_LISTENER

try {
    Ensure-TestDirectory -Path (Join-Path -Path $distributionScripts -ChildPath "lib")
    Ensure-TestDirectory -Path (Join-Path -Path $distributionRoot -ChildPath "deployment")
    Ensure-TestDirectory -Path (Join-Path -Path $releasePath -ChildPath "scripts")
    Ensure-TestDirectory -Path (Join-Path -Path $releasePath -ChildPath "app/backend/services")
    Ensure-TestDirectory -Path (Join-Path -Path $releasePath -ChildPath "app/frontend")

    Copy-Item `
        -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/launch-cached-app.ps1") `
        -Destination (Join-Path -Path $distributionScripts -ChildPath "launch-cached-app.ps1") `
        -Force
    Copy-Item `
        -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/lib/ApplicationLayout.ps1") `
        -Destination (Join-Path -Path $distributionScripts -ChildPath "lib/ApplicationLayout.ps1") `
        -Force

    Set-Content -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value "{}" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releasePath -ChildPath "app/backend/saphir-server.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releasePath -ChildPath "app/backend/saphir-config.psd1") -Value "@{ DataFolderPath = 'fixture' }" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releasePath -ChildPath "app/backend/services/RouteDispatchService.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releasePath -ChildPath "app/frontend/index.html") -Value "<html>fixture</html>" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releasePath -ChildPath "scripts/launch-app.ps1") -Value @'
param([switch]$Force)
Add-Content -LiteralPath $env:SAPHIR_BOOTSTRAP_TEST_MARKER -Value ([string][bool]$Force) -Encoding ASCII
throw "Simulated readiness timeout while the managed backend remains active."
'@ -Encoding UTF8

    Set-Content -LiteralPath (Join-Path -Path $distributionScripts -ChildPath "lib/LocalAppCache.ps1") -Value @'
function Get-SaphirLocalAppRoot { return $env:SAPHIR_APP_CACHE_ROOT }
function Get-SaphirActiveRelease {
    return [PSCustomObject]@{
        ReleaseId = "current"
        ReleasePath = $env:SAPHIR_BOOTSTRAP_TEST_RELEASE_PATH
        LaunchScript = (Join-Path -Path $env:SAPHIR_BOOTSTRAP_TEST_RELEASE_PATH -ChildPath "scripts/launch-app.ps1")
        Sha256 = ("a" * 64)
        Installed = $false
    }
}
function Enter-SaphirCacheMutex { return $null }
function Exit-SaphirCacheMutex { param($Mutex) }
function Repair-SaphirInterruptedCacheOperations { param($CacheRoot) }
function Read-SaphirReleaseManifest {
    return [PSCustomObject]@{
        ReleaseId = "current"
        Sha256 = ("a" * 64)
        DataFolderPath = "fixture"
    }
}
function Get-SaphirFailedRelease { return $null }
function Install-SaphirCachedRelease {
    param($Manifest, $CacheRoot, [switch]$ForceReinstall)
    if ($ForceReinstall) {
        Set-Content -LiteralPath $env:SAPHIR_BOOTSTRAP_TEST_REPAIR_MARKER -Value "repair attempted" -Encoding ASCII
    }
    return (Get-SaphirActiveRelease)
}
function Set-SaphirActiveRelease { param($CacheRoot, $Release) }
function Remove-SaphirFailedRelease { param($CacheRoot) }
function Remove-OldSaphirCachedReleases { param($CacheRoot, $KeepReleaseIds, $MaximumVersionCount) }
'@ -Encoding UTF8

    Set-Content -LiteralPath (Join-Path -Path $distributionScripts -ChildPath "lib/ServerControl.ps1") -Value @'
function Test-ManagedServiceHealthyForScript { return $false }
function Get-ServiceStatus {
    $isRunning = [string]$env:SAPHIR_BOOTSTRAP_TEST_LISTENER -ne "offline"
    return [PSCustomObject]@{
        IsRunning = $isRunning
        TrackedProcessId = if ($isRunning) { 4242 } else { $null }
        MetadataProcessId = if ($isRunning) { 4242 } else { $null }
    }
}
function Find-ServiceProcessesByScriptPath { return @() }
function Open-UriInDefaultBrowser { param($Uri) }
'@ -Encoding UTF8

    $powerShellCommand = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $powerShellCommand) {
        $powerShellCommand = Get-Command -Name "powershell" -ErrorAction Stop
    }

    $env:SAPHIR_APP_CACHE_ROOT = Join-Path -Path $testRoot -ChildPath "cache"
    $env:SAPHIR_RUNTIME_ROOT = Join-Path -Path $testRoot -ChildPath "runtime"
    $env:SAPHIR_BOOTSTRAP_TEST_RELEASE_PATH = $releasePath
    $env:SAPHIR_BOOTSTRAP_TEST_MARKER = $launchMarker
    $env:SAPHIR_BOOTSTRAP_TEST_REPAIR_MARKER = $repairMarker
    $env:SAPHIR_BOOTSTRAP_TEST_LISTENER = "active"

    $result = Invoke-TestBootstrap `
        -PowerShellPath $powerShellCommand.Source `
        -BootstrapPath (Join-Path -Path $distributionScripts -ChildPath "launch-cached-app.ps1")

    Assert-True -Condition ($result.ExitCode -ne 0) -Message "the bootstrap must report the inconclusive readiness failure"
    Assert-True -Condition (Test-Path -LiteralPath $launchMarker -PathType Leaf) -Message "the normal cached launch must be attempted once"
    $launches = @(Get-Content -LiteralPath $launchMarker | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert-True -Condition ($launches.Count -eq 1 -and $launches[0] -eq "False") -Message "a health timeout must not be retried with -Force"
    Assert-True -Condition (-not (Test-Path -LiteralPath $repairMarker)) -Message "an active managed listener must block automatic cache repair"
    Assert-True `
        -Condition (($result.Output -join " ") -match "did not repair its files") `
        -Message ("the failure must explain the safe refusal. Output: {0}" -f ($result.Output -join " | "))

    Remove-Item -LiteralPath $launchMarker -Force
    $env:SAPHIR_BOOTSTRAP_TEST_LISTENER = "offline"
    $offlineResult = Invoke-TestBootstrap `
        -PowerShellPath $powerShellCommand.Source `
        -BootstrapPath (Join-Path -Path $distributionScripts -ChildPath "launch-cached-app.ps1")

    Assert-True -Condition ($offlineResult.ExitCode -ne 0) -Message "the simulated repaired launcher still fails intentionally"
    Assert-True -Condition (Test-Path -LiteralPath $repairMarker -PathType Leaf) -Message "a proven-offline failed launch may still repair its cached files"
    $offlineLaunches = @(Get-Content -LiteralPath $launchMarker | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert-True -Condition ($offlineLaunches.Count -eq 2) -Message "a proven-offline failed launch must get exactly one repair retry"
    Assert-True -Condition ($offlineLaunches[0] -eq "False" -and $offlineLaunches[1] -eq "True") -Message "the one repair retry may use -Force only after offline identity checks pass"

    Write-Host "Cached bootstrap health-timeout safety test passed."
}
finally {
    $env:SAPHIR_APP_CACHE_ROOT = $previousCacheRoot
    $env:SAPHIR_RUNTIME_ROOT = $previousRuntimeRoot
    $env:SAPHIR_BOOTSTRAP_TEST_MARKER = $previousLaunchMarker
    $env:SAPHIR_BOOTSTRAP_TEST_REPAIR_MARKER = $previousRepairMarker
    $env:SAPHIR_BOOTSTRAP_TEST_RELEASE_PATH = $previousReleasePath
    $env:SAPHIR_BOOTSTRAP_TEST_LISTENER = $previousListenerState
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
