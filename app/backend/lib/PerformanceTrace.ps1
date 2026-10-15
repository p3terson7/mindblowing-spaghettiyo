# Opt-in diagnostics, extending the original SAPHIR_PERF summary contract.
# Each runspace owns its record/stack; only a bounded, thread-safe queue is
# shared with a single local writer. Never log arguments or exception messages.
$script:SaphirPerformanceEnabled = [string]$env:SAPHIR_PERFORMANCE_TRACE -eq "1" -or [string]$env:SAPHIR_PERF_TRACE -eq "1"
$script:SaphirPerformanceLevel = if ([string]$env:SAPHIR_TRACE_LEVEL -eq "detailed") { "detailed" } else { "summary" }
$script:SaphirPerformanceRecord = $null
$script:SaphirPerformanceOriginals = @{}
if ($script:SaphirPerformanceWriter) { try { $script:SaphirPerformanceWriter.Dispose() } catch { } }
$script:SaphirPerformanceWriter = $null
$script:SaphirPerformanceWriterAttempted = $false
$script:SaphirPerformanceWriterFailed = $false

function Get-SaphirPerformanceSetting {
    param([string]$Name, [int]$Default, [int]$Minimum, [int]$Maximum)
    $value = 0
    if ([int]::TryParse([Environment]::GetEnvironmentVariable($Name), [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) { return $value }
    return $Default
}

function Initialize-SaphirPerformanceWriter {
    if (-not $script:SaphirPerformanceEnabled -or $script:SaphirPerformanceWriterAttempted) { return }
    $script:SaphirPerformanceWriterAttempted = $true
    $initializationStep = "validate-local-directory"
    try {
        $localRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localRoot)) { throw "Local diagnostics root unavailable." }
        $directory = if ([string]::IsNullOrWhiteSpace([string]$env:SAPHIR_TRACE_DIR)) {
            Join-Path $localRoot "SAPHIR/diagnostics/performance"
        } else { [string]$env:SAPHIR_TRACE_DIR }
        $directory = [IO.Path]::GetFullPath($directory)
        $allowed = $false
        foreach ($base in @($localRoot, [IO.Path]::GetTempPath())) {
            $boundary = [IO.Path]::GetFullPath($base).TrimEnd([char[]]@([char]47, [char]92)) + [IO.Path]::DirectorySeparatorChar
            if ($directory.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
        }
        if (-not $allowed -or $directory.StartsWith("\\") -or $directory.StartsWith("/Volumes/")) { throw "Diagnostics must use local application data or local temporary storage." }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($directory))
            if ($drive.DriveType -ne [IO.DriveType]::Fixed -and $drive.DriveType -ne [IO.DriveType]::Ram) { throw "Diagnostic drive is not local." }
        }
        # Reject junctions/symlinks before creating anything. A redirected
        # LOCALAPPDATA/TEMP is not permission to write diagnostics onto SMB.
        $ancestor = $directory
        while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
            if ([IO.Directory]::Exists($ancestor) -and ([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint)) { throw "Diagnostic directory contains a redirected component." }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        if ($null -eq ("Saphir.Diagnostics.TraceWriter" -as [type])) {
            $initializationStep = "compile-writer"
            Add-Type -Path (Join-Path $PSScriptRoot "PerformanceTraceWriter.cs") -ErrorAction Stop
        }
        $initializationStep = "create-local-directory"
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $initializationStep = "set-local-permissions"
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @($identity, (New-Object Security.Principal.SecurityIdentifier("S-1-5-18")))) {
                $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $directory -AclObject $acl -ErrorAction Stop
        }
        $maxMb = Get-SaphirPerformanceSetting "SAPHIR_TRACE_MAX_MB" 16 1 128
        $files = Get-SaphirPerformanceSetting "SAPHIR_TRACE_MAX_FILES" 8 1 32
        $days = Get-SaphirPerformanceSetting "SAPHIR_TRACE_RETENTION_DAYS" 7 1 90
        $initializationStep = "start-writer"
        $script:SaphirPerformanceWriter = New-Object Saphir.Diagnostics.TraceWriter($directory, ([long]$maxMb * 1048576), $files, $days, 4096, 250)
        $script:SaphirPerformanceDirectory = $directory
    } catch {
        $script:SaphirPerformanceWriterFailed = $true
        # Include safe failure identifiers, never arbitrary exception messages,
        # paths, compiler source, arguments or business content.
        $failureType = [string]$_.CategoryInfo.Reason
        $failureCode = [string]$_.FullyQualifiedErrorId -replace '[^A-Za-z0-9._,-]', ''
        if ($failureCode.Length -gt 160) { $failureCode = $failureCode.Substring(0, 160) }
        Write-Warning ("SAPHIR local performance diagnostics could not be initialized (step={0}; type={1}; code={2}; language={3}); normal application behavior is unchanged." -f $initializationStep, $failureType, $failureCode, $ExecutionContext.SessionState.LanguageMode)
    }
}

