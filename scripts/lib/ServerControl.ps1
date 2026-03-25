$ErrorActionPreference = "Stop"

function Test-IsWindowsHost {
    return ($PSVersionTable.PSEdition -eq "Desktop") -or ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function ConvertTo-ShellSingleQuotedLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $escapedSingleQuote = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return $singleQuote + ($Value -replace [regex]::Escape($singleQuote), $escapedSingleQuote) + $singleQuote
}

function Get-PowerShellExecutable {
    $candidates = @("pwsh", "powershell", "powershell.exe")
    foreach ($candidate in $candidates) {
        $command = Get-Command -Name $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [string]$command.Source
        }
    }

    throw "Unable to find a PowerShell executable. Install PowerShell and make sure 'pwsh' or 'powershell' is available on PATH."
}

function Open-UriInDefaultBrowser {
    param([Parameter(Mandatory = $true)][string]$Uri)

    if (Test-IsWindowsHost) {
        Start-Process -FilePath $Uri | Out-Null
        return
    }

    $openCommand = Get-Command -Name "open" -ErrorAction SilentlyContinue
    if ($null -ne $openCommand) {
        & $openCommand.Source $Uri | Out-Null
        return
    }

    $xdgOpen = Get-Command -Name "xdg-open" -ErrorAction SilentlyContinue
    if ($null -ne $xdgOpen) {
        & $xdgOpen.Source $Uri | Out-Null
        return
    }

    throw "Unable to open the browser automatically. Open this URL manually: $Uri"
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-ListeningProcessId {
    param([Parameter(Mandatory = $true)][int]$Port)

    if (Test-IsWindowsHost) {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $connection) {
            return [int]$connection.OwningProcess
        }
        return $null
    }

    $lsof = Get-Command -Name "lsof" -ErrorAction SilentlyContinue
    if ($null -eq $lsof) {
        return $null
    }

    $result = & $lsof.Source -t -nP "-iTCP:$Port" "-sTCP:LISTEN" 2>$null | Select-Object -First 1
    if ($null -eq $result) {
        return $null
    }

    $rawValue = [string]$result
    if ($rawValue -match "^\d+$") {
        return [int]$rawValue
    }

    return $null
}

function Get-ManagedProcess {
    param([int]$ProcessId)

    if ($null -eq $ProcessId -or $ProcessId -le 0) {
        return $null
    }

    return (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Read-ServiceMetadata {
    param([Parameter(Mandatory = $true)][string]$PidFile)

    if (-not (Test-Path -Path $PidFile)) {
        return $null
    }

    try {
        return (Get-Content -Path $PidFile -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-ServiceMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][hashtable]$Metadata
    )

    $parent = Split-Path -Path $PidFile -Parent
    if ($parent) {
        Ensure-Directory -Path $parent
    }

    $Metadata | ConvertTo-Json -Depth 4 | Set-Content -Path $PidFile -Encoding UTF8
}

function Remove-ServiceMetadata {
    param([Parameter(Mandatory = $true)][string]$PidFile)

    if (Test-Path -Path $PidFile) {
        Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ServiceStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$PidFile
    )

    $metadata = Read-ServiceMetadata -PidFile $PidFile
    $trackedPid = $null
    if ($null -ne $metadata -and $metadata.pid) {
        $trackedPid = [int]$metadata.pid
    }

    $trackedProcess = Get-ManagedProcess -ProcessId $trackedPid
    if ($null -eq $trackedProcess -and $trackedPid) {
        Remove-ServiceMetadata -PidFile $PidFile
        $metadata = $null
        $trackedPid = $null
    }

    $portOwnerId = Get-ListeningProcessId -Port $Port
    $portOwnerProcess = Get-ManagedProcess -ProcessId $portOwnerId

    return [PSCustomObject]@{
        Name             = $Name
        DisplayName      = $DisplayName
        Port             = $Port
        PidFile          = $PidFile
        Metadata         = $metadata
        TrackedProcessId = $trackedPid
        TrackedProcess   = $trackedProcess
        PortOwnerId      = $portOwnerId
        PortOwnerProcess = $portOwnerProcess
        IsRunning        = ($null -ne $portOwnerId)
    }
}

function Get-LogTail {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return ""
    }

    try {
        return ((Get-Content -Path $Path -Tail 20) -join [Environment]::NewLine)
    }
    catch {
        return ""
    }
}

function Wait-ForPortState {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][bool]$ShouldBeListening,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $listenerPid = Get-ListeningProcessId -Port $Port
        if ($ShouldBeListening -and $listenerPid) {
            return $listenerPid
        }
        if (-not $ShouldBeListening -and -not $listenerPid) {
            return $null
        }
        Start-Sleep -Milliseconds 200
    }

    return (Get-ListeningProcessId -Port $Port)
}

