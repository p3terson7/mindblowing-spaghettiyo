$ErrorActionPreference = "Stop"

$script:saphirLauncherControlDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

$applicationLayoutCommand = Get-Command -Name "Resolve-SaphirApplicationLayout" -CommandType Function -ErrorAction SilentlyContinue
if ($null -eq $applicationLayoutCommand) {
    $applicationLayoutLibrary = Join-Path -Path $script:saphirLauncherControlDirectory -ChildPath "ApplicationLayout.ps1"
    if (-not (Test-Path -LiteralPath $applicationLayoutLibrary -PathType Leaf)) {
        throw "The SAPHIR application-layout library is unavailable."
    }
    . $applicationLayoutLibrary
}

$localCacheCommand = Get-Command -Name "Get-SaphirLocalAppRoot" -CommandType Function -ErrorAction SilentlyContinue
if ($null -eq $localCacheCommand) {
    $localCacheLibrary = Join-Path -Path $script:saphirLauncherControlDirectory -ChildPath "LocalAppCache.ps1"
    if (-not (Test-Path -LiteralPath $localCacheLibrary -PathType Leaf)) {
        throw "The SAPHIR local-cache library is unavailable."
    }
    . $localCacheLibrary
}

$serverControlCommand = Get-Command -Name "Get-ServiceStatus" -CommandType Function -ErrorAction SilentlyContinue
if ($null -eq $serverControlCommand) {
    $serverControlLibrary = Join-Path -Path $script:saphirLauncherControlDirectory -ChildPath "ServerControl.ps1"
    if (-not (Test-Path -LiteralPath $serverControlLibrary -PathType Leaf)) {
        throw "The SAPHIR service-control library is unavailable."
    }
    . $serverControlLibrary
}

function Get-SaphirLauncherRuntimeRoot {
    param([string]$RuntimeRoot = "")

    if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        return [System.IO.Path]::GetFullPath($RuntimeRoot)
    }

    $configuredRuntimeRoot = [string]$env:SAPHIR_RUNTIME_ROOT
    if ([string]::IsNullOrWhiteSpace($configuredRuntimeRoot)) {
        $configuredRuntimeRoot = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_RUNTIME_ROOT"))
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredRuntimeRoot)) {
        return [System.IO.Path]::GetFullPath($configuredRuntimeRoot)
    }

    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [string]$env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [string]$env:TEMP
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw "Unable to locate the SAPHIR runtime folder."
    }

    return (Join-Path -Path $localAppData -ChildPath "SAPHIR/runtime")
}

function Test-SaphirLauncherPathsEqual {
    param(
        [string]$FirstPath,
        [string]$SecondPath
    )

    if ([string]::IsNullOrWhiteSpace($FirstPath) -or [string]::IsNullOrWhiteSpace($SecondPath)) {
        return $false
    }

    try {
        $firstFullPath = [System.IO.Path]::GetFullPath($FirstPath)
        $secondFullPath = [System.IO.Path]::GetFullPath($SecondPath)
        $comparison = if (Test-IsWindowsHost) {
            [System.StringComparison]::OrdinalIgnoreCase
        }
        else {
            [System.StringComparison]::Ordinal
        }
        return $firstFullPath.Equals($secondFullPath, $comparison)
    }
    catch {
        return $false
    }
}

