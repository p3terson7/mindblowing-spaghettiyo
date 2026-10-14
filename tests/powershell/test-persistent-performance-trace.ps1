$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$backend = Join-Path $repo "app/backend"
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$owned = Join-Path $local ("SAPHIR/trace-test-" + [Guid]::NewGuid().ToString("N"))
$saved = @{}
foreach ($name in @("SAPHIR_PERFORMANCE_TRACE", "SAPHIR_PERF_TRACE", "SAPHIR_TRACE_LEVEL", "SAPHIR_TRACE_DIR")) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$child = $null
function Assert-Trace { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
try {
    $env:SAPHIR_PERFORMANCE_TRACE = "0"; $env:SAPHIR_PERF_TRACE = "0"; $env:SAPHIR_TRACE_DIR = Join-Path $owned "disabled"
    . (Join-Path $backend "lib/PerformanceTrace.ps1")
    foreach ($i in 1..1000) { Start-SaphirPerformanceTrace "disabled"; Start-SaphirPerformanceSpan "disabled" | Out-Null }
    Assert-Trace (-not [IO.Directory]::Exists($env:SAPHIR_TRACE_DIR)) "Disabled tracing touched the filesystem."
    Assert-Trace ($null -eq $script:SaphirPerformanceWriter -and $null -eq $script:SaphirPerformanceRecord) "Disabled tracing allocated persistent diagnostic state."

    $env:SAPHIR_PERFORMANCE_TRACE = "1"; $env:SAPHIR_TRACE_LEVEL = "detailed"; $env:SAPHIR_TRACE_DIR = Join-Path $owned "detailed"
    . (Join-Path $backend "lib/PerformanceTrace.ps1")
    Start-SaphirPerformanceTrace "GET /employee/Private-Employee-Name?token=private-token"
    Assert-Trace ($null -ne $script:SaphirPerformanceWriter) "Local persistent writer failed to initialize."
    $traceId = $script:SaphirPerformanceRecord.id
    function Test-InlineTraceParameters($first, $second = "default") { return "$first|$second" }
    function Test-TraceVariableArguments { return ($args -join "|") }
    Register-SaphirPerformanceFunctions @("Test-InlineTraceParameters", "Test-TraceVariableArguments")
    Assert-Trace ((Test-InlineTraceParameters "first" "second") -eq "first|second") "Inline function parameters changed under tracing."
    Assert-Trace ((Test-InlineTraceParameters -first "first") -eq "first|default") "Inline parameter defaults changed under tracing."
    Assert-Trace ((Test-TraceVariableArguments "first" "second") -eq "first|second") "Unbound arguments changed under tracing."
    $parent = Start-SaphirPerformanceSpan "Parent" -Component "Test" -Type "workflow"
    $nested = Start-SaphirPerformanceSpan "Nested" -Component "Test"
    Assert-Trace ($nested.parentId -eq $parent.id) "Nested span lost its parent."
    $nested.start = [Diagnostics.Stopwatch]::GetTimestamp() - [Diagnostics.Stopwatch]::Frequency
    $nested.startUtc = [DateTime]::UtcNow.AddDays(1).ToString("o")
    Stop-SaphirPerformanceSpan $nested
    Stop-SaphirPerformanceSpan $parent
    $resourcePath = Join-Path $owned "123456789_data.json"
    $resource = Get-SaphirPerformanceResource $resourcePath
    Assert-Trace ([string]$resource.resourceId -match '^[0-9a-f]{32}$') "Resource anonymization did not produce a keyed identifier."
    Assert-Trace ($resource.resourceId -eq (Get-SaphirPerformanceResource $resourcePath).resourceId) "Resource correlation was not stable within a trace."
    $failure = Start-SaphirPerformanceSpan "Failed" -Component "Test"
    try { throw "private-password $resourcePath" } catch { Stop-SaphirPerformanceSpan $failure -Status "error" -ErrorRecord $_ }
    Stop-SaphirPerformanceTrace 500 6>&1 | Out-Null
    $writer = $script:SaphirPerformanceWriter
    Close-SaphirPerformanceWriter
    $lines = @($writer.FilePaths | ForEach-Object { [IO.File]::ReadAllLines($_) })
    $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Trace ($events.Count -gt 10) "Persistent events are missing."
    Assert-Trace (($lines -join "") -notmatch 'Private-Employee-Name|private-password|private-token|123456789|trace-test-') "Trace exposed identities, secrets or paths."
    $nestedEnd = @($events | Where-Object { $_.event -eq "span_end" -and $_.operation -eq "Nested" })[0]
    Assert-Trace ($nestedEnd.durationMs -ge 999 -and $nestedEnd.durationMs -lt 5000) "Duration used wall-clock timestamps instead of monotonic ticks."
    Assert-Trace (@($events | Where-Object event -eq "error").Count -eq 1) "Error status/category was not recorded."

    # Use real bounded read workers and the existing deterministic fixture.
    $env:SAPHIR_TRACE_DIR = Join-Path $owned "workers"
    $fixture = Join-Path $owned "business-fixture"
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $fixture -Create -EmployeeCount 12
    Start-SaphirPerformanceTrace "GET /dashboard/bootstrap"
    Register-SaphirPerformanceFunctions -BackendRoot $backend
    $id = $script:SaphirPerformanceRecord.id
    $dashboard = Get-DashboardBootstrapModel -CurrentUser (Get-UserByUsername "audit-super")
    Assert-Trace ($dashboard.trackedEmployees -eq 12) "Detailed tracing changed dashboard results."
    Stop-SaphirPerformanceTrace 200 6>&1 | Out-Null
    $writer = $script:SaphirPerformanceWriter; Close-SaphirPerformanceWriter
    $workerFiles = @($writer.FilePaths)
    $workerEvents = @($workerFiles | ForEach-Object { [IO.File]::ReadAllLines($_) | ForEach-Object { $_ | ConvertFrom-Json } })
    $workerStarts = @($workerEvents | Where-Object { $_.event -eq "span_start" -and $_.operation -eq "EmployeeFile.Worker" })
    Assert-Trace ($workerStarts.Count -ge 12) "Concurrent workers were not individually traced."
    Assert-Trace (@($workerStarts | Where-Object { $_.traceId -ne $id -or -not $_.parentSpanId }).Count -eq 0) "Workers lost shared request correlation or explicit batch parents."
    Assert-Trace (@($workerEvents | Where-Object event -eq "filesystem_operation").Count -gt 0) "Individual filesystem timings are missing."
    & (Join-Path $repo "scripts/analyze-performance-trace.ps1") -TracePath $workerFiles -OutputBase (Join-Path $owned "worker-report") -Csv
    $report = [IO.File]::ReadAllText((Join-Path $owned "worker-report.json")) | ConvertFrom-Json
    Assert-Trace ($report.missingParents -eq 0 -and $report.invalidOrPartialLines -eq 0) "Execution tree or JSONL serialization is invalid."
    Assert-Trace ($report.parallelism[0].maximumConcurrency -le $report.parallelism[0].configuredLimit) "Tracing exceeded the bounded reader limit."

    # Deterministic overlapping children: 100 - union([10,60],[30,80]) = 30.
    $overlapId = [Guid]::NewGuid().ToString("N"); $rootId = [Guid]::NewGuid().ToString("N")
    $overlap = New-Object Collections.ArrayList
    [void]$overlap.Add(@{ schemaVersion = 2; event = "trace_start"; traceId = $overlapId; spanId = $rootId; operation = "overlap"; offsetMs = 0 })
    foreach ($case in @(@{ start = 10; end = 60 }, @{ start = 30; end = 80 })) {
        $spanId = [Guid]::NewGuid().ToString("N")
        [void]$overlap.Add(@{ schemaVersion = 2; event = "span_start"; traceId = $overlapId; spanId = $spanId; parentSpanId = $rootId; operation = "parallel"; offsetMs = $case.start })
        [void]$overlap.Add(@{ schemaVersion = 2; event = "span_end"; traceId = $overlapId; spanId = $spanId; parentSpanId = $rootId; operation = "parallel"; startOffsetMs = $case.start; endOffsetMs = $case.end; durationMs = $case.end - $case.start; status = "success" })
    }
    [void]$overlap.Add(@{ schemaVersion = 2; event = "trace_end"; traceId = $overlapId; spanId = $rootId; operation = "overlap"; durationMs = 100; status = "success" })
    $overlapPath = Join-Path $owned "overlap.jsonl"
    [IO.File]::WriteAllLines($overlapPath, [string[]]@($overlap | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }))
    & (Join-Path $repo "scripts/analyze-performance-trace.ps1") -TracePath $overlapPath -OutputBase (Join-Path $owned "overlap-report")
    $overlapReport = [IO.File]::ReadAllText((Join-Path $owned "overlap-report.json")) | ConvertFrom-Json
    Assert-Trace (@($overlapReport.spans | Where-Object operation -eq "overlap")[0].exclusiveMs -eq 30) "Exclusive duration summed overlapping children."

    $rotationFolder = Join-Path $owned "rotation"
    [IO.Directory]::CreateDirectory($rotationFolder) | Out-Null
    $oldTrace = Join-Path $rotationFolder "SAPHIR-performance-expired.jsonl"
    [IO.File]::WriteAllText($oldTrace, "{}"); [IO.File]::SetLastWriteTimeUtc($oldTrace, [DateTime]::UtcNow.AddDays(-10))
    $unrelated = Join-Path $rotationFolder "keep.jsonl"; [IO.File]::WriteAllText($unrelated, "{}")
    $rotating = New-Object Saphir.Diagnostics.TraceWriter($rotationFolder, 512, 2, 7, 4096, 25)
    foreach ($i in 1..100) { $rotating.Enqueue('{"event":"test","payload":"padding-padding-padding-padding-padding-padding"}') }
    $rotating.Dispose()
    Assert-Trace (@(Get-ChildItem -LiteralPath $rotationFolder -Filter "SAPHIR-performance-*.jsonl").Count -le 2) "Trace rotation exceeded its file limit."
    Assert-Trace (-not [IO.File]::Exists($oldTrace) -and [IO.File]::Exists($unrelated)) "Retention deleted unrelated files or failed to expire diagnostics."
    $rotating.Enqueue("{}"); Assert-Trace ($rotating.Dropped -gt 0) "A closed diagnostic sink did not fail safely."

    $env:SAPHIR_TRACE_DIR = Join-Path $owned "crash"
    $executable = (Get-Process -Id $PID).Path
    $child = Start-Process $executable -ArgumentList @("-NoProfile", "-File", ('"' + (Join-Path $repo "tests/lib/PerformanceTraceCrashWorker.ps1") + '"'), "-BackendRoot", ('"' + $backend + '"')) -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15); $persisted = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $crashFiles = @(Get-ChildItem -LiteralPath $env:SAPHIR_TRACE_DIR -Filter "*.jsonl" -ErrorAction SilentlyContinue)
        foreach ($file in $crashFiles) { if ([IO.File]::ReadAllText($file.FullName) -match 'Blocked.Operation') { $persisted = $true } }
        if ($persisted) { break }; Start-Sleep -Milliseconds 100
    }
    Assert-Trace $persisted "Spans were not flushed while the request execution thread was blocked."
    Stop-Process -Id $child.Id -Force; $child.WaitForExit(); $child = $null
    & (Join-Path $repo "scripts/analyze-performance-trace.ps1") -TracePath $env:SAPHIR_TRACE_DIR -OutputBase (Join-Path $owned "interrupted-report")
    $crashReport = [IO.File]::ReadAllText((Join-Path $owned "interrupted-report.json")) | ConvertFrom-Json
    Assert-Trace ($crashReport.incompleteSpans -ge 2) "Interrupted execution did not retain incomplete spans."

    $env:SAPHIR_TRACE_DIR = "\\corporate-share\data\traces"
    . (Join-Path $backend "lib/PerformanceTrace.ps1")
    Start-SaphirPerformanceTrace "blocked-destination" 3>&1 | Out-Null
    Assert-Trace ($null -eq $script:SaphirPerformanceWriter -and $script:SaphirPerformanceWriterFailed) "Tracing accepted a corporate/network destination."
    Stop-SaphirPerformanceTrace 200 6>&1 | Out-Null
    $blocked = Join-Path $owned "file-instead-of-directory"; [IO.File]::WriteAllText($blocked, "unchanged")
    $env:SAPHIR_TRACE_DIR = $blocked
    . (Join-Path $backend "lib/PerformanceTrace.ps1")
    Start-SaphirPerformanceTrace "logging-failure" 3>&1 | Out-Null
    Assert-Trace ($script:SaphirPerformanceWriterFailed -and [IO.File]::ReadAllText($blocked) -eq "unchanged") "Logging failures changed application data."
    Stop-SaphirPerformanceTrace 200 6>&1 | Out-Null
    Write-Host "Persistent tracing passed: hierarchy, monotonic timing, workers, overlap, crash recovery, JSONL, retention, privacy, local-only storage and failure isolation."
} finally {
    Close-SaphirPerformanceWriter
    if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
