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

function ConvertTo-WindowsPowerShellFileArguments {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    if ($ScriptPath.Contains('"')) {
        throw "A PowerShell script path cannot contain a double quote."
    }

    return ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath)
}

function Get-ManagedServiceLaunchPlan {
    param(
        [Parameter(Mandatory = $true)][bool]$IsRunning,
        [Parameter(Mandatory = $true)][bool]$HasTrackedProcess,
        [Parameter(Mandatory = $true)][bool]$IsExpectedManagedInstance,
        [Parameter(Mandatory = $true)][bool]$FrontendIsAvailable,
        [switch]$Force
    )

    if ($IsExpectedManagedInstance -and $FrontendIsAvailable -and -not $Force) {
        return [PSCustomObject]@{
            Action       = "Reuse"
            ForceRestart = $false
        }
    }

    if ($IsRunning -and -not $HasTrackedProcess -and -not $Force) {
        return [PSCustomObject]@{
            Action       = "Block"
            ForceRestart = $false
        }
    }

    $restartTrackedService = $HasTrackedProcess -and (-not $IsExpectedManagedInstance -or -not $FrontendIsAvailable)
    $forceRestart = [bool]($Force -or $restartTrackedService)
    return [PSCustomObject]@{
        Action       = if ($forceRestart) { "Restart" } else { "Start" }
        ForceRestart = $forceRestart
    }
}

function Test-ManagedServiceHealthyForScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$ServerScript,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][string]$FrontendUrl,
        [int]$TimeoutMilliseconds = 1500
    )

    try {
        $status = Get-ServiceStatus -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile
        if (-not $status.IsRunning -or -not $status.TrackedProcessId -or $null -eq $status.Metadata -or
            [string]::IsNullOrWhiteSpace([string]$status.Metadata.scriptPath) -or
            [string]::IsNullOrWhiteSpace([string]$status.Metadata.instanceToken)) {
            return $false
        }

        $expectedScriptPath = [System.IO.Path]::GetFullPath($ServerScript)
        $trackedScriptPath = [System.IO.Path]::GetFullPath([string]$status.Metadata.scriptPath)
        $comparison = if (Test-IsWindowsHost) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not $trackedScriptPath.Equals($expectedScriptPath, $comparison)) {
            return $false
        }

        $request = [System.Net.WebRequest]::Create($FrontendUrl)
        $request.Method = "GET"
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        try {
            $statusCode = [int]$response.StatusCode
            $appIdentity = [string]$response.Headers["X-SAPHIR-App"]
            $responseInstanceToken = [string]$response.Headers["X-SAPHIR-Instance"]
            $expectedInstanceToken = [string]$status.Metadata.instanceToken
            return ($statusCode -ge 200 -and
                $statusCode -lt 400 -and
                $appIdentity -eq "SAPHIR" -and
                $responseInstanceToken.Equals($expectedInstanceToken, [System.StringComparison]::Ordinal))
        }
        finally {
            $response.Close()
        }
    }
    catch {
        return $false
    }
}

function Test-ManagedServiceHttpIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$InstanceToken,
        [int]$TimeoutMilliseconds = 1500
    )

    if ([string]::IsNullOrWhiteSpace($InstanceToken)) {
        return $false
    }

    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $request.Method = "GET"
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $request.AllowAutoRedirect = $false
        $request.Proxy = $null
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        try {
            $statusCode = [int]$response.StatusCode
            $appIdentity = [string]$response.Headers["X-SAPHIR-App"]
            $responseInstanceToken = [string]$response.Headers["X-SAPHIR-Instance"]
            return ($statusCode -ge 200 -and
                $statusCode -lt 400 -and
                $appIdentity -eq "SAPHIR" -and
                $responseInstanceToken.Equals($InstanceToken, [System.StringComparison]::Ordinal))
        }
        finally {
            $response.Close()
        }
    }
    catch {
        return $false
    }
}