function Get-SaphirLauncherApplicationContext {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [string]$CacheRoot = ""
    )

    $scriptsDirectory = Split-Path -Path $script:saphirLauncherControlDirectory -Parent
    $controllerRoot = Split-Path -Path $scriptsDirectory -Parent
    $preferSourceContext = Test-SaphirLauncherPathsEqual -FirstPath $DistributionRoot -SecondPath $controllerRoot
    $sourceLayout = Resolve-SaphirApplicationLayout -ApplicationRoot $DistributionRoot
    $sourceLaunchScript = Join-Path -Path $DistributionRoot -ChildPath "scripts/launch-app.ps1"
    if ($preferSourceContext -and
        $null -ne $sourceLayout -and
        (Test-Path -LiteralPath $sourceLaunchScript -PathType Leaf)) {
        return [PSCustomObject]@{
            Kind            = "Source"
            ReleaseId       = "development"
            ApplicationRoot = [System.IO.Path]::GetFullPath($DistributionRoot)
            LayoutKind      = [string]$sourceLayout.Kind
            ServerScript    = [string]$sourceLayout.ServerScript
            ConfigPath      = [string]$sourceLayout.ConfigPath
            LaunchScript    = [System.IO.Path]::GetFullPath($sourceLaunchScript)
        }
    }

    # Installed launchers resolve the local active pointer before touching the
    # application share. This keeps ordinary status refreshes local and fast.
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = Get-SaphirLocalAppRoot
    }

    $activeRelease = Get-SaphirActiveRelease -CacheRoot $CacheRoot
    if ($null -ne $activeRelease) {
        $cachedLayout = Resolve-SaphirApplicationLayout -ApplicationRoot ([string]$activeRelease.ReleasePath)
        if ($null -ne $cachedLayout) {
            return [PSCustomObject]@{
                Kind            = "CachedRelease"
                ReleaseId       = [string]$activeRelease.ReleaseId
                ApplicationRoot = [string]$activeRelease.ReleasePath
                LayoutKind      = [string]$cachedLayout.Kind
                ServerScript    = [string]$cachedLayout.ServerScript
                ConfigPath      = [string]$cachedLayout.ConfigPath
                LaunchScript    = [string]$activeRelease.LaunchScript
            }
        }
    }

    # A source checkout may be passed explicitly to a controller loaded from a
    # test or another local location. Retain that development workflow after the
    # normal cached-release lookup.
    if ($null -ne $sourceLayout -and
        (Test-Path -LiteralPath $sourceLaunchScript -PathType Leaf)) {
        return [PSCustomObject]@{
            Kind            = "Source"
            ReleaseId       = "development"
            ApplicationRoot = [System.IO.Path]::GetFullPath($DistributionRoot)
            LayoutKind      = [string]$sourceLayout.Kind
            ServerScript    = [string]$sourceLayout.ServerScript
            ConfigPath      = [string]$sourceLayout.ConfigPath
            LaunchScript    = [System.IO.Path]::GetFullPath($sourceLaunchScript)
        }
    }

    return [PSCustomObject]@{
        Kind            = "None"
        ReleaseId       = ""
        ApplicationRoot = ""
        LayoutKind      = ""
        ServerScript    = ""
        ConfigPath      = ""
        LaunchScript    = ""
    }
}

function Get-SaphirLauncherAdjacentBootstrapPath {
    $scriptsDirectory = Split-Path -Path $script:saphirLauncherControlDirectory -Parent
    return (Join-Path -Path $scriptsDirectory -ChildPath "launch-cached-app.ps1")
}

function Get-SaphirLauncherPreviousProductPidFile {
    if (-not (Test-IsWindowsHost)) {
        return ""
    }

    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [string]$env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        return ""
    }

    $previousRuntimeRoot = Join-Path -Path $localAppData -ChildPath (("Overtime" + "Manager") + "/runtime")
    return (Join-Path -Path $previousRuntimeRoot -ChildPath "pids/app.pid.json")
}

function Get-SaphirLauncherManifestDataFolder {
    param([Parameter(Mandatory = $true)][string]$DistributionRoot)

    $manifestPath = Join-Path -Path $DistributionRoot -ChildPath "deployment/current.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return ""
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $dataFolderPath = [string]$manifest.dataFolderPath
        if ([string]::IsNullOrWhiteSpace($dataFolderPath) -or -not [System.IO.Path]::IsPathRooted($dataFolderPath)) {
            return ""
        }
        return [System.IO.Path]::GetFullPath($dataFolderPath)
    }
    catch {
        return ""
    }
}

function Get-SaphirLauncherConfiguredDataFolder {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$DistributionRoot
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Context.ApplicationRoot)) {
        $configPath = ""
        if ($Context.PSObject.Properties.Name -contains "ConfigPath") {
            $configPath = [string]$Context.ConfigPath
        }
        if ([string]::IsNullOrWhiteSpace($configPath)) {
            $contextLayout = Resolve-SaphirApplicationLayout -ApplicationRoot ([string]$Context.ApplicationRoot)
            if ($null -ne $contextLayout) {
                $configPath = [string]$contextLayout.ConfigPath
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($configPath) -and
            (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            try {
                $config = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
                $configuredPath = [string]$config.DataFolderPath
                if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
                    if ([System.IO.Path]::IsPathRooted($configuredPath)) {
                        return [System.IO.Path]::GetFullPath($configuredPath)
                    }

                    $configDirectory = Split-Path -Path $configPath -Parent
                    return [System.IO.Path]::GetFullPath((Join-Path -Path $configDirectory -ChildPath $configuredPath))
                }
            }
            catch {
            }
        }
    }

    return (Get-SaphirLauncherManifestDataFolder -DistributionRoot $DistributionRoot)
}

function Get-SaphirLauncherDeploymentSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [string]$InstalledReleaseId = "",
        [string]$CacheRoot = "",
        [switch]$DevelopmentContext
    )

    $resolvedDistributionRoot = [System.IO.Path]::GetFullPath($DistributionRoot)
    $manifestPath = Join-Path -Path $resolvedDistributionRoot -ChildPath "deployment/current.json"
    $snapshot = [ordered]@{
        State                  = "Unavailable"
        DistributionRoot       = $resolvedDistributionRoot
        DistributionReachable  = $false
        ManifestPath           = $manifestPath
        ManifestAvailable      = $false
        ManifestValid          = $false
        TargetReleaseId        = ""
        TargetSha256           = ""
        PackagePath            = ""
        PackageAvailable       = $false
        TargetDataFolderPath   = ""
        TargetDataAvailable    = $false
        UpdateAvailable        = $false
        TargetPreviouslyFailed = $false
        Issue                  = "DistributionUnavailable"
        Error                  = "The configured SAPHIR distribution folder is unavailable: $resolvedDistributionRoot"
    }

    if ($DevelopmentContext) {
        $snapshot.State = "Development"
        $snapshot.DistributionReachable = $true
        $snapshot.Issue = ""
        $snapshot.Error = ""
        return [PSCustomObject]$snapshot
    }

    try {
        $snapshot.DistributionReachable = Test-Path -LiteralPath $resolvedDistributionRoot -PathType Container -ErrorAction Stop
    }
    catch {
        $snapshot.Error = "The configured SAPHIR distribution folder could not be checked: $resolvedDistributionRoot. $($_.Exception.Message)"
        return [PSCustomObject]$snapshot
    }
    if (-not $snapshot.DistributionReachable) {
        return [PSCustomObject]$snapshot
    }

    try {
        $snapshot.ManifestAvailable = Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction Stop
    }
    catch {
        $snapshot.State = "ManifestUnavailable"
        $snapshot.Issue = "ManifestUnavailable"
        $snapshot.Error = "The SAPHIR release pointer could not be checked: $manifestPath. $($_.Exception.Message)"
        return [PSCustomObject]$snapshot
    }
    if (-not $snapshot.ManifestAvailable) {
        $snapshot.State = "ManifestMissing"
        $snapshot.Issue = "ManifestMissing"
        $snapshot.Error = "No SAPHIR release is published because the release pointer is missing: $manifestPath. A ZIP in deployment/releases is not enough; publish the application release so current.json is updated."
        return [PSCustomObject]$snapshot
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $snapshot.State = "InvalidManifest"
        $snapshot.Issue = "ManifestUnreadable"
        $snapshot.Error = "The SAPHIR release pointer is unreadable or incomplete: $manifestPath. Republish the application release. $($_.Exception.Message)"
        return [PSCustomObject]$snapshot
    }

    if ($null -eq $manifest -or [int]$manifest.schemaVersion -ne 1) {
        $snapshot.State = "InvalidManifest"
        $snapshot.Issue = "ManifestFormatUnsupported"
        $snapshot.Error = "The SAPHIR release pointer uses an unsupported format: $manifestPath. Republish it with the current packaging script."
        return [PSCustomObject]$snapshot
    }

    $snapshot.TargetReleaseId = [string]$manifest.releaseId
    if (-not (Test-SaphirReleaseId -ReleaseId $snapshot.TargetReleaseId)) {
        $snapshot.State = "InvalidManifest"
        $snapshot.Issue = "ReleaseIdInvalid"
        $snapshot.Error = "The SAPHIR release identifier in current.json is invalid. Publish the release again with a new Windows-safe ReleaseId."
        return [PSCustomObject]$snapshot
    }

    $snapshot.TargetSha256 = ([string]$manifest.sha256).Trim().ToLowerInvariant()
    if ($snapshot.TargetSha256 -notmatch "^[a-f0-9]{64}$") {
        $snapshot.State = "InvalidManifest"
        $snapshot.Issue = "ChecksumInvalid"
        $snapshot.Error = "The checksum for release '$($snapshot.TargetReleaseId)' is invalid. Republish the release instead of editing current.json manually."
        return [PSCustomObject]$snapshot
    }

    try {
        $snapshot.PackagePath = Resolve-SaphirPackagePath `
            -DistributionRoot $resolvedDistributionRoot `
            -RelativePackagePath ([string]$manifest.packagePath)
    }
    catch {
        $snapshot.State = "InvalidManifest"
        $snapshot.Issue = "PackagePathInvalid"
        $snapshot.Error = "The package path for release '$($snapshot.TargetReleaseId)' is invalid. Republish the application release. $($_.Exception.Message)"
        return [PSCustomObject]$snapshot
    }

    $snapshot.TargetDataFolderPath = [string]$manifest.dataFolderPath
    if ([string]::IsNullOrWhiteSpace($snapshot.TargetDataFolderPath) -or
        -not [System.IO.Path]::IsPathRooted($snapshot.TargetDataFolderPath)) {
        $snapshot.State = "InvalidManifest"
        $snapshot.Issue = "DataPathInvalid"
        $snapshot.Error = "Release '$($snapshot.TargetReleaseId)' does not contain an absolute shared-data path. Republish it with the correct DataFolderPath."
        return [PSCustomObject]$snapshot
    }
    $snapshot.ManifestValid = $true

    try {
        $snapshot.PackageAvailable = Test-Path -LiteralPath $snapshot.PackagePath -PathType Leaf -ErrorAction Stop
    }
    catch {
        $snapshot.PackageAvailable = $false
    }
    if (-not $snapshot.PackageAvailable) {
        $snapshot.State = "PackageUnavailable"
        $snapshot.Issue = "PackageUnavailable"
        $snapshot.Error = "current.json targets release '$($snapshot.TargetReleaseId)', but its ZIP is unavailable: $($snapshot.PackagePath). Republish that release or restore its matching ZIP."
        return [PSCustomObject]$snapshot
    }

    try {
        $snapshot.TargetDataAvailable = Test-Path -LiteralPath $snapshot.TargetDataFolderPath -PathType Container -ErrorAction Stop
    }
    catch {
        $snapshot.TargetDataAvailable = $false
    }
    if (-not $snapshot.TargetDataAvailable) {
        $snapshot.State = "DataUnavailable"
        $snapshot.Issue = "TargetDataUnavailable"
        $snapshot.Error = "Release '$($snapshot.TargetReleaseId)' points to an unavailable shared-data folder: $($snapshot.TargetDataFolderPath). Restore network access or republish with the correct path."
        return [PSCustomObject]$snapshot
    }

    $snapshot.UpdateAvailable = [string]::IsNullOrWhiteSpace($InstalledReleaseId) -or
        -not ([string]$snapshot.TargetReleaseId).Equals([string]$InstalledReleaseId, [System.StringComparison]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = Get-SaphirLocalAppRoot
    }
    $failedRelease = Get-SaphirFailedRelease -CacheRoot $CacheRoot
    $snapshot.TargetPreviouslyFailed = $null -ne $failedRelease -and
        [string]$failedRelease.ReleaseId -eq [string]$snapshot.TargetReleaseId -and
        [string]$failedRelease.Sha256 -eq [string]$snapshot.TargetSha256

    if ($snapshot.TargetPreviouslyFailed -and $snapshot.UpdateAvailable) {
        $bootstrapLogPath = Join-Path -Path $CacheRoot -ChildPath "runtime/logs/bootstrap.log"
        $snapshot.State = "PreviouslyFailed"
        $snapshot.Issue = "TargetPreviouslyFailed"
        $snapshot.Error = "Release '$($snapshot.TargetReleaseId)' is published, but the same package previously failed on this computer. Reinstall the current SAPHIR launcher from the distribution to unlock a release rejected by an older launcher. If it still fails, review $bootstrapLogPath and publish a corrected package with a new ReleaseId."
        return [PSCustomObject]$snapshot
    }

    $snapshot.State = "Ready"
    $snapshot.Issue = ""
    $snapshot.Error = ""
    return [PSCustomObject]$snapshot
}

