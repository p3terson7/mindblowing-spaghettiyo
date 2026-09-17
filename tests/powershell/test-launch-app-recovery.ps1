$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-launch-recovery {0}" -f [Guid]::NewGuid().ToString("N"))
$fixtureScripts = Join-Path -Path $testRoot -ChildPath "scripts"
$fixtureLib = Join-Path -Path $fixtureScripts -ChildPath "lib"
$fixtureServerScript = Join-Path -Path $testRoot -ChildPath "app/backend/saphir-server.ps1"
$forceMarker = Join-Path -Path $testRoot -ChildPath "force-marker.txt"
$previousServerScript = [string]$env:SAPHIR_TEST_SERVER_SCRIPT
$previousForceMarker = [string]$env:SAPHIR_TEST_FORCE_MARKER
$previousStatusMode = [string]$env:SAPHIR_TEST_STATUS_MODE

try {
    New-Item -ItemType Directory -Path $fixtureLib -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Path $fixtureServerScript -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/launch-app.ps1") -Destination (Join-Path -Path $fixtureScripts -ChildPath "launch-app.ps1") -Force
    Set-Content -LiteralPath $fixtureServerScript -Value "# fixture" -Encoding UTF8

    Set-Content -LiteralPath (Join-Path -Path $fixtureLib -ChildPath "ServerControl.ps1") -Value @'
function Test-IsWindowsHost { return $false }

function Get-ManagedServiceLaunchPlan {
    param($IsRunning, $HasTrackedProcess, $IsExpectedManagedInstance, $FrontendIsAvailable, [switch]$Force)

    if ($IsExpectedManagedInstance -and $FrontendIsAvailable -and -not $Force) {
        return [PSCustomObject]@{ Action = "Reuse"; ForceRestart = $false }
    }
    if ($IsRunning -and -not $HasTrackedProcess -and -not $Force) {
        return [PSCustomObject]@{ Action = "Block"; ForceRestart = $false }
    }
    if ($IsRunning -and $HasTrackedProcess -and $IsExpectedManagedInstance -and -not $FrontendIsAvailable -and -not $Force) {
        return [PSCustomObject]@{ Action = "Block"; ForceRestart = $false }
    }

    $restartTrackedService = $HasTrackedProcess -and (-not $IsExpectedManagedInstance -or -not $IsRunning)
    $forceRestart = [bool]($Force -or $restartTrackedService)
    return [PSCustomObject]@{
        Action       = if ($forceRestart) { "Restart" } else { "Start" }
        ForceRestart = $forceRestart
    }
}

function Test-ManagedServiceHealthyForScript {
    param($Name, $DisplayName, $ServerScript, $Port, $PidFile, $FrontendUrl, $TimeoutMilliseconds)
    return $false
}

function Get-ServiceStatus {
    param($Name, $DisplayName, $Port, $PidFile)
    $isUntracked = $env:SAPHIR_TEST_STATUS_MODE -eq "untracked"
    return [PSCustomObject]@{
        IsRunning       = $true
        PortOwnerId     = 999
        TrackedProcessId = if ($isUntracked) { $null } else { 123 }
        Metadata        = if ($isUntracked) { $null } else { [PSCustomObject]@{ scriptPath = $env:SAPHIR_TEST_SERVER_SCRIPT; instanceToken = "fixture-token" } }
    }
}

function Start-ManagedService {
    param($Name, $DisplayName, $ServerScript, $Port, $PidFile, $StdOutLog, $StdErrLog, $WorkingDirectory, [switch]$Force)
    Set-Content -LiteralPath $env:SAPHIR_TEST_FORCE_MARKER -Value ([string][bool]$Force) -Encoding ASCII
}

function Stop-ManagedService { param($Name, $DisplayName, $Port, $PidFile, $ServerScript, [switch]$Quiet) }

function Open-UriInDefaultBrowser { param($Uri) }
'@ -Encoding UTF8

    Set-Content -LiteralPath (Join-Path -Path $fixtureLib -ChildPath "RuntimeLayout.ps1") -Value @'
function Get-ManagedServiceConfig {
    param($Name)
    return [PSCustomObject]@{
        Name             = "app"
        DisplayName      = "SAPHIR fixture"
        Port             = 1
        PidFile          = "fixture.pid"
        StdOutLog        = "fixture.stdout"
        StdErrLog        = "fixture.stderr"
        WorkingDirectory = $env:TEMP
        ServerScript     = $env:SAPHIR_TEST_SERVER_SCRIPT
        FrontendUrl      = "http://127.0.0.1:1/"
    }
}

function Get-PreviousProductServiceConfigs { return @() }
'@ -Encoding UTF8

    $env:SAPHIR_TEST_SERVER_SCRIPT = $fixtureServerScript
    $env:SAPHIR_TEST_FORCE_MARKER = $forceMarker
    try {
        & (Join-Path -Path $fixtureScripts -ChildPath "launch-app.ps1")
    }
    catch {
        # A short failed health probe must block automatic process replacement.
    }

    if (Test-Path -LiteralPath $forceMarker -PathType Leaf) {
        throw "Assertion failed: a short health timeout must not reach the force-restart call."
    }

    try {
        & (Join-Path -Path $fixtureScripts -ChildPath "launch-app.ps1") -Force
    }
    catch {
        # The fake URL deliberately stays unavailable after the explicit restart.
    }
    if (-not (Test-Path -LiteralPath $forceMarker -PathType Leaf) -or
        (Get-Content -LiteralPath $forceMarker -Raw).Trim() -ne "True") {
        throw "Assertion failed: only an explicit -Force request may restart the unhealthy tracked service."
    }

    Remove-Item -LiteralPath $forceMarker -Force
    $env:SAPHIR_TEST_STATUS_MODE = "untracked"
    try {
        & (Join-Path -Path $fixtureScripts -ChildPath "launch-app.ps1") -Force
    }
    catch {
        # The fake URL deliberately stays unavailable after the mocked restart.
    }
    if (-not (Test-Path -LiteralPath $forceMarker -PathType Leaf) -or (Get-Content -LiteralPath $forceMarker -Raw).Trim() -ne "True") {
        throw "Assertion failed: -Force must reach safe restart recovery for an untracked listener."
    }

    Write-Host "Launch recovery test passed."
}
finally {
    $env:SAPHIR_TEST_SERVER_SCRIPT = $previousServerScript
    $env:SAPHIR_TEST_FORCE_MARKER = $previousForceMarker
    $env:SAPHIR_TEST_STATUS_MODE = $previousStatusMode
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