function Write-SaphirPerformanceEvent {
    param([string]$Event, $Frame, $Fields)
    $record = $script:SaphirPerformanceRecord
    if ($null -eq $record) { return }
    # Keep the useful stdout aggregates, but do not serialize unsavable events
    # after initialization fails (or after its bounded startup buffer is full).
    if (-not $record.sink -and ($script:SaphirPerformanceWriterFailed -or $null -eq $record.pending -or $record.pending.Count -ge 64)) { return }
    try {
        $ticks = [Diagnostics.Stopwatch]::GetTimestamp()
        $item = [ordered]@{
            schemaVersion = 2; event = $Event; traceId = $record.id
            spanId = if ($Frame) { $Frame.id } else { $record.rootSpanId }
            parentSpanId = if ($Frame) { $Frame.parentId } else { $record.parentSpanId }
            operation = if ($Frame) { $Frame.name } else { $record.name }
            component = if ($Frame) { $Frame.component } else { "Lifecycle" }
            operationType = if ($Frame) { $Frame.type } else { "workflow" }
            timestampUtc = if ($Event -eq "span_start" -and $Frame.startUtc) { $Frame.startUtc } else { [DateTime]::UtcNow.ToString("o") }
            offsetMs = [Math]::Round((($(if ($Event -eq "span_start" -and $Frame.start) { [long]$Frame.start } else { $ticks }) - [long]$record.start) * 1000.0 / [Diagnostics.Stopwatch]::Frequency), 4)
            processId = $PID; threadId = [Threading.Thread]::CurrentThread.ManagedThreadId
            runspaceId = if ([Management.Automation.Runspaces.Runspace]::DefaultRunspace) { [Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString("N") } else { $null }
            level = $record.level
        }
        if ($Event -eq "span_start") { $item.status = "incomplete" }
        # A strict allowlist: never accept arbitrary caller dictionaries/strings.
        if ($Fields) {
            foreach ($key in @("durationMs", "startOffsetMs", "endOffsetMs", "cacheSize", "affectedModels", "retryCount", "fileSizeBytes", "workerIndex", "workerLimit", "queueDepth", "workerCount", "waitMs", "scheduledOffsetMs", "writerDropped", "writerFailures", "eventCount", "writerMs")) {
                if ($Fields.ContainsKey($key)) { $item[$key] = [double]$Fields[$key] }
            }
            foreach ($key in @("servedFromCache", "filesystemAccess", "sharedResource")) { if ($Fields.ContainsKey($key)) { $item[$key] = [bool]$Fields[$key] } }
            foreach ($key in @("status", "cache", "reason", "resourceId", "resourceCategory", "modelCategory", "modelId", "errorCategory")) {
                if ($Fields.ContainsKey($key) -and [string]$Fields[$key] -match '^[A-Za-z][A-Za-z0-9._-]{0,100}$|^[0-9a-f]{32}$') { $item[$key] = [string]$Fields[$key] }
            }
        }
        $line = ConvertTo-Json -InputObject $item -Depth 4 -Compress
        if ($record.sink) { $record.sink.Enqueue($line) }
        elseif ($null -ne $record.pending -and $record.pending.Count -lt 64) { [void]$record.pending.Add($line) }
    } catch { $record.eventFailures++ }
}

function Get-SaphirPerformanceModelId {
    param([string]$Key)
    $record = $script:SaphirPerformanceRecord
    if (-not $record -or $record.level -ne "detailed") { return "" }
    if ($record.modelIds.ContainsKey($Key)) { return $record.modelIds[$Key] }
    try {
        $hmac = New-Object Security.Cryptography.HMACSHA256(,$record.resourceKey)
        try { $identity = [BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("model:" + $Key))).Replace("-", "").Substring(0,32).ToLowerInvariant() }
        finally { $hmac.Dispose() }
        if ($record.modelIds.Count -lt 8192) { $record.modelIds[$Key] = $identity }
        return $identity
    } catch { return "" }
}