function Get-SaphirLauncherStatus {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [string]$CacheRoot = "",
        [string]$RuntimeRoot = "",
        [int]$ProbeTimeoutMilliseconds = 900
    )

    if ([string]::IsNullOrWhiteSpace($DistributionRoot)) {
        throw "The SAPHIR distribution folder is required."
    }
    if ($ProbeTimeoutMilliseconds -lt 100) {
        $ProbeTimeoutMilliseconds = 100
    }

    $resolvedRuntimeRoot = Get-SaphirLauncherRuntimeRoot -RuntimeRoot $RuntimeRoot
    $pidFile = Join-Path -Path $resolvedRuntimeRoot -ChildPath "pids/app.pid.json"
    $logsPath = Join-Path -Path $resolvedRuntimeRoot -ChildPath "logs"
    $frontendUrl = "http://localhost:8081/"
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = Get-SaphirLocalAppRoot
    }
    $context = Get-SaphirLauncherApplicationContext -DistributionRoot $DistributionRoot -CacheRoot $CacheRoot
    $deployment = Get-SaphirLauncherDeploymentSnapshot `
        -DistributionRoot $DistributionRoot `
        -InstalledReleaseId ([string]$context.ReleaseId) `
        -CacheRoot $CacheRoot `
        -DevelopmentContext:([string]$context.Kind -eq "Source")
    $serviceStatus = Get-ServiceStatus -Name "app" -DisplayName "SAPHIR Backend" -Port 8081 -PidFile $pidFile
    $effectivePidFile = $pidFile
    $usingPreviousProductMetadata = $false

    # A verified backend from before the SAPHIR rename is tracked under the
    # previous AppData root. Treat it as a recoverable managed instance rather
    # than as a foreign port conflict, while retaining the same PID safeguards.
    if ([bool]$serviceStatus.IsRunning -and -not $serviceStatus.TrackedProcessId) {
        $previousPidFile = Get-SaphirLauncherPreviousProductPidFile
        if (-not [string]::IsNullOrWhiteSpace($previousPidFile)) {
            $previousStatus = Get-ServiceStatus `
                -Name "previous-product" `
                -DisplayName "Previous SAPHIR Backend" `
                -Port 8081 `
                -PidFile $previousPidFile
            if ($previousStatus.TrackedProcessId) {
                $serviceStatus = $previousStatus
                $effectivePidFile = $previousPidFile
                $usingPreviousProductMetadata = $true
                $previousRuntimeRoot = Split-Path -Path (Split-Path -Path $previousPidFile -Parent) -Parent
                $logsPath = Join-Path -Path $previousRuntimeRoot -ChildPath "logs"
            }
        }
    }

    $trackedScriptPath = ""
    if ($null -ne $serviceStatus.Metadata -and $serviceStatus.Metadata.scriptPath) {
        try {
            $trackedScriptPath = [System.IO.Path]::GetFullPath([string]$serviceStatus.Metadata.scriptPath)
        }
        catch {
            $trackedScriptPath = ""
        }
    }

    $metadataProcessId = if ($serviceStatus.TrackedProcessId) {
        [int]$serviceStatus.TrackedProcessId
    }
    elseif ($serviceStatus.PSObject.Properties.Name -contains "MetadataProcessId" -and $serviceStatus.MetadataProcessId) {
        [int]$serviceStatus.MetadataProcessId
    }
    else {
        0
    }
    $metadataTargetsExpectedInstance = $metadataProcessId -gt 0 -and
        $null -ne $serviceStatus.Metadata -and
        -not [string]::IsNullOrWhiteSpace($trackedScriptPath) -and
        (Test-SaphirLauncherPathsEqual -FirstPath $trackedScriptPath -SecondPath ([string]$context.ServerScript))
    $isHealthy = $false
    if ($metadataTargetsExpectedInstance) {
        $isHealthy = Test-ManagedServiceHealthyForScript `
            -Name "app" `
            -DisplayName "SAPHIR Backend" `
            -ServerScript ([string]$context.ServerScript) `
            -Port 8081 `
            -PidFile $effectivePidFile `
            -FrontendUrl $frontendUrl `
            -TimeoutMilliseconds $ProbeTimeoutMilliseconds
    }
    $isManaged = [bool]($serviceStatus.TrackedProcessId -or
        ($metadataTargetsExpectedInstance -and $isHealthy))
    $isExpectedInstance = $isManaged -and $metadataTargetsExpectedInstance

    $portOwnedByManagedInstance = $false
    if ($isManaged -and [bool]$serviceStatus.IsRunning) {
        $portOwnerId = if ($serviceStatus.PortOwnerId) { [int]$serviceStatus.PortOwnerId } else { 0 }
        $trackedProcessId = $metadataProcessId
        $portOwnedByManagedInstance = $portOwnerId -gt 0 -and
            ($portOwnerId -eq $trackedProcessId -or (Test-IsWindowsHost -and $portOwnerId -eq 4))
    }
    $hasPortConflict = [bool]$serviceStatus.IsRunning -and
        -not $isHealthy -and
        -not $portOwnedByManagedInstance

    $state = "Offline"
    $detail = "SAPHIR is stopped."
    if ($isHealthy) {
        $state = "Online"
        $detail = "SAPHIR is running."
    }
    elseif ($hasPortConflict) {
        $state = "PortConflict"
        $detail = "Port 8081 is being used by another program."
    }
    elseif ($isManaged) {
        $state = "Unresponsive"
        if ($isExpectedInstance) {
            $detail = "SAPHIR is running but did not answer its health check."
        }
        else {
            $detail = "A managed SAPHIR process is running from another application version."
        }
    }

    $dataFolderPath = Get-SaphirLauncherConfiguredDataFolder -Context $context -DistributionRoot $DistributionRoot
    $dataAvailable = $false
    if (-not [string]::IsNullOrWhiteSpace($dataFolderPath)) {
        try {
            $dataAvailable = Test-Path -LiteralPath $dataFolderPath -PathType Container
        }
        catch {
            $dataAvailable = $false
        }
    }
    if (-not $dataAvailable -and $state -eq "Online") {
        $detail = "$detail The shared data folder is unavailable."
    }

    $bootstrapScript = Join-Path -Path $DistributionRoot -ChildPath "scripts/launch-cached-app.ps1"
    $adjacentBootstrapScript = Get-SaphirLauncherAdjacentBootstrapPath
    $distributionAvailable = [string]$deployment.State -eq "Ready" -or
        [string]$deployment.State -eq "PreviouslyFailed" -or
        [string]$deployment.State -eq "Development"
    $adjacentBootstrapAvailable = Test-Path -LiteralPath $adjacentBootstrapScript -PathType Leaf
    $localLaunchAvailable = -not [string]::IsNullOrWhiteSpace([string]$context.LaunchScript) -and
        (Test-Path -LiteralPath ([string]$context.LaunchScript) -PathType Leaf)
    # The adjacent bootstrap is only a mechanism. A first-time offline machine
    # still needs either a reachable deployment or an installed/source release.
    $launchAvailable = $distributionAvailable -or $localLaunchAvailable
    $canStart = $state -eq "Offline" -and $launchAvailable
    $canOpen = $state -eq "Online"
    # A short probe timeout against the serialized backend can mean "busy", not
    # "dead". Only a healthy instance or a verified different release may expose
    # Restart; an expected-but-unresponsive instance remains stoppable explicitly.
    $canRestart = ($state -eq "Online" -or
        ($state -eq "Unresponsive" -and -not $isExpectedInstance)) -and
        $launchAvailable
    $canStop = $isManaged -and ($state -eq "Online" -or $state -eq "Unresponsive")

    $stdoutLog = Join-Path -Path $logsPath -ChildPath "app.stdout.log"
    $stderrLog = Join-Path -Path $logsPath -ChildPath "app.stderr.log"
    if ($null -ne $serviceStatus.Metadata) {
        if ($serviceStatus.Metadata.stdoutLog) {
            $stdoutLog = [string]$serviceStatus.Metadata.stdoutLog
        }
        if ($serviceStatus.Metadata.stderrLog) {
            $stderrLog = [string]$serviceStatus.Metadata.stderrLog
        }
    }

    return [PSCustomObject]@{
        SchemaVersion       = 1
        State               = $state
        ReleaseId           = [string]$context.ReleaseId
        ContextKind         = [string]$context.Kind
        ApplicationRoot     = [string]$context.ApplicationRoot
        ServerScript        = [string]$context.ServerScript
        TrackedScriptPath   = $trackedScriptPath
        LaunchScript        = [string]$context.LaunchScript
        DataAvailable       = [bool]$dataAvailable
        DataFolderPath      = [string]$dataFolderPath
        Detail              = $detail
        CanStart            = [bool]$canStart
        CanOpen             = [bool]$canOpen
        CanRestart          = [bool]$canRestart
        CanStop             = [bool]$canStop
        FrontendUrl         = $frontendUrl
        LogsPath            = $logsPath
        StdOutLog           = $stdoutLog
        StdErrLog           = $stderrLog
        ProcessId           = if ($serviceStatus.TrackedProcessId) { $serviceStatus.TrackedProcessId } else { $metadataProcessId }
        PortOwnerProcessId  = $serviceStatus.PortOwnerId
        Managed             = [bool]$isManaged
        ExpectedInstance    = [bool]$isExpectedInstance
        Healthy             = [bool]$isHealthy
        PortOwnedByManagedInstance = [bool]$portOwnedByManagedInstance
        DistributionAvailable = [bool]$distributionAvailable
        DistributionRoot    = [string]$deployment.DistributionRoot
        DistributionReachable = [bool]$deployment.DistributionReachable
        DeploymentState     = [string]$deployment.State
        DeploymentIssue     = [string]$deployment.Issue
        DeploymentError     = [string]$deployment.Error
        ManifestPath        = [string]$deployment.ManifestPath
        ManifestAvailable   = [bool]$deployment.ManifestAvailable
        ManifestValid       = [bool]$deployment.ManifestValid
        TargetReleaseId     = [string]$deployment.TargetReleaseId
        TargetSha256        = [string]$deployment.TargetSha256
        TargetPackagePath   = [string]$deployment.PackagePath
        TargetPackageAvailable = [bool]$deployment.PackageAvailable
        TargetDataFolderPath = [string]$deployment.TargetDataFolderPath
        TargetDataAvailable = [bool]$deployment.TargetDataAvailable
        UpdateAvailable     = [bool]$deployment.UpdateAvailable
        TargetPreviouslyFailed = [bool]$deployment.TargetPreviouslyFailed
        BootstrapScript     = if ($adjacentBootstrapAvailable) { $adjacentBootstrapScript } else { $bootstrapScript }
        PreviousProductInstance = [bool]$usingPreviousProductMetadata
        RuntimeRoot         = $resolvedRuntimeRoot
        PidFile             = $effectivePidFile
    }
}

function Stop-SaphirLauncherApp {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [string]$CacheRoot = "",
        [string]$RuntimeRoot = "",
        [switch]$Quiet
    )

    $status = Get-SaphirLauncherStatus `
        -DistributionRoot $DistributionRoot `
        -CacheRoot $CacheRoot `
        -RuntimeRoot $RuntimeRoot

    if ($status.State -eq "PortConflict") {
        throw "SAPHIR was not stopped because port 8081 belongs to another program."
    }
    if ($status.State -eq "Offline") {
        return $false
    }
    if (-not $status.Managed) {
        throw "SAPHIR was not stopped because its running process could not be verified."
    }

    $serverScript = if (-not [string]::IsNullOrWhiteSpace([string]$status.TrackedScriptPath)) {
        [string]$status.TrackedScriptPath
    }
    else {
        [string]$status.ServerScript
    }

    return [bool](Stop-ManagedService `
        -Name "app" `
        -DisplayName "SAPHIR Backend" `
        -Port 8081 `
        -PidFile ([string]$status.PidFile) `
        -ServerScript $serverScript `
        -Quiet:$Quiet)
}

