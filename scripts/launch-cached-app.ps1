param([switch]$Force)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$distributionRoot = (Get-Item -LiteralPath $scriptDir).Parent.FullName
$manifestPath = Join-Path -Path $distributionRoot -ChildPath "deployment/current.json"
$localCacheLibrary = Join-Path -Path $scriptDir -ChildPath "lib/LocalAppCache.ps1"
$serverControlLibrary = Join-Path -Path $scriptDir -ChildPath "lib/ServerControl.ps1"
$developmentLaunchScript = Join-Path -Path $scriptDir -ChildPath "launch-app.ps1"
$developmentServerScript = Join-Path -Path $distributionRoot -ChildPath "apps/admin/backend/admin-server.ps1"

# A source checkout has no published manifest. Preserve the existing developer
# workflow while employee distributions always use the versioned local cache.
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $developmentServerScript -PathType Leaf) -and
    (Test-Path -LiteralPath $developmentLaunchScript -PathType Leaf)) {
    # Source checkouts follow the same warm-launch rule as installed releases.
    # Developers can still request a restart explicitly after editing code.
    & $developmentLaunchScript -Force:$Force
    return
}

function Write-SaphirBootstrapLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $applicationRoot = [string]$env:SAPHIR_APP_CACHE_ROOT
    if ([string]::IsNullOrWhiteSpace($applicationRoot)) {
        $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            $localAppData = [string]$env:LOCALAPPDATA
        }
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            $localAppData = [string]$env:TEMP
        }
        if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
            $applicationRoot = Join-Path -Path $localAppData -ChildPath "SAPHIR"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($applicationRoot)) {
        try {
            $logFolder = Join-Path -Path $applicationRoot -ChildPath "runtime/logs"
            if (-not (Test-Path -LiteralPath $logFolder -PathType Container)) {
                New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
            }
            $logLine = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
            Add-Content -LiteralPath (Join-Path -Path $logFolder -ChildPath "bootstrap.log") -Value $logLine -Encoding UTF8
        }
        catch {
        }
    }
}

function Write-SaphirBootstrapFailure {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-SaphirBootstrapLog -Message $Message

    Write-Error $Message -ErrorAction Continue
    if ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.Popup($Message, 0, "SAPHIR could not start", 16)
        }
        catch {
        }
    }
}

function Get-SaphirActiveRuntimeRoot {
    param([Parameter(Mandatory = $true)][string]$ReleasePath)

    $configuredRuntimeRoot = [string]$env:SAPHIR_RUNTIME_ROOT
    if ([string]::IsNullOrWhiteSpace($configuredRuntimeRoot)) {
        $configuredRuntimeRoot = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_RUNTIME_ROOT"))
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredRuntimeRoot)) {
        return [System.IO.Path]::GetFullPath($configuredRuntimeRoot)
    }

    if ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            $localAppData = [string]$env:TEMP
        }
        return (Join-Path -Path $localAppData -ChildPath "SAPHIR/runtime")
    }

    return (Join-Path -Path $ReleasePath -ChildPath "runtime")
}

function Open-SaphirWarmFrontend {
    param([Parameter(Mandatory = $true)][string]$FrontendUrl)

    Write-Host "SAPHIR is already running. Opening it without checking the network release."
    try {
        Open-UriInDefaultBrowser -Uri $FrontendUrl
    }
    catch {
        Write-Warning "SAPHIR is ready, but the browser could not be opened automatically. Open $FrontendUrl manually."
    }
}

