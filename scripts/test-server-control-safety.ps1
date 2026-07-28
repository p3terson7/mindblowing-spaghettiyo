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
Assert-True -Condition ($unhealthyCurrentRelease.Action -eq "Restart" -and $unhealthyCurrentRelease.ForceRestart) -Message "an unhealthy current release must restart automatically"

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
$metadataProcess = [PSCustomObject]@{ ProcessName = "pwsh"; StartTime = $utcProcessStart }
$dateTimeMetadata = [PSCustomObject]@{ processStartedAtUtc = $utcProcessStart; scriptPath = $fixtureScriptPath }
Assert-True -Condition (Test-ServiceProcessMatchesMetadata -Process $metadataProcess -Metadata $dateTimeMetadata) -Message "JSON timestamps materialized as UTC DateTime values must not be shifted by the local timezone"

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

    return [PSCustomObject]@{
        IsRunning        = $true
        PortOwnerId       = 999
        TrackedProcessId  = 123
        Metadata          = [PSCustomObject]@{
            requestedProcessId = 123
            instanceToken = if ($script:testStatusMode -match "^tracked-graceful") {
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
        return [PSCustomObject]@{ ProcessName = "powershell" }
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
    return ($script:testStatusMode -eq "tracked-graceful" -or $script:testStatusMode -eq "tracked-graceful-timeout")
}

function Wait-ForProcessesToExit {
    param([int[]]$ProcessIds, [int]$TimeoutSeconds)

    $script:waitForProcessesCalls += 1
    if ($script:testStatusMode -eq "tracked-graceful-timeout" -and $script:waitForProcessesCalls -eq 1) {
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

Write-Host "Server control safety tests passed."