function Invoke-SaphirLauncherScriptProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$DistributionRoot = "",
        [switch]$Force,
        [int]$TimeoutSeconds = 180
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "The SAPHIR launch script is unavailable: $ScriptPath"
    }
    if ($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 600) {
        throw "The SAPHIR launch timeout must be between 5 and 600 seconds."
    }

    $command = Get-Command -Name $ScriptPath -ErrorAction Stop
    $optionalArguments = @()
    if ($command.Parameters.ContainsKey("NoBrowser")) {
        $optionalArguments += "-NoBrowser"
    }
    if ($command.Parameters.ContainsKey("NonInteractive")) {
        $optionalArguments += "-NonInteractive"
    }
    if ($Force -and $command.Parameters.ContainsKey("Force")) {
        $optionalArguments += "-Force"
    }
    if (-not [string]::IsNullOrWhiteSpace($DistributionRoot) -and
        $command.Parameters.ContainsKey("DistributionRoot")) {
        $optionalArguments += "-DistributionRoot"
        $optionalArguments += $DistributionRoot
    }

    if (Test-IsWindowsHost) {
        $powerShellExecutable = Join-Path -Path ([string]$env:SystemRoot) -ChildPath "System32/WindowsPowerShell/v1.0/powershell.exe"
        if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
            $powerShellExecutable = Get-PowerShellExecutable
        }
        $arguments = ConvertTo-WindowsPowerShellFileArguments -ScriptPath $ScriptPath
        foreach ($argument in $optionalArguments) {
            if ([string]$argument -match "^-") {
                $arguments += " " + [string]$argument
                continue
            }
            if ([string]$argument -match '"') {
                throw "A SAPHIR launch argument cannot contain a double quote."
            }
            $arguments += ' "{0}"' -f [string]$argument
        }
        $process = Start-Process `
            -FilePath $powerShellExecutable `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -PassThru
        try {
            # Start-Process -Wait follows the whole descendant process tree on
            # Windows. The cached bootstrap starts the long-lived SAPHIR
            # backend, so -Wait would not return until the server stopped.
            # Process.WaitForExit waits for this bootstrap process only.
            $bootstrapExited = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $bootstrapExited) {
                try {
                    Stop-Process -Id ([int]$process.Id) -Force -ErrorAction SilentlyContinue
                }
                catch {
                }
                throw "SAPHIR's startup helper did not finish within $TimeoutSeconds seconds."
            }
            $process.Refresh()
            $exitCode = [int]$process.ExitCode
        }
        finally {
            $process.Dispose()
        }
    }
    else {
        $powerShellExecutable = Get-PowerShellExecutable
        & $powerShellExecutable -NoProfile -File $ScriptPath @optionalArguments
        $exitCode = [int]$LASTEXITCODE
    }

    if ($exitCode -ne 0) {
        throw "SAPHIR could not complete the requested action (exit code $exitCode)."
    }
}