function Get-SaphirPerformanceResource {
    param([string]$Path)
    $record = $script:SaphirPerformanceRecord
    if (-not $record -or [string]::IsNullOrWhiteSpace($Path)) { return @{} }
    if ($record.resourceIds.ContainsKey($Path)) { return $record.resourceIds[$Path] }
    $shared = $false
    try {
        $full = [IO.Path]::GetFullPath($Path)
        if (-not [string]::IsNullOrWhiteSpace([string]$sharedFolder)) {
            $root = [IO.Path]::GetFullPath($sharedFolder).TrimEnd([char[]]@([char]47, [char]92))
            $shared = $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith(($root + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
        }
        $hmac = New-Object Security.Cryptography.HMACSHA256(,$record.resourceKey)
        try { $id = [BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant()))).Replace("-", "").Substring(0,32).ToLowerInvariant() }
        finally { $hmac.Dispose() }
        $file = [IO.Path]::GetFileName($full)
        $category = switch -Regex ($file) {
            '^\d+_data\.json' { "employee"; break }
            '^users\.json$' { "users"; break }
            '^sessions\.json$' { "sessions"; break }
            '^sync-state\.json$' { "sync"; break }
            '^projects\.json$' { "projects"; break }
            '^employeeNames\.json$' { "directory"; break }
            '^history\.json$' { "history"; break }
            '^compensation-grid\.json$' { "compensation"; break }
            '^.*\.lock$' { "lock"; break }
            default { "other" }
        }
        $value = @{ resourceId = $id; resourceCategory = $category; sharedResource = $shared }
        if ($record.resourceIds.Count -lt 8192) { $record.resourceIds[$Path] = $value }
        return $value
    } catch { return @{} }
}

function Get-SaphirPerformanceWorkerContext {
    param($Parent, [int]$Index, [string]$Path)
    if (-not $script:SaphirPerformanceRecord) { return $null }
    $record = $script:SaphirPerformanceRecord
    return [PSCustomObject]@{
        id = $record.id; start = $record.start; parentSpanId = $Parent.id
        level = $record.level; sink = $record.sink; resourceKey = $record.resourceKey
        workerIndex = $Index; scheduledOffsetMs = ([Diagnostics.Stopwatch]::GetTimestamp() - [long]$record.start) * 1000.0 / [Diagnostics.Stopwatch]::Frequency
    }
}

function Start-SaphirPerformanceWorker {
    param($Context, [string]$Path, [long]$EntryTicks, [string]$EntryUtc)
    if (-not $Context) { return }
    $script:SaphirPerformanceRecord = New-SaphirPerformanceRecord -Name "EmployeeFile.Worker" -Id $Context.id -Start $Context.start -ParentId $Context.parentSpanId -Key $Context.resourceKey -Sink $Context.sink -Level $Context.level
    $record = $script:SaphirPerformanceRecord
    $fields = Get-SaphirPerformanceResource $Path
    $fields.workerIndex = $Context.workerIndex; $fields.scheduledOffsetMs = $Context.scheduledOffsetMs
    $record.workerRoot = @{ id = $record.rootSpanId; parentId = $Context.parentSpanId; name = "EmployeeFile.Worker"; component = "EmployeeFileReadWorker"; type = "worker"; emit = $true; start = $EntryTicks; startUtc = $EntryUtc; childTicks = [long]0; fields = $fields }
    [void]$record.stack.Add($record.workerRoot)
    Write-SaphirPerformanceEvent "span_start" $record.workerRoot $fields
    Write-SaphirPerformanceEvent "worker_event" $null @{ workerIndex = $Context.workerIndex; scheduledOffsetMs = $Context.scheduledOffsetMs; reason = "started" }
}

