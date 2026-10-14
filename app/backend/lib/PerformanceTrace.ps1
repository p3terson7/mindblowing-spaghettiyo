# Opt-in diagnostic instrumentation. Never logs arguments, contents, credentials
# or resource paths. The current HttpListener has one request execution lane;
# these script-scoped spans must not be shared by future concurrent runspaces.
$script:SaphirPerformanceEnabled = [string]$env:SAPHIR_PERF_TRACE -eq "1"
$script:SaphirPerformanceRecord = $null
$script:SaphirPerformanceOriginals = @{}

function Start-SaphirPerformanceTrace {
    param([string]$Name)
    if (-not $script:SaphirPerformanceEnabled) { return }
    $safeName = $Name -replace '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}', '{id}' -replace '\d{6,}', '{id}'
    $script:SaphirPerformanceRecord = @{
        name = $safeName; id = [Guid]::NewGuid().ToString("N")
        start = [System.Diagnostics.Stopwatch]::GetTimestamp()
        functions = @{}; operations = @{}; resources = @{}; stack = (New-Object System.Collections.ArrayList)
        memoryStart = Get-SaphirPerformanceMemory
    }
}

function Get-SaphirPerformanceMemory {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $process.Refresh()
        return @{ workingSetBytes = $process.WorkingSet64; privateBytes = $process.PrivateMemorySize64; managedBytes = [GC]::GetTotalMemory($false) }
    } finally { $process.Dispose() }
}

function Start-SaphirPerformanceSpan {
    param([string]$Name)
    if ($null -eq $script:SaphirPerformanceRecord) { return $null }
    $frame = @{ name = $Name; start = [System.Diagnostics.Stopwatch]::GetTimestamp(); childTicks = [long]0 }
    [void]$script:SaphirPerformanceRecord.stack.Add($frame)
    return $frame
}

function Stop-SaphirPerformanceSpan {
    param($Frame)
    if ($null -eq $Frame -or $null -eq $script:SaphirPerformanceRecord) { return }
    $elapsed = [System.Diagnostics.Stopwatch]::GetTimestamp() - [long]$Frame.start
    $record = $script:SaphirPerformanceRecord
    $record.stack.RemoveAt($record.stack.Count - 1)
    if ($record.stack.Count -gt 0) { $record.stack[$record.stack.Count - 1].childTicks += $elapsed }
    if (-not $record.functions.ContainsKey($Frame.name)) {
        $record.functions[$Frame.name] = @{ count = 0; ticks = [long]0; selfTicks = [long]0 }
    }
    $metric = $record.functions[$Frame.name]
    $metric.count++
    $metric.ticks += $elapsed
    $metric.selfTicks += [Math]::Max([long]0, [long]($elapsed - [long]$Frame.childTicks))
}

function Add-SaphirPerformanceOperation {
    param([string]$Kind, [string]$Path = "")
    if ($null -eq $script:SaphirPerformanceRecord) { return }
    $key = $Kind
    if ($Kind.StartsWith("fs.")) {
        $isShared = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$sharedFolder) -and -not [string]::IsNullOrWhiteSpace($Path)) {
            $root = [System.IO.Path]::GetFullPath($sharedFolder).TrimEnd([char[]]@([char]47, [char]92))
            $fullPath = [System.IO.Path]::GetFullPath($Path)
            $isShared = $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
                $fullPath.StartsWith(($root + [System.IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
        }
        $key = $Kind.Replace("fs.", $(if ($isShared) { "fs.shared." } else { "fs.local." }))
    }
    $operations = $script:SaphirPerformanceRecord.operations
    $operations[$key] = [int]$operations[$key] + 1
    if ($Kind.StartsWith("fs.") -and $isShared) {
        # Identify repeated accesses without exposing paths, HRMIS, or names.
        $relative = $fullPath.Substring($root.Length).Replace("\", "/")
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $identity = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($relative))).Replace("-", "").Substring(0, 16) }
        finally { $sha.Dispose() }
        $resources = $script:SaphirPerformanceRecord.resources
        if (-not $resources.ContainsKey($identity)) { $resources[$identity] = @{} }
        $resources[$identity][$Kind] = [int]$resources[$identity][$Kind] + 1
    }
}

function Register-SaphirPerformanceFunctions {
    param([string[]]$Names)
    if (-not $script:SaphirPerformanceEnabled) { return }
    foreach ($name in $Names) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $command) { continue }
        $parameterBlock = $command.ScriptBlock.Ast.ParamBlock
        if ($null -eq $parameterBlock -and $command.ScriptBlock.Ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $parameterBlock = $command.ScriptBlock.Ast.Body.ParamBlock
        }
        if ($command.ScriptBlock.ToString().Contains("SaphirPerformanceOriginals")) { continue }
        $script:SaphirPerformanceOriginals[$name] = $command.ScriptBlock
        $parameters = if ($null -ne $parameterBlock) { $parameterBlock.Extent.Text } else { "param()" }
        $wrapper = @"
$parameters
if (`$null -eq `$script:SaphirPerformanceRecord) { return (& `$script:SaphirPerformanceOriginals['$name'] @PSBoundParameters) }
`$performanceFrame = Start-SaphirPerformanceSpan -Name '$name'
try { & `$script:SaphirPerformanceOriginals['$name'] @PSBoundParameters }
finally { Stop-SaphirPerformanceSpan -Frame `$performanceFrame }
"@
        Set-Item -Path ("Function:script:{0}" -f $name) -Value ([scriptblock]::Create($wrapper))
    }
}

function Stop-SaphirPerformanceTrace {
    param([int]$StatusCode = 0)
    if ($null -eq $script:SaphirPerformanceRecord) { return }
    $record = $script:SaphirPerformanceRecord
    $script:SaphirPerformanceRecord = $null
    $scale = 1000.0 / [System.Diagnostics.Stopwatch]::Frequency
    $functions = @{}
    foreach ($name in $record.functions.Keys) {
        $metric = $record.functions[$name]
        $functions[$name] = @{ count = $metric.count; ms = [Math]::Round(($metric.ticks * $scale), 3); selfMs = [Math]::Round(($metric.selfTicks * $scale), 3) }
    }
    $result = [ordered]@{
        name = $record.name; id = $record.id; status = $StatusCode
        totalMs = [Math]::Round((([System.Diagnostics.Stopwatch]::GetTimestamp() - $record.start) * $scale), 3)
        operations = $record.operations; functions = $functions; resources = $record.resources
        memory = @{ before = $record.memoryStart; after = Get-SaphirPerformanceMemory }
        caches = @{ models = $script:ReadModelCache.Count; dependencies = $script:ReadModelDependencies.Count; employeeFiles = $script:EmployeeEntryFileCache.Count; textFiles = $script:TextFileCache.Count }
    }
    # Logging is local stdout, not another shared-drive write. Durations are
    # inclusive and self-time excludes instrumented children, not all CPU work.
    Write-Host ("SAPHIR_PERF " + (ConvertTo-Json -InputObject $result -Depth 6 -Compress))
}
