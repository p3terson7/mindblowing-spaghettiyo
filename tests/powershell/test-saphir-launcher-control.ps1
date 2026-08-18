$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "scripts/lib/LauncherControl.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $caughtMessage = ""
    try {
        & $Action
    }
    catch {
        $caughtMessage = [string]$_.Exception.Message
    }

    if ([string]::IsNullOrWhiteSpace($caughtMessage) -or $caughtMessage -notmatch $MessagePattern) {
        throw "Assertion failed: $Message. Actual error: '$caughtMessage'."
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-launcher-control {0}" -f [Guid]::NewGuid().ToString("N"))
$sourceRoot = Join-Path -Path $testRoot -ChildPath "source"
$runtimeRoot = Join-Path -Path $testRoot -ChildPath "runtime"
$dataFolder = Join-Path -Path $sourceRoot -ChildPath "data"
$serverScript = Join-Path -Path $sourceRoot -ChildPath "app/backend/saphir-server.ps1"
$routeDispatchScript = Join-Path -Path $sourceRoot -ChildPath "app/backend/services/RouteDispatchService.ps1"
$frontendIndex = Join-Path -Path $sourceRoot -ChildPath "app/frontend/index.html"
$launchScript = Join-Path -Path $sourceRoot -ChildPath "scripts/launch-app.ps1"
$bootstrapScript = Join-Path -Path $sourceRoot -ChildPath "scripts/launch-cached-app.ps1"
$previousProductServerScript = Join-Path -Path $testRoot -ChildPath "previous-product/admin-server.ps1"
$script:testStatusMode = "Offline"
$script:testHealthy = $false
$script:testWindowsHost = $false
$script:stopCallCount = 0
$script:lastStoppedScript = ""
$script:launchCallCount = 0
$script:lastLaunchForce = $false
$script:lastLaunchScript = ""
$script:lastDistributionRoot = ""
$originalCacheRoot = [string]$env:SAPHIR_APP_CACHE_ROOT

function Test-IsWindowsHost {
    return [bool]$script:testWindowsHost
}

function Get-ServiceStatus {
    param($Name, $DisplayName, $Port, $PidFile)

    if ($script:testStatusMode -eq "PreviousProduct") {
        if ([string]$PidFile -match "OvertimeManager") {
            return [PSCustomObject]@{
                IsRunning       = $true
                PortOwnerId      = 202
                TrackedProcessId = 202
                Metadata         = [PSCustomObject]@{
                    scriptPath   = $previousProductServerScript
                    instanceToken = "abcdef0123456789abcdef0123456789"
                }
            }
        }
        return [PSCustomObject]@{
            IsRunning       = $true
            PortOwnerId      = 202
            TrackedProcessId = $null
            Metadata         = $null
        }
    }

    if ($script:testStatusMode -eq "Offline") {
        return [PSCustomObject]@{
            IsRunning       = $false
            PortOwnerId      = $null
            TrackedProcessId = $null
            Metadata         = $null
        }
    }
    if ($script:testStatusMode -eq "PortConflict") {
        return [PSCustomObject]@{
            IsRunning       = $true
            PortOwnerId      = 909
            TrackedProcessId = $null
            Metadata         = $null
        }
    }

    $trackedPath = if ($script:testStatusMode -eq "OtherVersion") {
        Join-Path -Path $testRoot -ChildPath "another-release/admin-server.ps1"
    }
    else {
        $serverScript
    }
    return [PSCustomObject]@{
        IsRunning       = $true
        PortOwnerId      = if ($script:testStatusMode -eq "TrackedWithForeignPort") { 909 } else { 101 }
        TrackedProcessId = 101
        Metadata         = [PSCustomObject]@{
            scriptPath   = $trackedPath
            instanceToken = "0123456789abcdef0123456789abcdef"
            stdoutLog    = Join-Path -Path $runtimeRoot -ChildPath "logs/custom.stdout.log"
            stderrLog    = Join-Path -Path $runtimeRoot -ChildPath "logs/custom.stderr.log"
        }
    }
}

function Test-ManagedServiceHealthyForScript {
    param($Name, $DisplayName, $ServerScript, $Port, $PidFile, $FrontendUrl, $TimeoutMilliseconds)
    return [bool]$script:testHealthy
}

function Stop-ManagedService {
    param($Name, $DisplayName, $Port, $PidFile, $ServerScript, [switch]$Quiet)

    $script:stopCallCount += 1
    $script:lastStoppedScript = [string]$ServerScript
    $script:testStatusMode = "Offline"
    $script:testHealthy = $false
    return $true
}

function Invoke-SaphirLauncherScriptProcess {
    param([string]$ScriptPath, [string]$DistributionRoot, [switch]$Force)

    $script:launchCallCount += 1
    $script:lastLaunchScript = $ScriptPath
    $script:lastLaunchForce = [bool]$Force
    $script:lastDistributionRoot = $DistributionRoot
    $script:testStatusMode = "Online"
    $script:testHealthy = $true
}

try {
    $env:SAPHIR_APP_CACHE_ROOT = Join-Path -Path $testRoot -ChildPath "isolated cache"
    New-Item -ItemType Directory -Path (Split-Path -Path $serverScript -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Path $launchScript -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path $dataFolder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $runtimeRoot -ChildPath "logs") -Force | Out-Null
    Set-Content -LiteralPath $serverScript -Value "# server fixture" -Encoding UTF8
    New-Item -ItemType Directory -Path (Split-Path -Path $routeDispatchScript -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Path $frontendIndex -Parent) -Force | Out-Null
    Set-Content -LiteralPath $routeDispatchScript -Value "# route fixture" -Encoding UTF8
    Set-Content -LiteralPath $frontendIndex -Value "<html></html>" -Encoding UTF8
    Set-Content -LiteralPath $launchScript -Value "param([switch]`$Force)" -Encoding UTF8
    Set-Content -LiteralPath $bootstrapScript -Value "param([switch]`$Force)" -Encoding UTF8
    Set-Content `
        -LiteralPath (Join-Path -Path (Split-Path -Path $serverScript -Parent) -ChildPath "saphir-config.psd1") `
        -Value "@{ DataFolderPath = '../../data' }" `
        -Encoding UTF8

    $deploymentFixtureRoot = Join-Path -Path $testRoot -ChildPath "published distribution"
    $deploymentFixtureData = Join-Path -Path $testRoot -ChildPath "shared data"
    $deploymentFixturePackage = Join-Path -Path $deploymentFixtureRoot -ChildPath "deployment/releases/SAPHIR-release-new.zip"
    $deploymentFixtureManifest = Join-Path -Path $deploymentFixtureRoot -ChildPath "deployment/current.json"
    $deploymentFixtureCache = Join-Path -Path $testRoot -ChildPath "deployment cache"
    New-Item -ItemType Directory -Path (Split-Path -Path $deploymentFixturePackage -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path $deploymentFixtureData -Force | Out-Null
    New-Item -ItemType Directory -Path $deploymentFixtureCache -Force | Out-Null
    Set-Content -LiteralPath $deploymentFixturePackage -Value "fixture" -Encoding ASCII
    $deploymentFixtureHash = "a" * 64
    [ordered]@{
        schemaVersion  = 1
        releaseId      = "release-new"
        packagePath    = "deployment/releases/SAPHIR-release-new.zip"
        sha256         = $deploymentFixtureHash
        dataFolderPath = $deploymentFixtureData
    } | ConvertTo-Json | Set-Content -LiteralPath $deploymentFixtureManifest -Encoding UTF8

    $deploymentReady = Get-SaphirLauncherDeploymentSnapshot `
        -DistributionRoot $deploymentFixtureRoot `
        -InstalledReleaseId "release-old" `
        -CacheRoot $deploymentFixtureCache
    Assert-Equal -Expected "Ready" -Actual $deploymentReady.State -Message "a complete network release must be reported as ready without installing it"
    Assert-Equal -Expected "release-new" -Actual $deploymentReady.TargetReleaseId -Message "status must expose the release targeted by current.json"
    Assert-True -Condition $deploymentReady.UpdateAvailable -Message "status must distinguish the installed release from the network target"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $deploymentFixtureCache -ChildPath "versions/release-new"))) -Message "a read-only status check must never install the target release"

    Remove-Item -LiteralPath $deploymentFixtureManifest -Force
    $missingManifest = Get-SaphirLauncherDeploymentSnapshot `
        -DistributionRoot $deploymentFixtureRoot `
        -InstalledReleaseId "release-old" `
        -CacheRoot $deploymentFixtureCache
    Assert-Equal -Expected "ManifestMissing" -Actual $missingManifest.State -Message "a ZIP without current.json must not be mistaken for a published release"
    Assert-True -Condition ([string]$missingManifest.Error -match "ZIP.*not enough") -Message "a missing pointer must explain that copying the ZIP alone does not publish it"
    [ordered]@{
        schemaVersion  = 1
        releaseId      = "release-new"
        packagePath    = "deployment/releases/SAPHIR-release-new.zip"
        sha256         = $deploymentFixtureHash
        dataFolderPath = $deploymentFixtureData
    } | ConvertTo-Json | Set-Content -LiteralPath $deploymentFixtureManifest -Encoding UTF8

    [ordered]@{
        schemaVersion = 1
        releaseId     = "release-new"
        sha256        = $deploymentFixtureHash
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path -Path $deploymentFixtureCache -ChildPath "failed.json") -Encoding UTF8
    $previousFailure = Get-SaphirLauncherDeploymentSnapshot `
        -DistributionRoot $deploymentFixtureRoot `
        -InstalledReleaseId "release-old" `
        -CacheRoot $deploymentFixtureCache
    Assert-Equal -Expected "PreviouslyFailed" -Actual $previousFailure.State -Message "a target package already marked failed on this workstation must be visible"
    Assert-True -Condition ($previousFailure.UpdateAvailable -and $previousFailure.TargetPreviouslyFailed) -Message "a failed update must remain visible instead of looking current"

    $script:testStatusMode = "Online"
    $script:testHealthy = $true
    $online = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "Online" -Actual $online.State -Message "a verified healthy SAPHIR instance must be online"
    Assert-Equal -Expected "development" -Actual $online.ReleaseId -Message "a source checkout must expose its development context"
    Assert-Equal -Expected "Source" -Actual $online.ContextKind -Message "the source context must be identified"
    Assert-True -Condition $online.DataAvailable -Message "the configured source data folder must be resolved relative to the backend"
    Assert-Equal -Expected $dataFolder -Actual $online.DataFolderPath -Message "the resolved source data path must be reported"
    Assert-True -Condition ($online.CanOpen -and $online.CanRestart -and $online.CanStop -and -not $online.CanStart) -Message "online actions must be exposed safely"
    Assert-True -Condition ($online.Managed -and $online.ExpectedInstance -and $online.Healthy) -Message "online must require the tracked expected instance and matching health probe"
    Assert-Equal -Expected (Join-Path -Path $runtimeRoot -ChildPath "logs") -Actual $online.LogsPath -Message "the runtime logs folder must be reported"

    $script:testStatusMode = "Offline"
    $script:testHealthy = $false
    $offline = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "Offline" -Actual $offline.State -Message "no process and no listener must be offline"
    Assert-True -Condition ($offline.CanStart -and -not $offline.CanOpen -and -not $offline.CanRestart -and -not $offline.CanStop) -Message "offline must expose only Start"

    $script:testStatusMode = "Unresponsive"
    $unresponsive = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "Unresponsive" -Actual $unresponsive.State -Message "a tracked expected process that fails health must be unresponsive"
    Assert-True -Condition (-not $unresponsive.CanStart -and -not $unresponsive.CanOpen -and -not $unresponsive.CanRestart -and $unresponsive.CanStop) -Message "a short failed health probe must not expose force Restart, while explicit Stop remains available"
    Assert-Throws -Action {
        Invoke-SaphirLauncherAction -Action Restart -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot | Out-Null
    } -MessagePattern "cannot be restarted" -Message "the launcher action layer must also reject restart after only a short health timeout"
    Assert-Equal -Expected 0 -Actual $script:stopCallCount -Message "a refused busy-instance restart must not call the process terminator"

    $script:testStatusMode = "OtherVersion"
    $otherVersion = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "Unresponsive" -Actual $otherVersion.State -Message "a tracked SAPHIR process from another version must not be treated as a port conflict"
    Assert-True -Condition ($otherVersion.Managed -and -not $otherVersion.ExpectedInstance) -Message "another tracked version must remain managed but unexpected"
    Assert-True -Condition $otherVersion.CanRestart -Message "a verified different release may still be replaced during an update"

    $script:testStatusMode = "PortConflict"
    $portConflict = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "PortConflict" -Actual $portConflict.State -Message "an untracked port listener must be a conflict"
    Assert-True -Condition (-not $portConflict.CanStart -and -not $portConflict.CanOpen -and -not $portConflict.CanRestart -and -not $portConflict.CanStop) -Message "a foreign port listener must expose no destructive action"
    Assert-Throws -Action {
        Stop-SaphirLauncherApp -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot -Quiet | Out-Null
    } -MessagePattern "another program" -Message "safe stop must refuse a foreign listener"
    Assert-Equal -Expected 0 -Actual $script:stopCallCount -Message "safe stop must not reach the service terminator for a conflict"

    $script:testStatusMode = "TrackedWithForeignPort"
    $trackedConflict = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "PortConflict" -Actual $trackedConflict.State -Message "a foreign listener must remain a conflict even when an orphaned tracked process exists"
    Assert-True -Condition (-not $trackedConflict.PortOwnedByManagedInstance) -Message "a different port owner must not be authorized as SAPHIR"

    $script:testWindowsHost = $true
    $script:testStatusMode = "PreviousProduct"
    $previousProduct = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "Unresponsive" -Actual $previousProduct.State -Message "a verified pre-rename backend must be recoverable rather than treated as a foreign conflict"
    Assert-True -Condition ($previousProduct.Managed -and $previousProduct.PreviousProductInstance) -Message "pre-rename PID metadata must remain a verified managed instance"
    Assert-True -Condition ($previousProduct.CanRestart -and $previousProduct.CanStop) -Message "a verified previous product instance must expose safe recovery actions"
    Assert-True -Condition ([string]$previousProduct.PidFile -match "OvertimeManager") -Message "safe stop must retain the previous product PID file"
    $script:testWindowsHost = $false

    $script:testStatusMode = "Unresponsive"
    [void](Stop-SaphirLauncherApp -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot -Quiet)
    Assert-Equal -Expected 1 -Actual $script:stopCallCount -Message "safe stop must terminate a verified managed process"
    Assert-Equal -Expected $serverScript -Actual $script:lastStoppedScript -Message "safe stop must bind termination to the tracked server script"

    $script:testStatusMode = "Offline"
    $script:testHealthy = $false
    $startResult = Invoke-SaphirLauncherAction -Action Start -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected 1 -Actual $script:launchCallCount -Message "Start must invoke one launch process"
    Assert-Equal -Expected (Get-SaphirLauncherAdjacentBootstrapPath) -Actual $script:lastLaunchScript -Message "Start must prefer the locally installed update-aware cached bootstrap"
    Assert-Equal -Expected $sourceRoot -Actual $script:lastDistributionRoot -Message "the local bootstrap must receive the canonical distribution path"
    Assert-True -Condition (-not $script:lastLaunchForce) -Message "Start must not force a healthy process replacement"
    Assert-Equal -Expected "Online" -Actual $startResult.State -Message "Start must return a refreshed status"

    $restartResult = Invoke-SaphirLauncherAction -Action Restart -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected 2 -Actual $script:launchCallCount -Message "Restart must invoke one additional launch process"
    Assert-Equal -Expected 2 -Actual $script:stopCallCount -Message "Restart must first stop the exact verified managed process"
    Assert-True -Condition (-not $script:lastLaunchForce) -Message "Restart must launch normally after the verified process has stopped"
    Assert-Equal -Expected "Online" -Actual $restartResult.State -Message "Restart must return a refreshed status"

    $stopResult = Invoke-SaphirLauncherAction -Action Stop -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected 3 -Actual $script:stopCallCount -Message "the Stop action must use the safe stop helper"
    Assert-Equal -Expected "Offline" -Actual $stopResult.State -Message "Stop must return a refreshed offline status"

    $previousRestartStopCount = $script:stopCallCount
    $script:testWindowsHost = $true
    $script:testStatusMode = "PreviousProduct"
    $script:testHealthy = $false
    $previousRestartResult = Invoke-SaphirLauncherAction -Action Restart -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected ($previousRestartStopCount + 1) -Actual $script:stopCallCount -Message "Restart must safely stop a verified pre-rename instance before launching SAPHIR"
    Assert-Equal -Expected $previousProductServerScript -Actual $script:lastStoppedScript -Message "pre-rename restart must use the recovered legacy PID metadata and exact server path"
    Assert-True -Condition (-not $script:lastLaunchForce) -Message "pre-rename restart must not ask the new runtime root to force-stop the already stopped legacy process"
    Assert-Equal -Expected "Online" -Actual $previousRestartResult.State -Message "pre-rename restart must start the current SAPHIR context"
    $script:testWindowsHost = $false

    Remove-Item -LiteralPath $dataFolder -Recurse -Force
    $dataUnavailable = Get-SaphirLauncherStatus -DistributionRoot $sourceRoot -RuntimeRoot $runtimeRoot
    Assert-True -Condition (-not $dataUnavailable.DataAvailable) -Message "an unavailable data folder must be reported without changing app state"
    Assert-Equal -Expected $dataFolder -Actual $dataUnavailable.DataFolderPath -Message "the unavailable configured data path must remain visible"

    $cachedDistribution = Join-Path -Path $testRoot -ChildPath "distribution"
    $cachedReleaseRoot = Join-Path -Path $testRoot -ChildPath "cache/versions/cached-release"
    $cachedServerScript = Join-Path -Path $cachedReleaseRoot -ChildPath "app/backend/saphir-server.ps1"
    $cachedConfigPath = Join-Path -Path $cachedReleaseRoot -ChildPath "app/backend/saphir-config.psd1"
    $cachedRouteDispatchScript = Join-Path -Path $cachedReleaseRoot -ChildPath "app/backend/services/RouteDispatchService.ps1"
    $cachedFrontendIndex = Join-Path -Path $cachedReleaseRoot -ChildPath "app/frontend/index.html"
    $cachedLaunchScript = Join-Path -Path $cachedReleaseRoot -ChildPath "scripts/launch-app.ps1"
    New-Item -ItemType Directory -Path (Split-Path -Path $cachedServerScript -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Path $cachedLaunchScript -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path $cachedDistribution -Force | Out-Null
    Set-Content -LiteralPath $cachedServerScript -Value "# cached server" -Encoding UTF8
    New-Item -ItemType Directory -Path (Split-Path -Path $cachedRouteDispatchScript -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Path $cachedFrontendIndex -Parent) -Force | Out-Null
    Set-Content -LiteralPath $cachedConfigPath -Value "@{ DataFolderPath = '$($dataFolder.Replace("'", "''"))' }" -Encoding UTF8
    Set-Content -LiteralPath $cachedRouteDispatchScript -Value "# cached route" -Encoding UTF8
    Set-Content -LiteralPath $cachedFrontendIndex -Value "<html></html>" -Encoding UTF8
    Set-Content -LiteralPath $cachedLaunchScript -Value "# cached launch" -Encoding UTF8
    $script:cachedFixture = [PSCustomObject]@{
        ReleaseId    = "cached-release"
        ReleasePath  = $cachedReleaseRoot
        LaunchScript = $cachedLaunchScript
    }
    function Get-SaphirActiveRelease {
        param([string]$CacheRoot)
        return $script:cachedFixture
    }
    $script:testStatusMode = "Offline"
    $cachedStatus = Get-SaphirLauncherStatus `
        -DistributionRoot $cachedDistribution `
        -CacheRoot (Join-Path -Path $testRoot -ChildPath "cache") `
        -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "CachedRelease" -Actual $cachedStatus.ContextKind -Message "a deployed launcher must resolve the active cached release"
    Assert-Equal -Expected "cached-release" -Actual $cachedStatus.ReleaseId -Message "the active cached release ID must be reported"
    Assert-Equal -Expected $cachedServerScript -Actual $cachedStatus.ServerScript -Message "cached status must target the active release server"
    Assert-True -Condition $cachedStatus.CanStart -Message "an installed cached release must remain startable when the distribution is unavailable"

    $script:cachedFixture = $null
    $firstTimeOfflineRoot = Join-Path -Path $testRoot -ChildPath "first-time-offline"
    New-Item -ItemType Directory -Path $firstTimeOfflineRoot -Force | Out-Null
    $firstTimeOffline = Get-SaphirLauncherStatus `
        -DistributionRoot $firstTimeOfflineRoot `
        -CacheRoot (Join-Path -Path $testRoot -ChildPath "empty-cache") `
        -RuntimeRoot $runtimeRoot
    Assert-Equal -Expected "Offline" -Actual $firstTimeOffline.State -Message "a first-time machine without the share must be offline"
    Assert-True -Condition (-not $firstTimeOffline.CanStart) -Message "a local bootstrap alone must not enable Start without a cached release or reachable deployment"

    Write-Host "SAPHIR launcher control tests passed."
}
finally {
    $env:SAPHIR_APP_CACHE_ROOT = $originalCacheRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