function New-SaphirPerformanceRecord {
    param([string]$Name, [string]$Id, [long]$Start, [string]$ParentId = "", [byte[]]$Key, $Sink, [string]$Level)
    return @{
        name = $Name; id = $Id; rootSpanId = [Guid]::NewGuid().ToString("N"); parentSpanId = $ParentId
        start = $Start; level = $Level; sink = $Sink; resourceKey = $Key; resourceIds = @{}; modelIds = @{}; eventFailures = 0
        functions = @{}; operations = @{}; resources = @{}; stack = (New-Object Collections.ArrayList)
        pending = (New-Object Collections.ArrayList)
    }
}

function Start-SaphirPerformanceTrace {
    param([string]$Name)
    if (-not $script:SaphirPerformanceEnabled) { return }
    $safeName = $Name -replace '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}', '{id}' -replace '\d+', '{id}'
    if ($Name -match '^(GET|POST|PUT|DELETE|OPTIONS|HEAD)\s+(/[^?]*)') {
        $method = $Matches[1]; $route = $Matches[2]
        $staticSegments = @("auth", "login", "me", "logout", "change-password", "dashboard", "bootstrap", "sync", "status", "health", "employees", "employee", "review", "projects", "self", "profile", "scripts", "assets", "add", "approval", "restore", "gc179-profile", "work-schedule", "history", "entries", "budget-periods", "compensation-grid", "bug-reports", "attachments", "__saphir", "control", "shutdown")
        $safeName = $method + " " + ((@($route.Split('/') | ForEach-Object { if (-not $_ -or $staticSegments -contains $_) { $_ } else { "{resource}" } })) -join "/")
    }
    $key = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($key) } finally { $rng.Dispose() }
    $script:SaphirPerformanceRecord = New-SaphirPerformanceRecord $safeName ([Guid]::NewGuid().ToString("N")) ([Diagnostics.Stopwatch]::GetTimestamp()) "" $key $script:SaphirPerformanceWriter $script:SaphirPerformanceLevel
    try { $script:SaphirPerformanceRecord.memoryStart = Get-SaphirPerformanceMemory } catch { $script:SaphirPerformanceRecord.memoryStart = @{} }
    Write-SaphirPerformanceEvent "trace_start" $null @{ status = "incomplete" }
    if (-not $script:SaphirPerformanceWriterAttempted) {
        $init = Start-SaphirPerformanceSpan -Name "Diagnostics.InitializeWriter" -Component "Diagnostics" -Type "infrastructure"
        Initialize-SaphirPerformanceWriter
        $script:SaphirPerformanceRecord.sink = $script:SaphirPerformanceWriter
        if ($script:SaphirPerformanceWriter) { foreach ($line in $script:SaphirPerformanceRecord.pending) { $script:SaphirPerformanceWriter.Enqueue($line) } }
        $script:SaphirPerformanceRecord.pending.Clear()
        Stop-SaphirPerformanceSpan $init -Status $(if ($script:SaphirPerformanceWriterFailed) { "error" } else { "success" })
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
    param([string]$Name, [string]$Component = "Backend", [string]$Type = "function", [string]$Path = "", $Fields)
    if ($null -eq $script:SaphirPerformanceRecord) { return $null }
    $record = $script:SaphirPerformanceRecord
    $emit = $record.level -eq "detailed" -or $Type -in @("workflow", "infrastructure", "worker", "dispatch", "response", "wait") -or $Name -match 'Bootstrap|Prefetch|SessionForUser|AuthenticatedUserFromRequest|Sync-ReadModelCaches|Ensure-AuthStorage|Startup\.|^Http.Serialize'
    $parent = $record.rootSpanId
    for ($i = $record.stack.Count - 1; $i -ge 0; $i--) { if ($record.stack[$i].emit) { $parent = $record.stack[$i].id; break } }
    $frame = @{ name = $Name; id = [Guid]::NewGuid().ToString("N"); parentId = $parent; component = $Component; type = $Type; emit = $emit; start = [Diagnostics.Stopwatch]::GetTimestamp(); startUtc = [DateTime]::UtcNow.ToString("o"); childTicks = [long]0; fields = @{} }
    if ($Path) { $frame.fields = Get-SaphirPerformanceResource $Path }
    if ($Fields) { foreach ($key in $Fields.Keys) { $frame.fields[$key] = $Fields[$key] } }
    [void]$script:SaphirPerformanceRecord.stack.Add($frame)
    if ($emit) { Write-SaphirPerformanceEvent "span_start" $frame $frame.fields }
    return $frame
}

