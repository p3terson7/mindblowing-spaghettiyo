$ErrorActionPreference = "Stop"

$script:saphirLauncherControlDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

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
    $sourceServerScript = Join-Path -Path $DistributionRoot -ChildPath "apps/admin/backend/admin-server.ps1"
    $sourceLaunchScript = Join-Path -Path $DistributionRoot -ChildPath "scripts/launch-app.ps1"
    if ($preferSourceContext -and
        (Test-Path -LiteralPath $sourceServerScript -PathType Leaf) -and
        (Test-Path -LiteralPath $sourceLaunchScript -PathType Leaf)) {
        return [PSCustomObject]@{
            Kind            = "Source"
            ReleaseId       = "development"
            ApplicationRoot = [System.IO.Path]::GetFullPath($DistributionRoot)
            ServerScript    = [System.IO.Path]::GetFullPath($sourceServerScript)
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
        return [PSCustomObject]@{
            Kind            = "CachedRelease"
            ReleaseId       = [string]$activeRelease.ReleaseId
            ApplicationRoot = [string]$activeRelease.ReleasePath
            ServerScript    = Join-Path -Path ([string]$activeRelease.ReleasePath) -ChildPath "apps/admin/backend/admin-server.ps1"
            LaunchScript    = [string]$activeRelease.LaunchScript
        }
    }

    # A source checkout may be passed explicitly to a controller loaded from a
    # test or another local location. Retain that development workflow after the
    # normal cached-release lookup.
    if ((Test-Path -LiteralPath $sourceServerScript -PathType Leaf) -and
        (Test-Path -LiteralPath $sourceLaunchScript -PathType Leaf)) {
        return [PSCustomObject]@{
            Kind            = "Source"
            ReleaseId       = "development"
            ApplicationRoot = [System.IO.Path]::GetFullPath($DistributionRoot)
            ServerScript    = [System.IO.Path]::GetFullPath($sourceServerScript)
            LaunchScript    = [System.IO.Path]::GetFullPath($sourceLaunchScript)
        }
    }

    return [PSCustomObject]@{
        Kind            = "None"
        ReleaseId       = ""
        ApplicationRoot = ""
        ServerScript    = ""
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
        $configPath = Join-Path -Path ([string]$Context.ApplicationRoot) -ChildPath "apps/admin/backend/admin-config.psd1"
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
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
    $context = Get-SaphirLauncherApplicationContext -DistributionRoot $DistributionRoot -CacheRoot $CacheRoot
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

    $isManaged = [bool]($serviceStatus.TrackedProcessId -and
        $null -ne $serviceStatus.Metadata -and
        -not [string]::IsNullOrWhiteSpace($trackedScriptPath))
    $isExpectedInstance = $isManaged -and
        (Test-SaphirLauncherPathsEqual -FirstPath $trackedScriptPath -SecondPath ([string]$context.ServerScript))
    $isHealthy = $false
    if ($isExpectedInstance) {
        $isHealthy = Test-ManagedServiceHealthyForScript `
            -Name "app" `
            -DisplayName "SAPHIR Backend" `
            -ServerScript ([string]$context.ServerScript) `
            -Port 8081 `
            -PidFile $effectivePidFile `
            -FrontendUrl $frontendUrl `
            -TimeoutMilliseconds $ProbeTimeoutMilliseconds
    }

    $portOwnedByManagedInstance = $false
    if ($isManaged -and [bool]$serviceStatus.IsRunning) {
        $portOwnerId = if ($serviceStatus.PortOwnerId) { [int]$serviceStatus.PortOwnerId } else { 0 }
        $trackedProcessId = if ($serviceStatus.TrackedProcessId) { [int]$serviceStatus.TrackedProcessId } else { 0 }
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
    $manifestPath = Join-Path -Path $DistributionRoot -ChildPath "deployment/current.json"
    $adjacentBootstrapScript = Get-SaphirLauncherAdjacentBootstrapPath
    $distributionAvailable = (Test-Path -LiteralPath $bootstrapScript -PathType Leaf) -and
        (Test-Path -LiteralPath $manifestPath -PathType Leaf)
    $adjacentBootstrapAvailable = Test-Path -LiteralPath $adjacentBootstrapScript -PathType Leaf
    $localLaunchAvailable = -not [string]::IsNullOrWhiteSpace([string]$context.LaunchScript) -and
        (Test-Path -LiteralPath ([string]$context.LaunchScript) -PathType Leaf)
    # The adjacent bootstrap is only a mechanism. A first-time offline machine
    # still needs either a reachable deployment or an installed/source release.
    $launchAvailable = $distributionAvailable -or $localLaunchAvailable
    $canStart = $state -eq "Offline" -and $launchAvailable
    $canOpen = $state -eq "Online"
    $canRestart = ($state -eq "Online" -or $state -eq "Unresponsive") -and $launchAvailable
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
        ProcessId           = $serviceStatus.TrackedProcessId
        PortOwnerProcessId  = $serviceStatus.PortOwnerId
        Managed             = [bool]$isManaged
        ExpectedInstance    = [bool]$isExpectedInstance
        Healthy             = [bool]$isHealthy
        PortOwnedByManagedInstance = [bool]$portOwnedByManagedInstance
        DistributionAvailable = [bool]$distributionAvailable
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
