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

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-TestBootstrap {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$BootstrapPath,
        [switch]$Force,
        [switch]$NoBrowser
    )

    $bootstrapArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $BootstrapPath)
    if ($Force) {
        $bootstrapArguments += "-Force"
    }
    if ($NoBrowser) {
        $bootstrapArguments += "-NoBrowser"
    }
    $output = @(& $PowerShellPath @bootstrapArguments 2>&1)
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-bootstrap {0}" -f [Guid]::NewGuid().ToString("N"))
$distributionRoot = Join-Path -Path $testRoot -ChildPath "network distribution"
$distributionScripts = Join-Path -Path $distributionRoot -ChildPath "scripts"
$cacheRoot = Join-Path -Path $testRoot -ChildPath "local cache"
$previousReleasePath = Join-Path -Path $cacheRoot -ChildPath "versions/working-release"
$dataFolder = Join-Path -Path $testRoot -ChildPath "shared data"
$launchMarkerPath = Join-Path -Path $testRoot -ChildPath "previous-release-launched.txt"
$browserMarkerPath = Join-Path -Path $testRoot -ChildPath "browser-opened.txt"
$runtimeRoot = Join-Path -Path $testRoot -ChildPath "runtime"
$previousCacheRoot = [string]$env:SAPHIR_APP_CACHE_ROOT
$previousLaunchMarker = [string]$env:SAPHIR_BOOTSTRAP_TEST_MARKER
$previousBrowserMarker = [string]$env:SAPHIR_BOOTSTRAP_TEST_BROWSER_MARKER
$previousHealthyState = [string]$env:SAPHIR_BOOTSTRAP_TEST_HEALTHY
$previousRuntimeRoot = [string]$env:SAPHIR_RUNTIME_ROOT

try {
    Ensure-TestDirectory -Path (Join-Path -Path $distributionScripts -ChildPath "lib")
    Ensure-TestDirectory -Path (Join-Path -Path $distributionRoot -ChildPath "deployment")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/lib")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/services")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/frontend")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "docs")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "scripts/lib")
    Ensure-TestDirectory -Path $dataFolder

    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/launch-cached-app.ps1") -Destination (Join-Path -Path $distributionScripts -ChildPath "launch-cached-app.ps1") -Force
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/lib/ApplicationLayout.ps1") -Destination (Join-Path -Path $distributionScripts -ChildPath "lib/ApplicationLayout.ps1") -Force
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/lib/LocalAppCache.ps1") -Destination (Join-Path -Path $distributionScripts -ChildPath "lib/LocalAppCache.ps1") -Force
    Set-Content -LiteralPath (Join-Path -Path $distributionScripts -ChildPath "lib/ServerControl.ps1") -Value @'
function Test-ManagedServiceHealthyForScript {
    param($Name, $DisplayName, $ServerScript, $Port, $PidFile, $FrontendUrl, $TimeoutMilliseconds)
    return ([string]$env:SAPHIR_BOOTSTRAP_TEST_HEALTHY -eq "true")
}