function Stop-SaphirPerformanceSpan {
    param($Frame, [string]$Status = "success", $ErrorRecord = $null)
    if ($null -eq $Frame -or $null -eq $script:SaphirPerformanceRecord) { return }
    $elapsed = [System.Diagnostics.Stopwatch]::GetTimestamp() - [long]$Frame.start
    $record = $script:SaphirPerformanceRecord
    # Remove the exact frame, never an unrelated parent after interrupted work.
    if ($record.stack.Count -gt 0 -and [object]::ReferenceEquals($record.stack[$record.stack.Count - 1], $Frame)) { $record.stack.RemoveAt($record.stack.Count - 1) }
    else { [void]$record.stack.Remove($Frame) }
    if ($record.stack.Count -gt 0) { $record.stack[$record.stack.Count - 1].childTicks += $elapsed }
    if (-not $record.functions.ContainsKey($Frame.name)) {
        $record.functions[$Frame.name] = @{ count = 0; ticks = [long]0; selfTicks = [long]0 }
    }
    $metric = $record.functions[$Frame.name]
    $metric.count++
    $metric.ticks += $elapsed
    $metric.selfTicks += [Math]::Max([long]0, [long]($elapsed - [long]$Frame.childTicks))
    if ($Frame.emit) {
        $fields = $Frame.fields.Clone()
        $fields.status = $Status
        $fields.durationMs = $elapsed * 1000.0 / [Diagnostics.Stopwatch]::Frequency
        $fields.startOffsetMs = ($Frame.start - [long]$record.start) * 1000.0 / [Diagnostics.Stopwatch]::Frequency
        $fields.endOffsetMs = $fields.startOffsetMs + $fields.durationMs
        if ($ErrorRecord) { $fields.errorCategory = $ErrorRecord.Exception.GetType().FullName }
        Write-SaphirPerformanceEvent "span_end" $Frame $fields
        if ($Status -eq "error") { Write-SaphirPerformanceEvent "error" $Frame $fields }
        if ($Frame.type -eq "filesystem") { Write-SaphirPerformanceEvent "filesystem_operation" $Frame $fields }
    }
}

function Add-SaphirPerformanceOperation {
    param([string]$Kind, [string]$Path = "", $Fields)
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
        $identity = (Get-SaphirPerformanceResource $Path).resourceId
        $resources = $script:SaphirPerformanceRecord.resources
        if ($identity) {
            if (-not $resources.ContainsKey($identity)) { $resources[$identity] = @{} }
            $resources[$identity][$Kind] = [int]$resources[$identity][$Kind] + 1
        }
    }
    if ($Kind.StartsWith("cache.") -and $script:SaphirPerformanceRecord.level -eq "detailed") {
        $parent = if ($script:SaphirPerformanceRecord.stack.Count) { $script:SaphirPerformanceRecord.stack[$script:SaphirPerformanceRecord.stack.Count - 1].id } else { $script:SaphirPerformanceRecord.rootSpanId }
        $frame = @{ id = [Guid]::NewGuid().ToString("N"); parentId = $parent; name = $Kind; type = "cache"; component = "Cache" }
        $data = if ($Path) { Get-SaphirPerformanceResource $Path } else { @{} }
        $data.cache = if ($Kind.EndsWith(".hit")) { "hit" } elseif ($Kind.EndsWith(".miss")) { "miss" } else { "event" }
        $data.servedFromCache = $data.cache -eq "hit"; $data.filesystemAccess = $false
        $data.cacheSize = $script:ReadModelCache.Count
        if ($Fields) { foreach ($field in $Fields.Keys) { $data[$field] = $Fields[$field] } }
        Write-SaphirPerformanceEvent "cache_event" $frame $data
    }
}