function Invoke-SaphirLauncherAction {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Start", "Restart", "Stop")]
        [string]$Action,
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [string]$CacheRoot = "",
        [string]$RuntimeRoot = ""
    )

    $status = Get-SaphirLauncherStatus `
        -DistributionRoot $DistributionRoot `
        -CacheRoot $CacheRoot `
        -RuntimeRoot $RuntimeRoot

    if ($Action -eq "Stop") {
        [void](Stop-SaphirLauncherApp `
            -DistributionRoot $DistributionRoot `
            -CacheRoot $CacheRoot `
            -RuntimeRoot $RuntimeRoot `
            -Quiet)
        return (Get-SaphirLauncherStatus `
            -DistributionRoot $DistributionRoot `
            -CacheRoot $CacheRoot `
            -RuntimeRoot $RuntimeRoot)
    }

    if ($status.State -eq "PortConflict") {
        throw "SAPHIR cannot start because port 8081 belongs to another program."
    }
    if ($Action -eq "Start" -and $status.State -eq "Online") {
        return $status
    }
    if ($Action -eq "Start" -and -not $status.CanStart) {
        throw "SAPHIR cannot be started from its current state."
    }
    if ($Action -eq "Restart" -and -not $status.CanRestart) {
        throw "SAPHIR cannot be restarted from its current state."
    }

    if ($Action -eq "Restart") {
        # Stop through the launcher status that identified the exact managed
        # process before invoking the cached bootstrap. This also lets the
        # rename-compatibility path stop a verified pre-SAPHIR instance whose
        # PID metadata lives under the former AppData root.
        [void](Stop-SaphirLauncherApp `
            -DistributionRoot $DistributionRoot `
            -CacheRoot $CacheRoot `
            -RuntimeRoot $RuntimeRoot `
            -Quiet)
    }

    $adjacentBootstrapScript = Get-SaphirLauncherAdjacentBootstrapPath
    $distributionBootstrapScript = Join-Path -Path $DistributionRoot -ChildPath "scripts/launch-cached-app.ps1"
    $launchScript = if (Test-Path -LiteralPath $adjacentBootstrapScript -PathType Leaf) {
        $adjacentBootstrapScript
    }
    elseif (Test-Path -LiteralPath $distributionBootstrapScript -PathType Leaf) {
        $distributionBootstrapScript
    }
    else {
        [string]$status.LaunchScript
    }
    Invoke-SaphirLauncherScriptProcess `
        -ScriptPath $launchScript `
        -DistributionRoot $DistributionRoot `
        -Force:$false

    return (Get-SaphirLauncherStatus `
        -DistributionRoot $DistributionRoot `
        -CacheRoot $CacheRoot `
        -RuntimeRoot $RuntimeRoot)
}