$mutex = $null
try {
    if (-not (Test-Path -LiteralPath $localCacheLibrary -PathType Leaf)) {
        throw "The SAPHIR cache installer is missing from the shared distribution."
    }
    if (-not (Test-Path -LiteralPath $serverControlLibrary -PathType Leaf)) {
        throw "The SAPHIR local service controller is missing from the shared distribution."
    }
    . $localCacheLibrary
    . $serverControlLibrary

    $cacheRoot = Get-SaphirLocalAppRoot
    if (-not $Force) {
        $warmRelease = Get-SaphirActiveRelease -CacheRoot $cacheRoot
        if ($null -ne $warmRelease) {
            $warmFrontendUrl = "http://localhost:8081/"
            $warmRuntimeRoot = Get-SaphirActiveRuntimeRoot -ReleasePath ([string]$warmRelease.ReleasePath)
            $warmPidFile = Join-Path -Path $warmRuntimeRoot -ChildPath "pids/app.pid.json"
            $warmServerScript = Join-Path -Path ([string]$warmRelease.ReleasePath) -ChildPath "apps/admin/backend/admin-server.ps1"
            $warmBackendHealthy = Test-ManagedServiceHealthyForScript `
                -Name "app" `
                -DisplayName "SAPHIR Backend" `
                -ServerScript $warmServerScript `
                -Port 8081 `
                -PidFile $warmPidFile `
                -FrontendUrl $warmFrontendUrl
            if ($warmBackendHealthy) {
                Open-SaphirWarmFrontend -FrontendUrl $warmFrontendUrl
                return
            }
        }
    }

    $mutex = Enter-SaphirCacheMutex -CacheRoot $cacheRoot
    Repair-SaphirInterruptedCacheOperations -CacheRoot $cacheRoot
    $previousRelease = Get-SaphirActiveRelease -CacheRoot $cacheRoot
    $release = $null
    $usedPreviousRelease = $false
    $targetManifest = $null
    try {
        $targetManifest = Read-SaphirReleaseManifest -ManifestPath $manifestPath -DistributionRoot $distributionRoot
    }
    catch {
        $manifestError = $_
        if ($null -ne $previousRelease -and (Test-Path -LiteralPath $previousRelease.LaunchScript -PathType Leaf)) {
            Write-Warning "The network release information is unavailable. Starting the previous local SAPHIR version."
            & $previousRelease.LaunchScript -Force:$Force
            Set-SaphirActiveRelease -CacheRoot $cacheRoot -Release $previousRelease
            Write-SaphirBootstrapLog -Message ("The release manifest could not be read. SAPHIR restored '{0}'. {1}" -f $previousRelease.ReleaseId, $manifestError.Exception.Message)
            $release = $previousRelease
            $usedPreviousRelease = $true
        }
        else {
            throw $manifestError
        }
    }

    if (-not $usedPreviousRelease) {
        $failedRelease = Get-SaphirFailedRelease -CacheRoot $cacheRoot
        $skipKnownFailedRelease = $null -ne $failedRelease -and
            [string]$failedRelease.ReleaseId -eq [string]$targetManifest.ReleaseId -and
            [string]$failedRelease.Sha256 -eq [string]$targetManifest.Sha256 -and
            $null -ne $previousRelease -and
            [string]$previousRelease.ReleaseId -ne [string]$targetManifest.ReleaseId

        if ($skipKnownFailedRelease) {
            Write-Warning "SAPHIR is using the previous local version because the current network release already failed on this computer."
            & $previousRelease.LaunchScript -Force:$Force
            Set-SaphirActiveRelease -CacheRoot $cacheRoot -Release $previousRelease
            $release = $previousRelease
            $usedPreviousRelease = $true
        }
        else {
            try {
                $release = Install-SaphirCachedRelease -Manifest $targetManifest -CacheRoot $cacheRoot
                try {
                    # A newly installed or repaired release must replace any
                    # process still running from files at the same path. Warm
                    # launches of an unchanged cached release are reused.
                    $restartForInstalledRelease = $Force -or [bool]$release.Installed
                    & $release.LaunchScript -Force:$restartForInstalledRelease
                }
                catch {
                    $cachedLaunchError = $_
                    if (-not [bool]$release.Installed) {
                        Write-Warning "The local SAPHIR copy failed to start. Repairing it once from the network release."
                        $release = Install-SaphirCachedRelease -Manifest $targetManifest -CacheRoot $cacheRoot -ForceReinstall
                        & $release.LaunchScript -Force
                    }
                    else {
                        throw $cachedLaunchError
                    }
                }

                Set-SaphirActiveRelease -CacheRoot $cacheRoot -Release $release
                Remove-SaphirFailedRelease -CacheRoot $cacheRoot
            }
            catch {
                $launchError = $_
                if ($null -ne $previousRelease -and
                    [string]$previousRelease.ReleaseId -ne [string]$targetManifest.ReleaseId -and
                    (Test-Path -LiteralPath $previousRelease.LaunchScript -PathType Leaf)) {
                    try {
                        Write-Warning "The new SAPHIR release failed. Restoring the previous local release."
                        # Displace any partially started new release before
                        # restoring the last version known to work.
                        & $previousRelease.LaunchScript -Force
                        Set-SaphirActiveRelease -CacheRoot $cacheRoot -Release $previousRelease
                        try {
                            Set-SaphirFailedRelease -CacheRoot $cacheRoot -Manifest $targetManifest
                        }
                        catch {
                            Write-Warning "The failed-release marker could not be saved."
                        }
                        Write-SaphirBootstrapLog -Message ("Release '{0}' failed and SAPHIR restored '{1}'. {2}" -f $targetManifest.ReleaseId, $previousRelease.ReleaseId, $launchError.Exception.Message)
                        $release = $previousRelease
                        $usedPreviousRelease = $true
                    }
                    catch {
                        Write-SaphirBootstrapLog -Message ("Release '{0}' failed, and rollback to '{1}' also failed. Update error: {2} Rollback error: {3}" -f $targetManifest.ReleaseId, $previousRelease.ReleaseId, $launchError.Exception.Message, $_.Exception.Message)
                        Write-Warning "The previous SAPHIR release could not be restored automatically."
                    }
                }
                if (-not $usedPreviousRelease) {
                    throw $launchError
                }
            }
        }
    }

    $keepReleaseIds = @([string]$release.ReleaseId)
    if ($null -ne $previousRelease -and -not [string]::IsNullOrWhiteSpace([string]$previousRelease.ReleaseId)) {
        $keepReleaseIds += [string]$previousRelease.ReleaseId
    }
    Remove-OldSaphirCachedReleases -CacheRoot $cacheRoot -KeepReleaseIds $keepReleaseIds -MaximumVersionCount 2
}
catch {
    Write-SaphirBootstrapFailure -Message ("SAPHIR could not start. {0}`n`nIf the problem continues, run Stop SAPHIR and contact support." -f $_.Exception.Message)
    exit 1
}
finally {
    $exitMutexCommand = Get-Command -Name "Exit-SaphirCacheMutex" -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $exitMutexCommand) {
        Exit-SaphirCacheMutex -Mutex $mutex
    }
    elseif ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
