$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path

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
        [Parameter(Mandatory = $true)][string]$BootstrapPath
    )

    $output = @(& $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $BootstrapPath 2>&1)
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("geem-bootstrap {0}" -f [Guid]::NewGuid().ToString("N"))
$distributionRoot = Join-Path -Path $testRoot -ChildPath "network distribution"
$distributionScripts = Join-Path -Path $distributionRoot -ChildPath "scripts"
$cacheRoot = Join-Path -Path $testRoot -ChildPath "local cache"
$previousReleasePath = Join-Path -Path $cacheRoot -ChildPath "versions/working-release"
$dataFolder = Join-Path -Path $testRoot -ChildPath "shared data"
$launchMarkerPath = Join-Path -Path $testRoot -ChildPath "previous-release-launched.txt"
$previousCacheRoot = [string]$env:OVERTIME_APP_CACHE_ROOT
$previousLaunchMarker = [string]$env:GEEM_BOOTSTRAP_TEST_MARKER

try {
    Ensure-TestDirectory -Path (Join-Path -Path $distributionScripts -ChildPath "lib")
    Ensure-TestDirectory -Path (Join-Path -Path $distributionRoot -ChildPath "deployment")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/services")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/frontend")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "docs")
    Ensure-TestDirectory -Path (Join-Path -Path $previousReleasePath -ChildPath "scripts/lib")
    Ensure-TestDirectory -Path $dataFolder

    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/launch-cached-app.ps1") -Destination (Join-Path -Path $distributionScripts -ChildPath "launch-cached-app.ps1") -Force
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/lib/LocalAppCache.ps1") -Destination (Join-Path -Path $distributionScripts -ChildPath "lib/LocalAppCache.ps1") -Force

    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/admin-server.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/admin-config.psd1") -Value "@{ DataFolderPath = '$($dataFolder.Replace("'", "''"))' }" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/backend/services/RouteDispatchService.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "apps/admin/frontend/index.html") -Value "<html>fixture</html>" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "docs/GC179.pdf") -Value "fixture" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "scripts/lib/RuntimeLayout.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "scripts/lib/ServerControl.ps1") -Value "# fixture" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $previousReleasePath -ChildPath "scripts/launch-app.ps1") -Value @'
param([switch]$Force)
Set-Content -LiteralPath $env:GEEM_BOOTSTRAP_TEST_MARKER -Value "working-release" -Encoding UTF8
'@ -Encoding UTF8

    $workingHash = "a" * 64
    Write-TestJson -Path (Join-Path -Path $previousReleasePath -ChildPath ".geem-release.json") -Value ([ordered]@{
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
    Write-TestJson -Path (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value ([ordered]@{
        schemaVersion  = 1
        releaseId      = "broken-update"
        packagePath    = "deployment/releases/GEEM-broken-update.zip"
        sha256         = ("b" * 64)
        dataFolderPath = $dataFolder
        publishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    })

    $powerShellCommand = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $powerShellCommand) {
        $powerShellCommand = Get-Command -Name "powershell" -ErrorAction Stop
    }

    $env:OVERTIME_APP_CACHE_ROOT = $cacheRoot
    $env:GEEM_BOOTSTRAP_TEST_MARKER = $launchMarkerPath
    $bootstrapPath = Join-Path -Path $distributionScripts -ChildPath "launch-cached-app.ps1"
    $bootstrapResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath

    Assert-True -Condition ($bootstrapResult.ExitCode -eq 0) -Message ("bootstrap must return success after restoring the previous release. Output: {0}" -f ($bootstrapResult.Output -join " | "))
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "the previous release must be launched when an update package is unavailable"
    Assert-True -Condition ((Get-Content -LiteralPath $launchMarkerPath -Raw).Trim() -eq "working-release") -Message "rollback must launch the expected previous release"

    $active = Get-Content -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "active.json") -Raw | ConvertFrom-Json
    Assert-True -Condition ([string]$active.releaseId -eq "working-release") -Message "rollback must preserve the previous active release"

    $failed = Get-Content -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "failed.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ([string]$failed.releaseId -eq "broken-update") -Message "a failed update must be remembered locally"
    Remove-Item -LiteralPath $launchMarkerPath -Force
    $knownFailureResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath
    Assert-True -Condition ($knownFailureResult.ExitCode -eq 0) -Message "a known failed release must immediately reuse the previous version"
    Assert-True -Condition (($knownFailureResult.Output -join " ") -match "already failed") -Message "a known failed release must be bypassed rather than retried"
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "bypassing a failed update must still launch the previous version"

    $brokenBuildRoot = Join-Path -Path $testRoot -ChildPath "broken launch build"
    $brokenRuntime = Join-Path -Path $brokenBuildRoot -ChildPath "runtime"
    Ensure-TestDirectory -Path $brokenBuildRoot
    Copy-Item -LiteralPath $previousReleasePath -Destination $brokenRuntime -Recurse -Force
    Remove-Item -LiteralPath (Join-Path -Path $brokenRuntime -ChildPath ".geem-release.json") -Force
    Set-Content -LiteralPath (Join-Path -Path $brokenRuntime -ChildPath "scripts/launch-app.ps1") -Value @'
param([switch]$Force)
throw "Intentional launch failure for rollback testing."
'@ -Encoding UTF8
    $releaseFolder = Join-Path -Path $distributionRoot -ChildPath "deployment/releases"
    Ensure-TestDirectory -Path $releaseFolder
    $brokenLaunchZip = Join-Path -Path $releaseFolder -ChildPath "GEEM-launch-failure.zip"
    Compress-Archive -Path (Join-Path -Path $brokenRuntime -ChildPath "*") -DestinationPath $brokenLaunchZip -Force
    $brokenLaunchHash = (Get-FileHash -LiteralPath $brokenLaunchZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-TestJson -Path (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value ([ordered]@{
        schemaVersion  = 1
        releaseId      = "launch-failure"
        packagePath    = "deployment/releases/GEEM-launch-failure.zip"
        sha256         = $brokenLaunchHash
        dataFolderPath = $dataFolder
        publishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    })
    Remove-Item -LiteralPath $launchMarkerPath -Force
    $launchFailureResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath
    Assert-True -Condition ($launchFailureResult.ExitCode -eq 0) -Message ("a valid package whose launch fails must roll back. Output: {0}" -f ($launchFailureResult.Output -join " | "))
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "a launch failure must start the previous working version"
    $failedLaunch = Get-Content -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "failed.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ([string]$failedLaunch.releaseId -eq "launch-failure") -Message "a release that fails during launch must be marked failed"

    Set-Content -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/current.json") -Value "{" -Encoding UTF8
    Remove-Item -LiteralPath $launchMarkerPath -Force
    $manifestFailureResult = Invoke-TestBootstrap -PowerShellPath $powerShellCommand.Source -BootstrapPath $bootstrapPath
    Assert-True -Condition ($manifestFailureResult.ExitCode -eq 0) -Message "a corrupt network manifest must fall back to the active local release"
    Assert-True -Condition (Test-Path -LiteralPath $launchMarkerPath -PathType Leaf) -Message "manifest fallback must launch the active local release"

    Write-Host "Cached bootstrap rollback test passed."
}
finally {
    $env:OVERTIME_APP_CACHE_ROOT = $previousCacheRoot
    $env:GEEM_BOOTSTRAP_TEST_MARKER = $previousLaunchMarker
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