function Register-SaphirPerformanceFunctions {
    param([string[]]$Names, [string]$BackendRoot = "")
    if (-not $script:SaphirPerformanceEnabled) { return }
    if ($BackendRoot) {
        $Names = @(Get-Command -CommandType Function | Where-Object { -not $_.ModuleName -and $_.ScriptBlock.File -and $_.ScriptBlock.File.StartsWith($BackendRoot, [StringComparison]::OrdinalIgnoreCase) -and $_.ScriptBlock.File -notlike '*PerformanceTrace.ps1' } | ForEach-Object { $_.Name })
    }
    foreach ($name in $Names) {
        # Summary proxies only major services/storage boundaries. Detailed mode
        # captures every eligible backend function; proxying thousands of tiny
        # classification helpers is itself measurable PowerShell work.
        if ($script:SaphirPerformanceLevel -eq "summary" -and $name -notmatch '^(Get-(DashboardBootstrapModel|SelfBootstrapModel|ProjectsBootstrapModel|ApprovalsEntriesModel|EmployeeDataSnapshot|ScopedEmployeeDataSnapshot|EmployeeDirectoryList|ProjectStatistics.*|CachedEmployeeEntriesForFile|EmployeeReadContribution|ScopedEmployeeReadContribution|EmployeeCompensationReadEstimates|AuthenticatedUserFromRequest|AuthSyncVersion|UserLookupCache|SyncState|FileItemWithRetry|FileMetadataSnapshot|SaphirChildFilesWithRetry|TraceConstant)|Read-(SyncState.*|AuthArrayFileCached|TextFile.*|FileBytes.*|JsonArrayFile)|Write-(JsonAtomic|TextAtomic|HttpResponseSafely)|Acquire-ResourceLock|Release-ResourceLock|Sync-ReadModelCaches|Invoke-ReadModelCache|Ensure-AuthStorage|New-SessionForUser|Test-PasswordCredential|Publish-DataChange|Prefetch-EmployeeFileText)$') { continue }
        $command = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $command) { continue }
        $parameterBlock = $command.ScriptBlock.Ast.ParamBlock
        if ($null -eq $parameterBlock -and $command.ScriptBlock.Ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $parameterBlock = $command.ScriptBlock.Ast.Body.ParamBlock
        }
        if ($command.ScriptBlock.ToString().Contains("SaphirPerformanceOriginals")) { continue }
        $script:SaphirPerformanceOriginals[$name] = $command.ScriptBlock
        $component = if ($command.ScriptBlock.File) { [IO.Path]::GetFileNameWithoutExtension($command.ScriptBlock.File) } else { "Backend" }
        $inlineParameters = if ($command.ScriptBlock.Ast -is [Management.Automation.Language.FunctionDefinitionAst]) { @($command.ScriptBlock.Ast.Parameters) } else { @() }
        $parameters = if ($null -ne $parameterBlock) { $parameterBlock.Extent.Text } elseif ($inlineParameters.Count -gt 0) { "param(" + (@($inlineParameters | ForEach-Object { $_.Extent.Text }) -join ",") + ")" } else { "param()" }
        $wrapper = @"
$parameters
if (`$null -eq `$script:SaphirPerformanceRecord) { return (& `$script:SaphirPerformanceOriginals['$name'] @PSBoundParameters @args) }
`$performanceFrame = Start-SaphirPerformanceSpan -Name '$name' -Component '$component'
`$performanceStatus = 'success'
`$performanceError = `$null
try { & `$script:SaphirPerformanceOriginals['$name'] @PSBoundParameters @args }
catch { `$performanceStatus = if (`$_.Exception -is [OperationCanceledException] -or `$_.Exception -is [Management.Automation.PipelineStoppedException]) { 'cancelled' } else { 'error' }; `$performanceError = `$_; throw }
finally { Stop-SaphirPerformanceSpan -Frame `$performanceFrame -Status `$performanceStatus -ErrorRecord `$performanceError }
"@
        Set-Item -Path ("Function:script:{0}" -f $name) -Value ([scriptblock]::Create($wrapper))
    }
}

