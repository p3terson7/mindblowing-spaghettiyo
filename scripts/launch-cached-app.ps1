param([switch]$Force)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$distributionRoot = (Get-Item -LiteralPath $scriptDir).Parent.FullName
$manifestPath = Join-Path -Path $distributionRoot -ChildPath "deployment/current.json"
$localCacheLibrary = Join-Path -Path $scriptDir -ChildPath "lib/LocalAppCache.ps1"
$developmentLaunchScript = Join-Path -Path $scriptDir -ChildPath "launch-app.ps1"
$developmentServerScript = Join-Path -Path $distributionRoot -ChildPath "apps/admin/backend/admin-server.ps1"

# A source checkout has no published manifest. Preserve the existing developer
# workflow while employee distributions always use the versioned local cache.
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $developmentServerScript -PathType Leaf) -and
    (Test-Path -LiteralPath $developmentLaunchScript -PathType Leaf)) {
    & $developmentLaunchScript -Force:$Force
    return
}

function Write-GeemBootstrapLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $applicationRoot = [string]$env:OVERTIME_APP_CACHE_ROOT
    if ([string]::IsNullOrWhiteSpace($applicationRoot)) {
        $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            $localAppData = [string]$env:LOCALAPPDATA
        }
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            $localAppData = [string]$env:TEMP
        }
        if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
            $applicationRoot = Join-Path -Path $localAppData -ChildPath "OvertimeManager"
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

function Write-GeemBootstrapFailure {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-GeemBootstrapLog -Message $Message

    Write-Error $Message -ErrorAction Continue
    if ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.Popup($Message, 0, "GEEM could not start", 16)
        }
        catch {
        }
    }
}

$mutex = $null
try {
    if (-not (Test-Path -LiteralPath $localCacheLibrary -PathType Leaf)) {
        throw "The GEEM cache installer is missing from the shared distribution."
    }
    . $localCacheLibrary

    $cacheRoot = Get-GeemLocalAppRoot
    $mutex = Enter-GeemCacheMutex -CacheRoot $cacheRoot
    Repair-GeemInterruptedCacheOperations -CacheRoot $cacheRoot
    $previousRelease = Get-GeemActiveRelease -CacheRoot $cacheRoot
    $release = $null
    $usedPreviousRelease = $false
    $targetManifest = $null
    try {
        $targetManifest = Read-GeemReleaseManifest -ManifestPath $manifestPath -DistributionRoot $distributionRoot
    }
    catch {
        $manifestError = $_
        if ($null -ne $previousRelease -and (Test-Path -LiteralPath $previousRelease.LaunchScript -PathType Leaf)) {
            Write-Warning "The network release information is unavailable. Starting the previous local GEEM version."
            & $previousRelease.LaunchScript -Force:$Force
            Set-GeemActiveRelease -CacheRoot $cacheRoot -Release $previousRelease
            Write-GeemBootstrapLog -Message ("The release manifest could not be read. GEEM restored '{0}'. {1}" -f $previousRelease.ReleaseId, $manifestError.Exception.Message)
            $release = $previousRelease
            $usedPreviousRelease = $true
        }
        else {
            throw $manifestError
        }
    }

    if (-not $usedPreviousRelease) {
        $failedRelease = Get-GeemFailedRelease -CacheRoot $cacheRoot
        $skipKnownFailedRelease = $null -ne $failedRelease -and
            [string]$failedRelease.ReleaseId -eq [string]$targetManifest.ReleaseId -and
            [string]$failedRelease.Sha256 -eq [string]$targetManifest.Sha256 -and
            $null -ne $previousRelease -and
            [string]$previousRelease.ReleaseId -ne [string]$targetManifest.ReleaseId

        if ($skipKnownFailedRelease) {
            Write-Warning "GEEM is using the previous local version because the current network release already failed on this computer."
            & $previousRelease.LaunchScript -Force:$Force
            Set-GeemActiveRelease -CacheRoot $cacheRoot -Release $previousRelease
            $release = $previousRelease
            $usedPreviousRelease = $true
        }
        else {
            try {
                $release = Install-GeemCachedRelease -Manifest $targetManifest -CacheRoot $cacheRoot
                try {
                    & $release.LaunchScript -Force:$Force
                }
                catch {
                    $cachedLaunchError = $_
                    if (-not [bool]$release.Installed) {
                        Write-Warning "The local GEEM copy failed to start. Repairing it once from the network release."
                        $release = Install-GeemCachedRelease -Manifest $targetManifest -CacheRoot $cacheRoot -ForceReinstall
                        & $release.LaunchScript -Force:$Force
                    }
                    else {
                        throw $cachedLaunchError
                    }
                }

                Set-GeemActiveRelease -CacheRoot $cacheRoot -Release $release
                Remove-GeemFailedRelease -CacheRoot $cacheRoot
            }
            catch {
                $launchError = $_
                if ($null -ne $previousRelease -and
                    [string]$previousRelease.ReleaseId -ne [string]$targetManifest.ReleaseId -and
                    (Test-Path -LiteralPath $previousRelease.LaunchScript -PathType Leaf)) {
                    try {
                        Write-Warning "The new GEEM release failed. Restoring the previous local release."
                        & $previousRelease.LaunchScript -Force:$Force
                        Set-GeemActiveRelease -CacheRoot $cacheRoot -Release $previousRelease
                        try {
                            Set-GeemFailedRelease -CacheRoot $cacheRoot -Manifest $targetManifest
                        }
                        catch {
                            Write-Warning "The failed-release marker could not be saved."
                        }
                        Write-GeemBootstrapLog -Message ("Release '{0}' failed and GEEM restored '{1}'. {2}" -f $targetManifest.ReleaseId, $previousRelease.ReleaseId, $launchError.Exception.Message)
                        $release = $previousRelease
                        $usedPreviousRelease = $true
                    }
                    catch {
                        Write-GeemBootstrapLog -Message ("Release '{0}' failed, and rollback to '{1}' also failed. Update error: {2} Rollback error: {3}" -f $targetManifest.ReleaseId, $previousRelease.ReleaseId, $launchError.Exception.Message, $_.Exception.Message)
                        Write-Warning "The previous GEEM release could not be restored automatically."
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
    Remove-OldGeemCachedReleases -CacheRoot $cacheRoot -KeepReleaseIds $keepReleaseIds -MaximumVersionCount 2
}
catch {
    Write-GeemBootstrapFailure -Message ("GEEM could not start. {0}`n`nIf the problem continues, run Stop GEEM and contact support." -f $_.Exception.Message)
    exit 1
}
finally {
    $exitMutexCommand = Get-Command -Name "Exit-GeemCacheMutex" -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $exitMutexCommand) {
        Exit-GeemCacheMutex -Mutex $mutex
    }
    elseif ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
