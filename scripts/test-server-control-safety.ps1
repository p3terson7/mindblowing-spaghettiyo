$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path
. (Join-Path -Path $repoRoot -ChildPath "scripts/lib/ServerControl.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$script:testStatusMode = "untracked"
$script:stoppedProcessIds = @()
$script:runningPowerShellProcesses = @()
$script:processCommandLines = @{}
$script:gracefulShutdownCalls = 0
$script:lastGracefulShutdownToken = ""
$script:waitForProcessesCalls = 0

function Get-RunningPowerShellProcesses {
    return @($script:runningPowerShellProcesses)
}

function Get-ProcessCommandLine {
    param([int]$ProcessId)

    $key = [string]$ProcessId
    if ($script:processCommandLines.ContainsKey($key)) {
        return [string]$script:processCommandLines[$key]
    }
    return ""
}

$quotedArguments = ConvertTo-WindowsPowerShellFileArguments -ScriptPath "C:\Users\Test User\SAPHIR Cache\admin-server.ps1"
Assert-True -Condition ($quotedArguments -eq '-NoProfile -ExecutionPolicy Bypass -File "C:\Users\Test User\SAPHIR Cache\admin-server.ps1"') -Message "Windows launch arguments must quote cached paths containing spaces"

$healthyCurrentRelease = Get-ManagedServiceLaunchPlan -IsRunning $true -HasTrackedProcess $true -IsExpectedManagedInstance $true -FrontendIsAvailable $true
Assert-True -Condition ($healthyCurrentRelease.Action -eq "Reuse" -and -not $healthyCurrentRelease.ForceRestart) -Message "a healthy current release must be reused"

$changedRelease = Get-ManagedServiceLaunchPlan -IsRunning $true -HasTrackedProcess $true -IsExpectedManagedInstance $false -FrontendIsAvailable $true
Assert-True -Condition ($changedRelease.Action -eq "Restart" -and $changedRelease.ForceRestart) -Message "a changed cached release must replace the tracked server"

$unhealthyCurrentRelease = Get-ManagedServiceLaunchPlan -IsRunning $true -HasTrackedProcess $true -IsExpectedManagedInstance $true -FrontendIsAvailable $false
Assert-True -Condition ($unhealthyCurrentRelease.Action -eq "Block" -and -not $unhealthyCurrentRelease.ForceRestart) -Message "a short health timeout must not authorize an automatic force restart"

$unrelatedListener = Get-ManagedServiceLaunchPlan -IsRunning $true -HasTrackedProcess $false -IsExpectedManagedInstance $false -FrontendIsAvailable $false
Assert-True -Condition ($unrelatedListener.Action -eq "Block" -and -not $unrelatedListener.ForceRestart) -Message "an unrelated port listener must remain protected"

$coldStart = Get-ManagedServiceLaunchPlan -IsRunning $false -HasTrackedProcess $false -IsExpectedManagedInstance $false -FrontendIsAvailable $false
Assert-True -Condition ($coldStart.Action -eq "Start" -and -not $coldStart.ForceRestart) -Message "a stopped app must start normally"

$explicitRestart = Get-ManagedServiceLaunchPlan -IsRunning $true -HasTrackedProcess $true -IsExpectedManagedInstance $true -FrontendIsAvailable $true -Force
Assert-True -Condition ($explicitRestart.Action -eq "Restart" -and $explicitRestart.ForceRestart) -Message "an explicit force request must restart a healthy release"

$fixtureScriptPath = [System.IO.Path]::GetFullPath((Join-Path -Path $repoRoot -ChildPath "fixture folder/admin-server.ps1"))
$fixtureProcess = [PSCustomObject]@{ Id = 999; ProcessName = "pwsh" }
$matchingCommandLine = 'pwsh -NoProfile -File "{0}"' -f $fixtureScriptPath
Assert-True -Condition (Test-ProcessRunsPowerShellFile -Process $fixtureProcess -ScriptPath $fixtureScriptPath -CommandLine $matchingCommandLine) -Message "an exact quoted -File script path must identify the managed app"
Assert-True -Condition (-not (Test-ProcessRunsPowerShellFile -Process $fixtureProcess -ScriptPath $fixtureScriptPath -CommandLine ('pwsh -NoProfile -File "{0}.other"' -f $fixtureScriptPath))) -Message "a script path prefix must not identify the managed app"
Assert-True -Condition (-not (Test-ProcessRunsPowerShellFile -Process $fixtureProcess -ScriptPath $fixtureScriptPath -CommandLine ('pwsh -NoProfile -File other.ps1 -Note "{0}"' -f $fixtureScriptPath))) -Message "mentioning the expected path outside -File must not identify the managed app"
Assert-True -Condition (-not (Test-ProcessRunsPowerShellFile -Process ([PSCustomObject]@{ Id = 998; ProcessName = "node" }) -ScriptPath $fixtureScriptPath -CommandLine $matchingCommandLine)) -Message "a non-PowerShell process must never identify as the managed app"

$utcProcessStart = [DateTime]::SpecifyKind([DateTime]::ParseExact("2026-07-14T00:36:59.3522070", "yyyy-MM-ddTHH:mm:ss.fffffff", [System.Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
$metadataProcess = [PSCustomObject]@{ Id = 997; ProcessName = "pwsh"; StartTime = $utcProcessStart }
$dateTimeMetadata = [PSCustomObject]@{
    pid                 = 997
    processStartedAtUtc = $utcProcessStart
    scriptPath          = $fixtureScriptPath
}
$script:processCommandLines["997"] = $matchingCommandLine
Assert-True -Condition (Test-ServiceProcessMatchesMetadata -Process $metadataProcess -Metadata $dateTimeMetadata) -Message "JSON timestamps materialized as UTC DateTime values and an exact command line must identify the managed process"
$script:processCommandLines["997"] = 'pwsh -NoProfile -File other-server.ps1'
Assert-True -Condition (-not (Test-ServiceProcessMatchesMetadata -Process $metadataProcess -Metadata $dateTimeMetadata)) -Message "matching PID timestamps without the exact -File script must not authorize a process"

$invalidMetadataRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-invalid-pid-{0}" -f [Guid]::NewGuid().ToString("N"))
$invalidPidFile = Join-Path -Path $invalidMetadataRoot -ChildPath "app.pid.json"
try {
    New-Item -ItemType Directory -Path $invalidMetadataRoot -Force | Out-Null
    Set-Content -LiteralPath $invalidPidFile -Value '{"pid":"not-a-number","scriptPath":"/tmp/admin-server.ps1","processStartedAtUtc":"2026-07-14T00:36:59.3522070Z"}' -Encoding UTF8
    Assert-True -Condition ($null -eq (Read-ServiceMetadata -PidFile $invalidPidFile)) -Message "malformed numeric PID metadata must be rejected without a cast exception"
    $invalidStatus = Get-ServiceStatus -Name "fixture" -DisplayName "Fixture" -Port 65534 -PidFile $invalidPidFile
    Assert-True -Condition ($null -eq $invalidStatus.TrackedProcessId -and $null -eq $invalidStatus.Metadata) -Message "malformed PID metadata must degrade to an untracked status"
    Assert-True -Condition (-not (Test-Path -LiteralPath $invalidPidFile)) -Message "invalid disposable PID metadata must be removed for recovery"
}
finally {
    if (Test-Path -LiteralPath $invalidMetadataRoot) {
        Remove-Item -LiteralPath $invalidMetadataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ServiceStatus {
    param($Name, $DisplayName, $Port, $PidFile)

    if ($script:testStatusMode -eq "untracked") {
        return [PSCustomObject]@{
            IsRunning        = $true
            PortOwnerId       = 999
            TrackedProcessId  = $null
            Metadata          = $null
        }
    }

    $candidateOnly = $script:testStatusMode -match "^candidate-"
    return [PSCustomObject]@{
        IsRunning        = $true
        PortOwnerId       = 999
        TrackedProcessId  = if ($candidateOnly) { $null } else { 123 }
        MetadataProcessId = 123
        MetadataProcess   = [PSCustomObject]@{ Id = 123; ProcessName = "powershell"; StartTime = $utcProcessStart }
        Metadata          = [PSCustomObject]@{
            pid                = 123
            requestedProcessId = 123
            scriptPath         = $fixtureScriptPath
            processStartedAtUtc = $utcProcessStart
            instanceToken = if ($script:testStatusMode -match "graceful|candidate-token") {
                "0123456789abcdef0123456789abcdef"
            }
            else {
                ""
            }
        }
    }
}

function Get-ManagedProcess {
    param([int]$ProcessId)

    if ($ProcessId -eq 123) {
        if ($script:testStatusMode -eq "candidate-token-pid-reused") {
            return [PSCustomObject]@{ Id = 123; ProcessName = "powershell"; StartTime = $utcProcessStart.AddMilliseconds(100) }
        }
        return [PSCustomObject]@{ Id = 123; ProcessName = "powershell"; StartTime = $utcProcessStart }
    }
    if ($ProcessId -eq 999) {
        return $fixtureProcess
    }
    return $null
}

function Stop-Process {
    param([int]$Id, [switch]$Force, $ErrorAction)
    $script:stoppedProcessIds += $Id
}

function Invoke-ManagedServiceGracefulShutdown {
    param([int]$Port, [string]$InstanceToken, [int]$TimeoutMilliseconds)

    $script:gracefulShutdownCalls += 1
    $script:lastGracefulShutdownToken = $InstanceToken
    return ($script:testStatusMode -eq "tracked-graceful" -or
        $script:testStatusMode -eq "tracked-graceful-timeout" -or
        $script:testStatusMode -eq "candidate-token-timeout" -or
        $script:testStatusMode -eq "candidate-token-pid-reused")
}

function Wait-ForProcessesToExit {
    param([int[]]$ProcessIds, [int]$TimeoutSeconds)

    $script:waitForProcessesCalls += 1
    if (($script:testStatusMode -eq "tracked-graceful-timeout" -or
        $script:testStatusMode -eq "candidate-token-timeout" -or
        $script:testStatusMode -eq "candidate-token-pid-reused") -and
        $script:waitForProcessesCalls -eq 1) {
        return $false
    }
    return $true
}

function Wait-ForPortState {
    param([int]$Port, [bool]$ShouldBeListening, [int]$TimeoutSeconds)
    return $null
}

function Remove-ServiceMetadata {
    param([string]$PidFile)
}

$untrackedError = ""
$script:runningPowerShellProcesses = @($fixtureProcess)
$script:processCommandLines["999"] = 'pwsh -NoProfile -File other-server.ps1'
try {
    Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
}
catch {
    $untrackedError = [string]$_.Exception.Message
}
Assert-True -Condition ($untrackedError -match "untracked process") -Message "stop must refuse an untracked port owner"
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 0) -Message "stop must not terminate an untracked process"
Assert-True -Condition ($script:gracefulShutdownCalls -eq 0) -Message "stop must not send a control request to an untracked listener"

$script:processCommandLines["999"] = $matchingCommandLine
Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 1 -and [int]$script:stoppedProcessIds[0] -eq 999) -Message "stop must recover and terminate an untracked instance with the exact managed script path"
Assert-True -Condition ($script:gracefulShutdownCalls -eq 0) -Message "script-path recovery without current token metadata must use the protected force fallback"

$script:testStatusMode = "tracked"
$script:stoppedProcessIds = @()
$script:runningPowerShellProcesses = @()
$script:processCommandLines["123"] = $matchingCommandLine
Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 1 -and [int]$script:stoppedProcessIds[0] -eq 123) -Message "stop must terminate only the tracked PowerShell process"
Assert-True -Condition ($script:stoppedProcessIds -notcontains 999) -Message "stop must never add an unrelated port owner"

$script:testStatusMode = "tracked-graceful"
$script:stoppedProcessIds = @()
$script:gracefulShutdownCalls = 0
$script:lastGracefulShutdownToken = ""
$script:waitForProcessesCalls = 0
Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
Assert-True -Condition ($script:gracefulShutdownCalls -eq 1) -Message "a tracked current instance must receive one graceful shutdown request"
Assert-True -Condition ($script:lastGracefulShutdownToken -eq "0123456789abcdef0123456789abcdef") -Message "graceful shutdown must use the tracked instance token"
Assert-True -Condition ($script:waitForProcessesCalls -eq 1) -Message "stop must wait for the backend to exit after graceful acknowledgement"
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 0) -Message "a successful graceful shutdown must not force-terminate the backend"

$script:testStatusMode = "tracked-graceful-timeout"
$script:stoppedProcessIds = @()
$script:gracefulShutdownCalls = 0
$script:waitForProcessesCalls = 0
Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
Assert-True -Condition ($script:gracefulShutdownCalls -eq 1) -Message "graceful shutdown must be attempted before fallback"
Assert-True -Condition ($script:waitForProcessesCalls -eq 2) -Message "a backend that ignores graceful shutdown must be checked again after force fallback"
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 1 -and [int]$script:stoppedProcessIds[0] -eq 123) -Message "a timed-out graceful shutdown must retain the existing force fallback"

$script:testStatusMode = "candidate-unverified"
$script:stoppedProcessIds = @()
$script:gracefulShutdownCalls = 0
$script:processCommandLines["123"] = 'pwsh -NoProfile -File other-server.ps1'
$candidateError = ""
try {
    Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
}
catch {
    $candidateError = [string]$_.Exception.Message
}
Assert-True -Condition ($candidateError -match "untracked process") -Message "a timestamp-only PID candidate must be refused when neither script nor HTTP token identity verifies it"
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 0) -Message "a timestamp-only PID candidate must never be force-killed"

$script:testStatusMode = "candidate-token-timeout"
$script:stoppedProcessIds = @()
$script:gracefulShutdownCalls = 0
$script:waitForProcessesCalls = 0
Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
Assert-True -Condition ($script:gracefulShutdownCalls -eq 1) -Message "a metadata candidate may be controlled through its exact HTTP instance token"
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 1 -and [int]$script:stoppedProcessIds[0] -eq 123) -Message "an exact HTTP token may authorize the force fallback when command-line inspection is unavailable"

$script:testStatusMode = "candidate-token-pid-reused"
$script:stoppedProcessIds = @()
$script:gracefulShutdownCalls = 0
$script:waitForProcessesCalls = 0
$pidReuseError = ""
try {
    Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
}
catch {
    $pidReuseError = [string]$_.Exception.Message
}
Assert-True -Condition ($pidReuseError -match "identity changed") -Message "a reused PID must invalidate earlier HTTP-token force-stop authority"
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 0) -Message "a new process that reused the verified PID must never be force-killed"

Write-Host "Server control safety tests passed."