function Stop-SaphirPerformanceTrace {
    param([int]$StatusCode = 0)
    if ($null -eq $script:SaphirPerformanceRecord) { return }
    $record = $script:SaphirPerformanceRecord
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
        memory = @{ before = $record.memoryStart; after = $(try { Get-SaphirPerformanceMemory } catch { @{} }) }
        caches = @{ models = $script:ReadModelCache.Count; dependencies = $script:ReadModelDependencies.Count; employeeFiles = $script:EmployeeEntryFileCache.Count; textFiles = $script:TextFileCache.Count }
    }
    $sink = $record.sink
    Write-SaphirPerformanceEvent "trace_end" $null @{
        status = if ($StatusCode -ge 400) { "error" } else { "success" }
        durationMs = $result.totalMs; writerDropped = if ($sink) { $sink.Dropped } else { 0 }
        writerFailures = if ($sink) { $sink.Failures } else { [int]$script:SaphirPerformanceWriterFailed }
        eventCount = if ($sink) { $sink.Written } else { 0 }
        writerMs = if ($sink) { $sink.WriteTicks * 1000.0 / [Diagnostics.Stopwatch]::Frequency } else { 0 }
    }
    if ($sink) {
        $summaryLine = ConvertTo-Json -InputObject ([ordered]@{ schemaVersion = 2; event = "trace_summary"; traceId = $record.id; summary = $result }) -Depth 7 -Compress
        $sink.Enqueue($summaryLine)
    }
    $script:SaphirPerformanceRecord = $null
    # Logging is local stdout, not another shared-drive write. Durations are
    # inclusive and self-time excludes instrumented children, not all CPU work.
    Write-Host ("SAPHIR_PERF " + (ConvertTo-Json -InputObject $result -Depth 6 -Compress))
}

function Close-SaphirPerformanceWriter {
    if ($script:SaphirPerformanceWriter) { try { $script:SaphirPerformanceWriter.Dispose() } catch { }; $script:SaphirPerformanceWriter = $null }
}

function Start-SaphirFilesystemSpan {
    param([string]$Operation, [string]$Path, [int]$RetryCount = 0)
    if (-not $script:SaphirPerformanceRecord -or $script:SaphirPerformanceRecord.level -ne "detailed") { return $null }
    return (Start-SaphirPerformanceSpan -Name ("FileStore." + $Operation) -Component "FileStore" -Type "filesystem" -Path $Path -Fields @{ filesystemAccess = $true; servedFromCache = $false; retryCount = $RetryCount })
}

function Invoke-SaphirDiagnosticCall {
    param([string]$Name, [string]$Component = "FileStore", [string]$Type = "filesystem", [string]$Path = "", [int]$RetryCount = 0, [scriptblock]$Action)
    $frame = $null
    if ($script:SaphirPerformanceRecord -and ($Type -ne "filesystem" -or $script:SaphirPerformanceRecord.level -eq "detailed")) {
        $frame = Start-SaphirPerformanceSpan -Name $Name -Component $Component -Type $Type -Path $Path -Fields @{ filesystemAccess = $Type -eq "filesystem"; servedFromCache = $false; retryCount = $RetryCount }
        if ($frame -and $Path -and $script:FileMetadataCache -and $script:FileMetadataCache[$Path].Metadata) { $frame.fields.fileSizeBytes = $script:FileMetadataCache[$Path].Metadata.Length }
    }
    $status = "success"; $failure = $null
    try { & $Action }
    catch { $status = if ($_.Exception -is [OperationCanceledException] -or $_.Exception -is [Management.Automation.PipelineStoppedException]) { "cancelled" } else { "error" }; $failure = $_; throw }
    finally { if ($frame) { Stop-SaphirPerformanceSpan $frame -Status $status -ErrorRecord $failure } }
}

function Get-SaphirDiagnosticCacheEntry {
    param([string]$Name, $Cache, [string]$Key, [string]$Path = "")
    $frame = Start-SaphirPerformanceSpan -Name $Name -Component "Cache" -Type "cache" -Path $Path -Fields @{ cacheSize = $Cache.Count; filesystemAccess = $false }
    try {
        $value = $Cache[$Key]
        $frame.fields.cache = if ($null -ne $value) { "present" } else { "absent" }
        return $value
    } finally { Stop-SaphirPerformanceSpan $frame }
}