function Open-UriInDefaultBrowser {
    param([string]$Uri)
    Set-Content -LiteralPath $env:SAPHIR_BOOTSTRAP_TEST_BROWSER_MARKER -Value $Uri -Encoding UTF8
}
'@ -Encoding UTF8

    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/admin-server.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/admin-config.psd1") -Value "@{ DataFolderPath = '$($dataFolder.Replace("'", "''"))' }" -Encoding UTF8
    # This fixture intentionally models a cached release from before graceful
    # service control existed. New bootstrap code must continue to discover and
    # launch it when the network release is unavailable or needs rollback.
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/services/RouteDispatchService.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/frontend/index.html") -Value "<html>fixture</html>" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "docs/GC179.pdf") -Value "fixture" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "scripts/lib/RuntimeLayout.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "scripts/lib/ServerControl.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "scripts/launch-app.ps1") -Value @'
param([switch]$Force)
Set-Content -LiteralPath $env:SAPHIR_BOOTSTRAP_TEST_MARKER -Value ("working-release|{0}" -f [bool]$Force) -Encoding UTF8
'@ -Encoding UTF8

    $workingHash = "a" * 64
    Write-TestJson -Path (Join-Path -Path $previousReleasePath -ChildPath ".saphir-release.json") -Value ([ordered]@{
        schemaVersion  = 1
        releaseId      = "working-release"
        sha256         = $workingHash
        dataFolderPath = $dataFolder
    })
    Write-TestJson -Path (Join-Path -Path $cacheRoot -ChildPath "active.json") -Value ([ordered]@{
        schemaVersion = 1
        releaseId     = "working-release"
        sha256        = $workingHash
    })
    $brokenUpdateManifest = [ordered]@{
        schemaVersion  = 1
        releaseId      = "broken-update"
        packagePath    = "deployment/releases/SAPHIR-broken-update.zip"
        sha256         = ("b" * 64)
        dataFolderPath = $dataFolder
        publishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-TestJson -Path (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value $brokenUpdateManifest

    $powerShellCommand = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $powerShellCommand) {
        $powerShellCommand = Get-Command -Name "powershell" -ErrorAction Stop
    }

    $env:SAPHIR_APP_CACHE_ROOT = $cacheRoot
    $env:SAPHIR_BOOTSTRAP_TEST_MARKER = $launchMarkerPath
    $env:SAPHIR_BOOTSTRAP_TEST_BROWSER_MARKER = $browserMarkerPath
    $env:SAPHIR_BOOTSTRAP_TEST_HEALTHY = "true"
    $env:SAPHIR_RUNTIME_ROOT = $runtimeRoot
    $bootstrapPath = Join-Path -Path $distributionScripts -ChildPath "launch-cached-app.ps1"

    Set-Content -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value "{" -Encoding UTF8
    $warmResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath
    Assert-True -Condition ($warmResult.ExitCode -eq 0) -Message ("a healthy active release must open without reading a corrupt network manifest. Output: {0}" -f ($warmResult.Output -join " | "))
    Assert-True -Condition (Test-Path -LiteralPath $browserMarkerPath -PathType Leaf) -Message "a warm launch must reopen the existing frontend"
    Assert-True -Condition ((Get-Content -LiteralPath $browserMarkerPath -Raw).Trim() -eq "http://localhost:8081/") -Message "a warm launch must open the SAPHIR frontend URL"
    Assert-True -Condition (-not (Test-Path -LiteralPath $launchMarkerPath)) -Message "a warm launch must not invoke the cached release launcher"
    Assert-True -Condition (($warmResult.Output -join " ") -match "without checking the network release") -Message "a warm launch must report that it skipped the network release check"

    Remove-Item -LiteralPath $browserMarkerPath -Force
    $quietWarmResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath -NoBrowser
    Assert-True -Condition ($quietWarmResult.ExitCode -eq 0) -Message "-NoBrowser must preserve the healthy warm-launch shortcut"
    Assert-True -Condition (-not (Test-Path -LiteralPath $browserMarkerPath)) -Message "-NoBrowser must not reopen the frontend for a healthy warm instance"
    Assert-True -Condition (-not (Test-Path -LiteralPath $launchMarkerPath)) -Message "-NoBrowser must not restart a healthy warm instance"

    $forcedResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath -Force
    Assert-True -Condition ($forcedResult.ExitCode -eq 0) -Message ("-Force must bypass the warm-launch shortcut. Output: {0}" -f ($forcedResult.Output -join " | "))
    Assert-True -Condition (-not (Test-Path -LiteralPath $browserMarkerPath)) -Message "-Force must not use the warm-launch browser shortcut"
    Assert-True -Condition ((Get-Content -LiteralPath $launchMarkerPath -Raw).Trim() -eq "working-release|True") -Message "-Force must reach and force-start the active cached release"

    Remove-Item -LiteralPath $launchMarkerPath -Force
    $env:SAPHIR_BOOTSTRAP_TEST_HEALTHY = "false"
    Write-TestJson -Path (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value $brokenUpdateManifest
    $bootstrapResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath

    Assert-True -Condition ($bootstrapResult.ExitCode -eq 0) -Message ("bootstrap must return success after restoring the previous release. Output: {0}" -f ($bootstrapResult.Output -join " | "))
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "the previous release must be launched when an update package is unavailable"
    Assert-True -Condition ((Get-Content -LiteralPath $launchMarkerPath -Raw).Trim() -eq "working-release|True") -Message "rollback must force-start the expected previous release"

    $active = Get-Content -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "active.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ([string]$active.releaseId -eq "working-release") -Message "rollback must preserve the previous active release"

    $failed = Get-Content -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "failed.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ([string]$failed.releaseId -eq "broken-update") -Message "a failed update must be remembered locally"
    Remove-Item -LiteralPath $launchMarkerPath -Force
    $knownFailureResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath
    Assert-True -Condition ($knownFailureResult.ExitCode -eq 0) -Message "a known failed release must immediately reuse the previous version"
    Assert-True -Condition (($knownFailureResult.Output -join " ") -match "already failed") -Message "a known failed release must be bypassed rather than retried"
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "bypassing a failed update must still launch the previous version"
    Assert-True -Condition ((Get-Content -LiteralPath $launchMarkerPath -Raw).Trim() -eq "working-release|False") -Message "a known failed update must reuse a healthy previous version without forcing a restart"

    $brokenBuildRoot = Join-Path -Path $testRoot -ChildPath "broken launch build"
    $brokenRuntime = Join-Path -Path $brokenBuildRoot -ChildPath "runtime"
    Ensure-TestDirectory -Path $brokenBuildRoot
    Copy-Item -LiteralPath $previousReleasePath -Destination $brokenRuntime -Recurse -Force
    Remove-Item -LiteralPath (Join-Path -Path $brokenRuntime -ChildPath ".saphir-release.json") -Force
    Set-Content -LiteralPath (Join-Path -Path $brokenRuntime -ChildPath "scripts/launch-app.ps1") -Value @'
param([switch]$Force)
throw "Intentional launch failure for rollback testing."
'@ -Encoding UTF8
    $releaseFolder = Join-Path -Path $distributionRoot -ChildPath "deployment/releases"
    Ensure-TestDirectory -Path $releaseFolder
    $brokenLaunchZip = Join-Path -Path $releaseFolder -ChildPath "SAPHIR-launch-failure.zip"
    Compress-Archive -Path (Join-Path -Path $brokenRuntime -ChildPath "*") -DestinationPath $brokenLaunchZip -Force
    $brokenLaunchHash = (Get-FileHash -LiteralPath $brokenLaunchZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-TestJson -Path (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value ([ordered]@{
        schemaVersion  = 1
        releaseId      = "launch-failure"
        packagePath    = "deployment/releases/SAPHIR-launch-failure.zip"
        sha256         = $brokenLaunchHash
        dataFolderPath = $dataFolder
        publishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    })
    Remove-Item -LiteralPath $launchMarkerPath -Force
    $launchFailureResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath
    Assert-True -Condition ($launchFailureResult.ExitCode -eq 0) -Message ("a valid package whose launch fails must roll back. Output: {0}" -f ($launchFailureResult.Output -join " | "))
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "a launch failure must start the previous working version"
    Assert-True -Condition ((Get-Content -LiteralPath $launchMarkerPath -Raw).Trim() -eq "working-release|True") -Message "a launch failure rollback must force-start the previous working version"
    $failedLaunch = Get-Content -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "failed.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ([string]$failedLaunch.releaseId -eq "launch-failure") -Message "a release that fails during launch must be marked failed"

    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "scripts/launch-app.ps1") -Value @'
param([switch]$Force, [switch]$NoBrowser)
Set-Content -LiteralPath $env:SAPHIR_BOOTSTRAP_TEST_MARKER -Value ("working-release|{0}|{1}" -f [bool]$Force, [bool]$NoBrowser) -Encoding UTF8
'@ -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value "{" -Encoding UTF8
    Remove-Item -LiteralPath $launchMarkerPath -Force
    $manifestFailureResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath -NoBrowser
    Assert-True -Condition ($manifestFailureResult.ExitCode -eq 0) -Message "a corrupt network manifest must fall back to the active local release"
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "manifest fallback must launch the active local release"
    Assert-True -Condition ((Get-Content -LiteralPath $launchMarkerPath -Raw).Trim() -eq "working-release|False|True") -Message "manifest fallback must reuse the active version without forcing a restart or opening the browser"

    Write-Host "Cached bootstrap rollback test passed."
}
finally {
    $env:SAPHIR_APP_CACHE_ROOT = $previousCacheRoot
    $env:SAPHIR_BOOTSTRAP_TEST_MARKER = $previousLaunchMarker
    $env:SAPHIR_BOOTSTRAP_TEST_BROWSER_MARKER = $previousBrowserMarker
    $env:SAPHIR_BOOTSTRAP_TEST_HEALTHY = $previousHealthyState
    $env:SAPHIR_RUNTIME_ROOT = $previousRuntimeRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