function Invoke-ManagedServiceGracefulShutdown {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$InstanceToken,
        [int]$TimeoutMilliseconds = 30000
    )

    if ([string]::IsNullOrWhiteSpace($InstanceToken)) {
        return $false
    }

    # The backend intentionally serializes requests so file mutations cannot
    # overlap. A health request may therefore wait behind a legitimate shared
    # data write. Give that request enough time to finish before the protected
    # force-stop fallback is considered.
    $baseUri = "http://localhost:{0}/" -f $Port
    if (-not (Test-ManagedServiceHttpIdentity `
        -Uri $baseUri `
        -InstanceToken $InstanceToken `
        -TimeoutMilliseconds $TimeoutMilliseconds)) {
        return $false
    }

    try {
        $request = [System.Net.WebRequest]::Create(("{0}__saphir/control/shutdown" -f $baseUri))
        $request.Method = "POST"
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $request.AllowAutoRedirect = $false
        $request.Proxy = $null
        $request.ContentLength = 0
        $request.Headers["X-SAPHIR-Control-Token"] = $InstanceToken
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        try {
            $appIdentity = [string]$response.Headers["X-SAPHIR-App"]
            $responseInstanceToken = [string]$response.Headers["X-SAPHIR-Instance"]
            return ([int]$response.StatusCode -eq 202 -and
                $appIdentity -eq "SAPHIR" -and
                $responseInstanceToken.Equals($InstanceToken, [System.StringComparison]::Ordinal))
        }
        finally {
            $response.Close()
        }
    }
    catch {
        return $false
    }
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
        $getNetTcpConnection = Get-Command -Name "Get-NetTCPConnection" -ErrorAction SilentlyContinue
        if ($null -ne $getNetTcpConnection) {
            $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $connection) {
                return [int]$connection.OwningProcess
            }
        }

        $netstat = Get-Command -Name "netstat.exe" -ErrorAction SilentlyContinue
        if ($null -ne $netstat) {
            $lines = & $netstat.Source -ano -p tcp 2>$null
            foreach ($line in $lines) {
                $trimmed = ([string]$line).Trim()
                if ($trimmed -notmatch "^TCP\s+") {
                    continue
                }

                $parts = $trimmed -split "\s+"
                if ($parts.Count -lt 5) {
                    continue
                }

                $localAddress = [string]$parts[1]
                $state = [string]$parts[3]
                $pidText = [string]$parts[4]
                $portPattern = "(:|\.)" + [regex]::Escape([string]$Port) + "$"
                if ($localAddress -match $portPattern -and $pidText -match "^\d+$" -and $state -match "LISTEN|ECOUTE|ÉCOUTE") {
                    return [int]$pidText
                }
            }
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

function Test-IsManagedPowerShellProcess {
    param($Process)

    if ($null -eq $Process) {
        return $false
    }

    $processName = ([string]$Process.ProcessName).ToLowerInvariant()
    return ($processName -eq "powershell" -or $processName -eq "pwsh")
}

function Get-ProcessCommandLine {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if ($ProcessId -le 0) {
        return ""
    }

    if (Test-IsWindowsHost) {
        $filter = "ProcessId = $ProcessId"
        $getCimInstance = Get-Command -Name "Get-CimInstance" -ErrorAction SilentlyContinue
        if ($null -ne $getCimInstance) {
            try {
                $processRecord = Get-CimInstance -ClassName "Win32_Process" -Filter $filter -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $processRecord) {
                    return [string]$processRecord.CommandLine
                }
            }
            catch { }
        }

        $getWmiObject = Get-Command -Name "Get-WmiObject" -ErrorAction SilentlyContinue
        if ($null -ne $getWmiObject) {
            try {
                $processRecord = Get-WmiObject -Class "Win32_Process" -Filter $filter -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $processRecord) {
                    return [string]$processRecord.CommandLine
                }
            }
            catch { }
        }

        return ""
    }

    $psCommand = Get-Command -Name "ps" -ErrorAction SilentlyContinue
    if ($null -eq $psCommand) {
        return ""
    }

    try {
        $commandLine = @(& $psCommand.Source -ww -p $ProcessId -o "command=" 2>$null)
        return (($commandLine | ForEach-Object { [string]$_ }) -join " ").Trim()
    }
    catch {
        return ""
    }
}

function Get-RunningPowerShellProcesses {
    $processes = @()
    foreach ($processName in @("pwsh", "powershell")) {
        try {
            $processes += @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        }
        catch { }
    }

    return @($processes)
}

function Test-ProcessRunsPowerShellFile {
    param(
        $Process,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$CommandLine
    )

    if (-not (Test-IsManagedPowerShellProcess -Process $Process)) {
        return $false
    }

    try {
        $expectedScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    }
    catch {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        $CommandLine = Get-ProcessCommandLine -ProcessId ([int]$Process.Id)
    }
    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    $escapedScriptPath = [regex]::Escape($expectedScriptPath)
    $regexOptions = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if (Test-IsWindowsHost) {
        $regexOptions = $regexOptions -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }

    # Match only the value of PowerShell's -File parameter. Merely mentioning the
    # path elsewhere in a command line must never authorize terminating a process.
    $fileArgumentPattern = '(^|\s)-[Ff][Ii][Ll][Ee](\s+|:)("' + $escapedScriptPath + '"|''' + $escapedScriptPath + '''|' + $escapedScriptPath + ')($|\s)'
    return [regex]::IsMatch($CommandLine, $fileArgumentPattern, $regexOptions)
}

function Find-ServiceProcessesByScriptPath {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $matches = @()
    foreach ($candidate in @(Get-RunningPowerShellProcesses)) {
        if (Test-ProcessRunsPowerShellFile -Process $candidate -ScriptPath $ScriptPath) {
            $matches += $candidate
        }
    }

    return @($matches)
}

function Test-ServiceProcessMatchesMetadata {
    param(
        $Process,
        $Metadata
    )

    if (-not (Test-IsManagedPowerShellProcess -Process $Process) -or $null -eq $Metadata) {
        return $false
    }

    $recordedStartValue = if ($Metadata.processStartedAtUtc) { $Metadata.processStartedAtUtc } else { $Metadata.startedAtUtc }
    if ($null -ne $recordedStartValue -and -not [string]::IsNullOrWhiteSpace([string]$recordedStartValue)) {
        try {
            # PowerShell 7's ConvertFrom-Json turns ISO timestamps into DateTime
            # values. Casting that DateTime back to text drops its UTC kind and
            # can apply the local offset twice, making valid PID metadata look
            # stale. Preserve DateTime values directly; parse only legacy text.
            $recordedStart = if ($recordedStartValue -is [DateTime]) {
                ([DateTime]$recordedStartValue).ToUniversalTime()
            }
            else {
                [DateTime]::Parse(
                    [string]$recordedStartValue,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind
                ).ToUniversalTime()
            }
            $actualStart = $Process.StartTime.ToUniversalTime()
            $allowedDifferenceSeconds = if ($Metadata.processStartedAtUtc) { 5 } else { 120 }
            if ([math]::Abs(($actualStart - $recordedStart).TotalSeconds) -gt $allowedDifferenceSeconds) {
                return $false
            }
        }
        catch {
            return $false
        }
    }

    return -not [string]::IsNullOrWhiteSpace([string]$Metadata.scriptPath)
}

function Read-ServiceMetadata {
    param([Parameter(Mandatory = $true)][string]$PidFile)

    if (-not (Test-Path -Path $PidFile)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
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

    $temporaryPath = "$PidFile.tmp.$([Guid]::NewGuid().ToString('N'))"
    $json = ConvertTo-Json -InputObject $Metadata -Depth 4
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8NoBom)
        Move-Item -LiteralPath $temporaryPath -Destination $PidFile -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
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
    if ($null -ne $trackedProcess -and -not (Test-ServiceProcessMatchesMetadata -Process $trackedProcess -Metadata $metadata)) {
        $trackedProcess = $null
    }
    if ($null -eq $trackedProcess -and $trackedPid) {
        Remove-ServiceMetadata -PidFile $PidFile
        $metadata = $null
        $trackedPid = $null
    }

    $portOwnerId = Get-ListeningProcessId -Port $Port
    $portOwnerProcess = Get-ManagedProcess -ProcessId $portOwnerId

    $displayProcessId = if ($trackedPid) { $trackedPid } else { $portOwnerId }

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
        DisplayProcessId = $displayProcessId
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

function Get-StartupTimeoutSeconds {
    $timeoutSeconds = 45
    $configuredTimeout = [string]$env:SAPHIR_STARTUP_TIMEOUT_SECONDS
    if ([string]::IsNullOrWhiteSpace($configuredTimeout)) {
        $configuredTimeout = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_STARTUP_TIMEOUT_SECONDS"))
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredTimeout)) {
        [int]::TryParse($configuredTimeout, [ref]$timeoutSeconds) | Out-Null
    }

    if ($timeoutSeconds -lt 10) {
        return 10
    }

    return $timeoutSeconds
}

function Wait-ForProcessesToExit {
    param(
        [Parameter(Mandatory = $true)][int[]]$ProcessIds,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $activeProcesses = @($ProcessIds | Where-Object {
            $candidate = [int]$_
            $candidate -gt 0 -and $null -ne (Get-ManagedProcess -ProcessId $candidate)
        })

        if ($activeProcesses.Count -eq 0) {
            return $true
        }

        Start-Sleep -Milliseconds 200
    }

    $remaining = @($ProcessIds | Where-Object {
        $candidate = [int]$_
        $candidate -gt 0 -and $null -ne (Get-ManagedProcess -ProcessId $candidate)
    })

    return ($remaining.Count -eq 0)
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
        $isManagedInstance = $status.Metadata -and $status.Metadata.scriptPath -and ([string]$status.Metadata.scriptPath -eq $ServerScript) -and $status.TrackedProcessId
        if ($isManagedInstance) {
            Write-Host "$DisplayName is already running on port $Port (PID $($status.DisplayProcessId))."
            return $status
        }

        if (Test-IsWindowsHost -and [int]$status.PortOwnerId -eq 4 -and -not $status.TrackedProcessId) {
            Write-Host "$DisplayName appears to be behind HTTP.sys on port $Port. Attempting a managed restart."
            Remove-ServiceMetadata -PidFile $PidFile
        }
        else {
        throw "$DisplayName could not start because port $Port is already in use by PID $($status.PortOwnerId). Stop that process or run the stop script first."
        }
    }

    if ($Force) {
        Stop-ManagedService -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile -ServerScript $ServerScript -Quiet
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
    $instanceToken = [Guid]::NewGuid().ToString("N")
    $previousInstanceToken = [System.Environment]::GetEnvironmentVariable("SAPHIR_INSTANCE_TOKEN", [System.EnvironmentVariableTarget]::Process)
    try {
        [System.Environment]::SetEnvironmentVariable("SAPHIR_INSTANCE_TOKEN", $instanceToken, [System.EnvironmentVariableTarget]::Process)
        if (Test-IsWindowsHost) {
            $arguments = ConvertTo-WindowsPowerShellFileArguments -ScriptPath $ServerScript
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
            $nohupCommand = Get-Command -Name "nohup" -ErrorAction SilentlyContinue
            $launcherPrefix = if ($null -ne $nohupCommand) { (ConvertTo-ShellSingleQuotedLiteral -Value ([string]$nohupCommand.Source)) + " " } else { "" }
            $shellCommand = "cd {0}; {1}{2} -NoProfile -File {3} > {4} 2> {5} < /dev/null &" -f `
                (ConvertTo-ShellSingleQuotedLiteral -Value $WorkingDirectory),
                $launcherPrefix,
                (ConvertTo-ShellSingleQuotedLiteral -Value $powerShellExecutable),
                (ConvertTo-ShellSingleQuotedLiteral -Value $ServerScript),
                (ConvertTo-ShellSingleQuotedLiteral -Value $StdOutLog),
                (ConvertTo-ShellSingleQuotedLiteral -Value $StdErrLog)
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "/bin/sh"
            $processStartInfo.WorkingDirectory = $WorkingDirectory
            $processStartInfo.UseShellExecute = $false
            [void]$processStartInfo.ArgumentList.Add("-c")
            [void]$processStartInfo.ArgumentList.Add($shellCommand)
            $process = [System.Diagnostics.Process]::Start($processStartInfo)
            $requestedProcessId = [int]$process.Id
        }
    }
    finally {
        [System.Environment]::SetEnvironmentVariable("SAPHIR_INSTANCE_TOKEN", $previousInstanceToken, [System.EnvironmentVariableTarget]::Process)
    }

    $startupTimeoutSeconds = Get-StartupTimeoutSeconds
    $listenerPid = Wait-ForPortState -Port $Port -ShouldBeListening $true -TimeoutSeconds $startupTimeoutSeconds
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
        $details += "Startup timeout: $startupTimeoutSeconds second(s)."
        $details += "Logs: $StdOutLog and $StdErrLog"
        if ($stderrTail) { $details += "stderr:`n$stderrTail" }
        if ($stdoutTail) { $details += "stdout:`n$stdoutTail" }
        $detailText = if ($details.Count -gt 0) { " `n`n" + ($details -join "`n`n") } else { "" }
        throw "Failed to start $DisplayName on port $Port.$detailText"
    }

    $managedProcessId = if (Test-IsWindowsHost) { [int]$requestedProcessId } else { [int]$listenerPid }
    $managedProcess = Get-ManagedProcess -ProcessId $managedProcessId
    $processStartedAtUtc = if ($null -ne $managedProcess) {
        try { $managedProcess.StartTime.ToUniversalTime().ToString("o") } catch { "" }
    }
    else {
        ""
    }
    $metadata = @{
        name              = $Name
        displayName       = $DisplayName
        pid               = $managedProcessId
        requestedProcessId = $requestedProcessId
        port              = $Port
        scriptPath        = $ServerScript
        stdoutLog         = $StdOutLog
        stderrLog         = $StdErrLog
        startedAtUtc      = (Get-Date).ToUniversalTime().ToString("o")
        processStartedAtUtc = $processStartedAtUtc
        instanceToken     = $instanceToken
    }
    Write-ServiceMetadata -PidFile $PidFile -Metadata $metadata

    Write-Host "Started $DisplayName on port $Port (PID $managedProcessId)."
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
        [string]$ServerScript,
        [switch]$Quiet
    )

    $status = Get-ServiceStatus -Name $Name -DisplayName $DisplayName -Port $Port -PidFile $PidFile
    $processIds = @()
    if ($status.TrackedProcessId) {
        $processIds += [int]$status.TrackedProcessId
    }
    if ($status.Metadata -and $status.Metadata.requestedProcessId) {
        $requestedProcessId = [int]$status.Metadata.requestedProcessId
        $requestedProcess = Get-ManagedProcess -ProcessId $requestedProcessId
        if ($processIds -notcontains $requestedProcessId -and (Test-IsManagedPowerShellProcess -Process $requestedProcess)) {
            $processIds += $requestedProcessId
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ServerScript)) {
        foreach ($matchingProcess in @(Find-ServiceProcessesByScriptPath -ScriptPath $ServerScript)) {
            $matchingProcessId = [int]$matchingProcess.Id
            if ($matchingProcessId -gt 0 -and $processIds -notcontains $matchingProcessId) {
                $processIds += $matchingProcessId
            }
        }
    }

    if ($processIds.Count -eq 0) {
        if ($status.IsRunning) {
            throw "$DisplayName was not stopped because port $Port belongs to an untracked process (PID $($status.PortOwnerId))."
        }

        Remove-ServiceMetadata -PidFile $PidFile
        if (-not $Quiet) {
            Write-Host "$DisplayName is not running."
        }
        return $false
    }

    $managedProcessIds = @($processIds | Where-Object { [int]$_ -gt 0 -and [int]$_ -ne 4 })
    $instanceToken = if ($status.Metadata -and $status.Metadata.instanceToken) {
        [string]$status.Metadata.instanceToken
    }
    else {
        ""
    }
    $canRequestGracefulShutdown = $status.IsRunning -and
        $status.TrackedProcessId -and
        ($processIds -contains [int]$status.TrackedProcessId) -and
        -not [string]::IsNullOrWhiteSpace($instanceToken)

    if ($canRequestGracefulShutdown -and
        (Invoke-ManagedServiceGracefulShutdown -Port $Port -InstanceToken $instanceToken)) {
        $gracefulProcessesStopped = $true
        if ($managedProcessIds.Count -gt 0) {
            $gracefulProcessesStopped = Wait-ForProcessesToExit -ProcessIds $managedProcessIds -TimeoutSeconds 5
        }

        $gracefulPortOwner = Wait-ForPortState -Port $Port -ShouldBeListening $false -TimeoutSeconds 5
        $gracefulPortStopped = -not $gracefulPortOwner -or
            (Test-IsWindowsHost -and [int]$gracefulPortOwner -eq 4)

        if ($gracefulProcessesStopped -and $gracefulPortStopped) {
            Remove-ServiceMetadata -PidFile $PidFile
            if (-not $Quiet) {
                Write-Host "Stopped $DisplayName."
            }
            return $true
        }
    }

    foreach ($processId in $processIds) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        catch { }
    }

    $managedProcessesStopped = $true
    if ($managedProcessIds.Count -gt 0) {
        $managedProcessesStopped = Wait-ForProcessesToExit -ProcessIds $managedProcessIds -TimeoutSeconds 10
    }

    $remainingPortOwner = Wait-ForPortState -Port $Port -ShouldBeListening $false -TimeoutSeconds 10
    Remove-ServiceMetadata -PidFile $PidFile

    if (-not $managedProcessesStopped) {
        throw "Failed to stop $DisplayName cleanly. A managed backend process is still running."
    }

    if ($remainingPortOwner -and -not (Test-IsWindowsHost -and [int]$remainingPortOwner -eq 4)) {
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
        Write-Host ("{0}: RUNNING (PID {1}, port {2})" -f $DisplayName, $status.DisplayProcessId, $Port)
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