function Start-ManagedService {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$ServerScript,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][string]$StdOutLog,
        [Parameter(Mandatory = $true)][string]$StdErrLog,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [switch]$Force
    )

    if (-not (Test-Path -Path $ServerScript)) {
        throw "$DisplayName backend script not found: $ServerScript"
    }

    $status = Get-ServiceStatus -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile
    if ($status.IsRunning -and -not $Force) {
        $isManagedInstance = $status.Metadata -and $status.Metadata.scriptPath -and ([string]$status.Metadata.scriptPath -eq $ServerScript) -and $status.TrackedProcessId -and ($status.PortOwnerId -eq $status.TrackedProcessId)
        if ($isManagedInstance) {
            Write-Host "$DisplayName is already running on port $Port (PID $($status.PortOwnerId))."
            return $status
        }

        throw "$DisplayName could not start because port $Port is already in use by PID $($status.PortOwnerId). Stop that process or run the stop script first."
    }

    if ($Force) {
        Stop-ManagedService -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile -Quiet
    }
    elseif ($status.TrackedProcessId -and -not $status.IsRunning) {
        Remove-ServiceMetadata -PidFile $PidFile
    }

    $stdoutParent = Split-Path -Path $StdOutLog -Parent
    $stderrParent = Split-Path -Path $StdErrLog -Parent
    if ($stdoutParent) { Ensure-Directory -Path $stdoutParent }
    if ($stderrParent) { Ensure-Directory -Path $stderrParent }

    if (Test-Path -Path $StdOutLog) {
        Remove-Item -Path $StdOutLog -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -Path $StdErrLog) {
        Remove-Item -Path $StdErrLog -Force -ErrorAction SilentlyContinue
    }

    $powerShellExecutable = Get-PowerShellExecutable
    if (Test-IsWindowsHost) {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ServerScript)
        $startProcessParams = @{
            FilePath               = $powerShellExecutable
            ArgumentList           = $arguments
            WorkingDirectory       = $WorkingDirectory
            RedirectStandardOutput = $StdOutLog
            RedirectStandardError  = $StdErrLog
            PassThru               = $true
            WindowStyle            = "Hidden"
        }

        $process = Start-Process @startProcessParams
        $requestedProcessId = [int]$process.Id
    }
    else {
        $nohup = Get-Command -Name "nohup" -ErrorAction SilentlyContinue
        if ($null -eq $nohup) {
            throw "Managed background start requires 'nohup' on non-Windows hosts."
        }

        $nohupArguments = @($powerShellExecutable, "-NoProfile", "-File", $ServerScript)
        $startProcessParams = @{
            FilePath               = $nohup.Source
            ArgumentList           = $nohupArguments
            WorkingDirectory       = $WorkingDirectory
            RedirectStandardOutput = $StdOutLog
            RedirectStandardError  = $StdErrLog
            PassThru               = $true
        }
        $process = Start-Process @startProcessParams
        $requestedProcessId = [int]$process.Id
    }

    $listenerPid = Wait-ForPortState -Port $Port -ShouldBeListening $true -TimeoutSeconds 10
    if (-not $listenerPid) {
        if ($requestedProcessId) {
            try {
                Stop-Process -Id $requestedProcessId -Force -ErrorAction SilentlyContinue
            }
            catch { }
        }

        $stderrTail = Get-LogTail -Path $StdErrLog
        $stdoutTail = Get-LogTail -Path $StdOutLog
        $details = @()
        if ($stderrTail) { $details += "stderr:`n$stderrTail" }
        if ($stdoutTail) { $details += "stdout:`n$stdoutTail" }
        $detailText = if ($details.Count -gt 0) { " `n`n" + ($details -join "`n`n") } else { "" }
        throw "Failed to start $DisplayName on port $Port.$detailText"
    }

    $metadata = @{
        name              = $Name
        displayName       = $DisplayName
        pid               = [int]$listenerPid
        requestedProcessId = $requestedProcessId
        port              = $Port
        scriptPath        = $ServerScript
        stdoutLog         = $StdOutLog
        stderrLog         = $StdErrLog
        startedAtUtc      = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-ServiceMetadata -PidFile $PidFile -Metadata $metadata

    Write-Host "Started $DisplayName on port $Port (PID $listenerPid)."
    Write-Host "Logs:"
    Write-Host "  stdout: $StdOutLog"
    Write-Host "  stderr: $StdErrLog"

    return (Get-ServiceStatus -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile)
}

function Stop-ManagedService {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$PidFile,
        [switch]$Quiet
    )

    $status = Get-ServiceStatus -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile
    $processIds = @()
    if ($status.TrackedProcessId) {
        $processIds += [int]$status.TrackedProcessId
    }
    if ($status.PortOwnerId -and ($processIds -notcontains [int]$status.PortOwnerId)) {
        $processIds += [int]$status.PortOwnerId
    }

    if ($processIds.Count -eq 0) {
        Remove-ServiceMetadata -PidFile $PidFile
        if (-not $Quiet) {
            Write-Host "$DisplayName is not running."
        }
        return $false
    }

    foreach ($processId in $processIds) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    $remainingPortOwner = Wait-ForPortState -Port $Port -ShouldBeListening $false -TimeoutSeconds 10
    Remove-ServiceMetadata -PidFile $PidFile

    if ($remainingPortOwner) {
        throw "Failed to stop $DisplayName cleanly. Port $Port is still in use by PID $remainingPortOwner."
    }

    if (-not $Quiet) {
        Write-Host "Stopped $DisplayName."
    }
    return $true
}

function Show-ServiceStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$PidFile
    )

    $status = Get-ServiceStatus -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile
    if ($status.IsRunning) {
        Write-Host ("{0}: RUNNING (PID {1}, port {2})" -f $DisplayName, $status.PortOwnerId, $Port)
    }
    else {
        Write-Host ("{0}: STOPPED" -f $DisplayName)
    }

    if ($status.Metadata -and $status.Metadata.stdoutLog) {
        Write-Host ("  stdout: {0}" -f [string]$status.Metadata.stdoutLog)
    }
    if ($status.Metadata -and $status.Metadata.stderrLog) {
        Write-Host ("  stderr: {0}" -f [string]$status.Metadata.stderrLog)
    }

    return $status
}
