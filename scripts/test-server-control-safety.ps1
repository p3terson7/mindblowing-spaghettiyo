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

function Wait-ForProcessesToExit {
    param([int[]]$ProcessIds, [int]$TimeoutSeconds)
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

$script:processCommandLines["999"] = $matchingCommandLine
Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 1 -and [int]$script:stoppedProcessIds[0] -eq 999) -Message "stop must recover and terminate an untracked instance with the exact managed script path"

$script:testStatusMode = "tracked"
$script:stoppedProcessIds = @()
$script:runningPowerShellProcesses = @()
Stop-ManagedService -Name "app" -DisplayName "SAPHIR" -Port 8081 -PidFile "fixture.json" -ServerScript $fixtureScriptPath -Quiet | Out-Null
Assert-True -Condition ($script:stoppedProcessIds.Count -eq 1 -and [int]$script:stoppedProcessIds[0] -eq 123) -Message "stop must terminate only the tracked PowerShell process"
Assert-True -Condition ($script:stoppedProcessIds -notcontains 999) -Message "stop must never add an unrelated port owner"

Write-Host "Server control safety tests passed."
