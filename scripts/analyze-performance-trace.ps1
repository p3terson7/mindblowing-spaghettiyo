<# Local, offline analyzer. Reads JSONL as data, never evaluates trace content. #>
param(
    [Parameter(Mandatory = $true)][string[]]$TracePath,
    [string[]]$BrowserTracePath = @(),
    [string]$OutputBase = "",
    [switch]$Csv,
    [int]$MaxEvents = 200000
)
$ErrorActionPreference = "Stop"

function Get-TraceIntervalUnionMs {
    param([object[]]$Intervals, [double]$Lower = 0, [double]$Upper = [double]::MaxValue)
    $total = [double]0; $start = [double]0; $end = [double]0; $hasInterval = $false
    foreach ($interval in @($Intervals | Sort-Object startMs, endMs)) {
        $nextStart = [Math]::Max($Lower, [double]$interval.startMs)
        $nextEnd = [Math]::Min($Upper, [double]$interval.endMs)
        if ($nextEnd -le $nextStart) { continue }
        if (-not $hasInterval) { $start = $nextStart; $end = $nextEnd; $hasInterval = $true }
        elseif ($nextStart -le $end) { $end = [Math]::Max($end, $nextEnd) }
        else { $total += $end - $start; $start = $nextStart; $end = $nextEnd }
    }
    if ($hasInterval) { $total += $end - $start }
    return $total
}

function Get-TraceMaximumConcurrency {
    param([object[]]$Intervals)
    $points = @(foreach ($interval in $Intervals) {
        if ($null -eq $interval.endMs) { continue }
        [PSCustomObject]@{ time = $interval.startMs; delta = 1 }
        [PSCustomObject]@{ time = $interval.endMs; delta = -1 }
    })
    $active = 0; $maximum = 0
    foreach ($point in @($points | Sort-Object time, delta)) { $active += $point.delta; $maximum = [Math]::Max($maximum, $active) }
    return $maximum
}

function Get-TracePercentile {
    param([object[]]$Values, [double]$Percentile)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    return [double]$sorted[[Math]::Max(0, [int][Math]::Ceiling($Percentile * $sorted.Count) - 1)]
}

function Format-TraceNumber {
    param($Value)
    if ($null -eq $Value) { return "unavailable" }
    return ([double]$Value).ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-TraceSafeLabel {
    param($Value)
    return ([string]$Value -replace '[\r\n\t`|<>]', ' ').Substring(0, [Math]::Min(180, ([string]$Value).Length))
}

$files = @{}
foreach ($path in @($TracePath) + @($BrowserTracePath)) {
    if ([IO.Directory]::Exists($path)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $path -Filter "*.jsonl" -File)) { $files[$file.FullName] = $true }
    } else {
        $resolved = (Resolve-Path -LiteralPath $path).Path
        $files[$resolved] = $true
        # A rotated request can straddle files. Automatically include its peers.
        if ([IO.Path]::GetFileName($resolved) -match '^(SAPHIR-performance-.*)-\d{4}\.jsonl$') {
            foreach ($file in @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($resolved)) -Filter ($Matches[1] + "-*.jsonl") -File)) { $files[$file.FullName] = $true }
        }
    }
}
if ($files.Count -eq 0) { throw "No local trace files found." }
if (-not $OutputBase) { $OutputBase = Join-Path ([IO.Path]::GetDirectoryName(@($files.Keys)[0])) "SAPHIR-performance-report" }
$OutputBase = [IO.Path]::GetFullPath($OutputBase)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputBase)) | Out-Null

$spans = @{}; $traces = @{}; $cacheEvents = New-Object Collections.ArrayList
$browserSummaries = New-Object Collections.ArrayList; $summaries = New-Object Collections.ArrayList
$invalidLines = 0; $eventCount = 0; $limited = $false
foreach ($file in @($files.Keys | Sort-Object)) {
    foreach ($line in [IO.File]::ReadLines($file)) {
        if ($eventCount -ge $MaxEvents) { $limited = $true; break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -gt 262144) { $invalidLines++; continue }
        try { $item = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { $invalidLines++; continue }
        if ($item.schemaVersion -ne 2 -or [string]$item.traceId -notmatch '^[0-9a-f]{32}$') { $invalidLines++; continue }
        $eventCount++
        $traceId = [string]$item.traceId
        if (-not $traces.ContainsKey($traceId)) { $traces[$traceId] = @{ traceId = $traceId; source = if ($item.source -eq "browser") { "browser" } else { "backend" }; level = [string]$item.level; startUtc = $null; rootId = ""; durationMs = $null; status = "incomplete"; writerDropped = 0; writerFailures = 0 } }
        if ($item.timestampUtc -and ($null -eq $traces[$traceId].startUtc -or $item.event -eq "trace_start")) {
            try {
                $utc = if ($item.timestampUtc -is [DateTime]) { $item.timestampUtc } else { [DateTime]::Parse([string]$item.timestampUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
                $traces[$traceId].startUtc = $utc.ToUniversalTime().ToString("o")
            } catch { $traces[$traceId].startUtc = "unknown" }
        }
        $key = "$traceId|$($item.spanId)"
        if ($item.event -eq "trace_summary") { [void]$summaries.Add($item); continue }
        if ($item.event -eq "browser_summary") { [void]$browserSummaries.Add($item); continue }
        if ($item.event -eq "cache_event") { [void]$cacheEvents.Add($item); continue }
        if ($item.event -in @("trace_start", "span_start")) {
            if ($spans.ContainsKey($key)) { continue }
            $spans[$key] = [PSCustomObject]@{
                traceId = $traceId; source = $traces[$traceId].source; spanId = [string]$item.spanId; parentSpanId = [string]$item.parentSpanId
                operation = Get-TraceSafeLabel $item.operation; component = Get-TraceSafeLabel $item.component; operationType = [string]$item.operationType
                startUtc = $item.timestampUtc; endUtc = $null; startMs = [double]$item.offsetMs; endMs = $null; inclusiveMs = $null; exclusiveMs = $null
                status = "incomplete"; resourceId = [string]$item.resourceId; resourceCategory = [string]$item.resourceCategory
                filesystemAccess = [bool]$item.filesystemAccess; sharedResource = [bool]$item.sharedResource; retryCount = [int]$item.retryCount
                fileSizeBytes = $item.fileSizeBytes; workerIndex = $item.workerIndex; workerLimit = $item.workerLimit; scheduledOffsetMs = $item.scheduledOffsetMs
                backendTraceId = ""; processId = $item.processId; threadId = $item.threadId; runspaceId = $item.runspaceId; errorCategory = ""
                missingStart = $false; missingParent = $false
            }
            if ($item.event -eq "trace_start") { $traces[$traceId].rootId = [string]$item.spanId; $spans[$key].startMs = 0 }
        }
        elseif ($item.event -in @("span_end", "trace_end")) {
            if (-not $spans.ContainsKey($key)) {
                $spans[$key] = [PSCustomObject]@{
                    traceId = $traceId; source = $traces[$traceId].source; spanId = [string]$item.spanId; parentSpanId = [string]$item.parentSpanId
                    operation = Get-TraceSafeLabel $item.operation; component = Get-TraceSafeLabel $item.component; operationType = [string]$item.operationType
                    startUtc = $null; endUtc = $null; startMs = [double]$item.startOffsetMs; endMs = $null; inclusiveMs = $null; exclusiveMs = $null
                    status = "incomplete"; resourceId = [string]$item.resourceId; resourceCategory = [string]$item.resourceCategory
                    filesystemAccess = [bool]$item.filesystemAccess; sharedResource = [bool]$item.sharedResource; retryCount = [int]$item.retryCount
                    fileSizeBytes = $item.fileSizeBytes; workerIndex = $item.workerIndex; workerLimit = $item.workerLimit; scheduledOffsetMs = $item.scheduledOffsetMs
                    backendTraceId = ""; processId = $item.processId; threadId = $item.threadId; runspaceId = $item.runspaceId; errorCategory = ""
                    missingStart = $true; missingParent = $false
                }
            }
            $span = $spans[$key]
            $span.endUtc = $item.timestampUtc; $span.inclusiveMs = [double]$item.durationMs
            if ($item.event -eq "span_end") { $span.startMs = [double]$item.startOffsetMs; $span.endMs = [double]$item.endOffsetMs }
            else { $span.endMs = $span.startMs + $span.inclusiveMs }
            $span.status = [string]$item.status; $span.backendTraceId = [string]$item.backendTraceId; $span.errorCategory = [string]$item.errorCategory
            if ($item.event -eq "trace_end") {
                $traces[$traceId].durationMs = $item.durationMs; $traces[$traceId].status = [string]$item.status
                $traces[$traceId].writerDropped = [long]$item.writerDropped; $traces[$traceId].writerFailures = [long]$item.writerFailures
            }
        }
    }
}

$children = @{}
foreach ($span in $spans.Values) {
    if ($span.parentSpanId) {
        $parentKey = "$($span.traceId)|$($span.parentSpanId)"
        if (-not $children.ContainsKey($parentKey)) { $children[$parentKey] = New-Object Collections.ArrayList }
        [void]$children[$parentKey].Add($span)
        $span.missingParent = -not $spans.ContainsKey($parentKey)
    }
}
foreach ($key in $spans.Keys) {
    $span = $spans[$key]
    if ($null -ne $span.inclusiveMs -and -not $span.missingStart) {
        $intervals = @($children[$key] | Where-Object { $null -ne $_.endMs })
        $span.exclusiveMs = [Math]::Max([double]0, ($span.inclusiveMs - (Get-TraceIntervalUnionMs -Intervals $intervals -Lower $span.startMs -Upper $span.endMs)))
    }
}

$all = @($spans.Values | Sort-Object source, @{ Expression = { $traces[$_.traceId].startUtc } }, startMs, spanId)
$fs = @($all | Where-Object { $_.operationType -eq "filesystem" -and $_.filesystemAccess -and $null -ne $_.inclusiveMs })
$sharedFs = @($fs | Where-Object sharedResource)
$workers = @($all | Where-Object { $_.operation -eq "EmployeeFile.Worker" })
$parallel = @(foreach ($group in @($workers | Group-Object traceId)) {
    $complete = @($group.Group | Where-Object { $null -ne $_.endMs })
    $limit = @($all | Where-Object { $_.traceId -eq $group.Name -and $_.operation -eq "EmployeeFileReadService.Prefetch" } | ForEach-Object workerLimit | Select-Object -First 1)
    $prefetch = @($all | Where-Object { $_.traceId -eq $group.Name -and $_.operation -eq "EmployeeFileReadService.Prefetch" } | ForEach-Object inclusiveMs | Select-Object -First 1)
    $activity = New-Object Collections.ArrayList; $active = 0
    $points = @(foreach ($worker in $complete) { [PSCustomObject]@{ offsetMs = $worker.startMs; delta = 1 }; [PSCustomObject]@{ offsetMs = $worker.endMs; delta = -1 } })
    foreach ($point in @($points | Sort-Object offsetMs, delta)) { $active += $point.delta; [void]$activity.Add([PSCustomObject]@{ offsetMs = $point.offsetMs; activeWorkers = $active }) }
    [PSCustomObject]@{ traceId = $group.Name; configuredLimit = if ($limit.Count) { $limit[0] } else { $null }; maximumConcurrency = Get-TraceMaximumConcurrency $complete; workerCount = $group.Count; incompleteWorkers = $group.Count - $complete.Count; prefetchWallMs = if ($prefetch.Count) { $prefetch[0] } else { $null }; workerInclusiveSumMs = ($complete | Measure-Object inclusiveMs -Sum).Sum; slowestWorkerMs = ($complete | Measure-Object inclusiveMs -Maximum).Maximum; averageWorkerMs = ($complete | Measure-Object inclusiveMs -Average).Average; schedulingDelayMs = @($complete | ForEach-Object { [Math]::Max([double]0, ($_.startMs - [double]$_.scheduledOffsetMs)) }); activityTimeline = @($activity.ToArray()) }
})
$repeated = @(foreach ($group in @($all | Group-Object operation)) {
    $resources = @($group.Group | Where-Object resourceId | Group-Object resourceId)
    [PSCustomObject]@{ operation = $group.Name; calls = $group.Count; inclusiveSumMs = ($group.Group | Measure-Object inclusiveMs -Sum).Sum; uniqueResources = $resources.Count; repeatedResources = @($resources | Where-Object Count -gt 1).Count }
})
$correlations = @(foreach ($span in @($all | Where-Object backendTraceId)) {
    $backend = $traces[$span.backendTraceId]
    [PSCustomObject]@{ backendTraceId = $span.backendTraceId; browserOperation = $span.operation; browserObservedHeadersMs = $span.inclusiveMs; backendRequestMs = if ($backend) { $backend.durationMs } else { $null }; differenceMs = if ($backend -and $null -ne $backend.durationMs) { $span.inclusiveMs - [double]$backend.durationMs } else { $null } }
})
$browserDashboard = @(foreach ($span in @($all | Where-Object { $_.source -eq "browser" -and $_.operation -eq "refreshDashboardView" })) {
    $paint = @($all | Where-Object { $_.traceId -eq $span.traceId -and $_.parentSpanId -eq $span.spanId -and $_.operation -eq "Dashboard.UsableAfterPaint" } | Select-Object -First 1)
    [PSCustomObject]@{ traceId = $span.traceId; dashboardWorkMs = $span.inclusiveMs; usableAfterMs = if ($paint.Count -and $null -ne $paint[0].endMs) { $paint[0].endMs - $span.startMs } else { $null }; navigationToUsableMs = if ($paint.Count) { $paint[0].endMs } else { $null }; readinessDefinition = "Dashboard refresh resolved successfully followed by two animation frames; not an OS-level responsiveness test." }
})
$summary = [ordered]@{
    schemaVersion = 2; inputFileCount = $files.Count; eventCount = $eventCount; invalidOrPartialLines = $invalidLines; inputLimitReached = $limited
    traces = @($traces.Values); spans = $all; correlations = $correlations; browserDashboard = $browserDashboard; browserNavigation = @($browserSummaries.ToArray())
    incompleteSpans = @($all | Where-Object { $_.status -eq "incomplete" }).Count
    missingParents = @($all | Where-Object missingParent).Count; missingStarts = @($all | Where-Object missingStart).Count
    filesystem = @{ applicationCalls = $fs.Count; sharedApplicationCalls = $sharedFs.Count; metadata = @($sharedFs | Where-Object operation -match 'Metadata').Count; enumerations = @($sharedFs | Where-Object operation -match 'Enumerate').Count; reads = @($sharedFs | Where-Object operation -match 'ReadText|ReadBytes').Count; retryAttempts = @($sharedFs | Where-Object retryCount -gt 0).Count; medianMs = Get-TracePercentile @($sharedFs | ForEach-Object inclusiveMs) 0.5; p95Ms = Get-TracePercentile @($sharedFs | ForEach-Object inclusiveMs) 0.95 }
    parallelism = $parallel; cacheEvents = @($cacheEvents.ToArray()); aggregateSummaries = @($summaries.ToArray()); repeatedOperations = $repeated
    timingCaveats = @("Filesystem spans measure application calls, not SMB packets or pure network latency.", "Inclusive sums overlap; only interval unions represent elapsed coverage.", "Exclusive time includes uninstrumented work, scheduling and tracing overhead; it is not CPU time.", "Browser/server durations use separate monotonic clocks. Correlation joins IDs, never wall-clock timestamps.", "Summary mode intentionally omits individual filesystem/cache/function events.")
}
$encoding = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputBase + ".json", (ConvertTo-Json -InputObject $summary -Depth 14), $encoding)
if ($Csv) { $all | Export-Csv -LiteralPath ($OutputBase + ".csv") -NoTypeInformation -Encoding UTF8 }

$markdown = New-Object Text.StringBuilder
function Add-ReportLine { param([string]$Text = "") [void]$markdown.AppendLine($Text) }
Add-ReportLine "# SAPHIR performance trace report"
Add-ReportLine
Add-ReportLine "Local diagnostic data only. Events: $eventCount. Files: $($files.Count). Invalid/partial lines: $invalidLines. Incomplete spans: $($summary.incompleteSpans). Missing parents: $($summary.missingParents). Input limit reached: $limited."
Add-ReportLine
Add-ReportLine "## A. Overall timeline"
Add-ReportLine
Add-ReportLine "Backend startup and requests are separate traces. Browser timings start at the browser performance time origin; clocks are not synchronized. Login workflow timing can include subsequent workspace loading."
Add-ReportLine
Add-ReportLine "| Workflow | Source | Duration ms | Status |"
Add-ReportLine "|---|---|---:|---|"
foreach ($span in @($all | Where-Object { -not $_.parentSpanId -or $_.operation -match 'refreshDashboardView|submitLogin|UsableAfterPaint|bootstrapApplication' })) { Add-ReportLine "| $($span.operation) | $($span.source) | $(Format-TraceNumber $span.inclusiveMs) | $($span.status) |" }
foreach ($row in $browserDashboard) { Add-ReportLine "| Dashboard refresh start to usable after paint | browser | $(Format-TraceNumber $row.usableAfterMs) | measured |" }
Add-ReportLine
Add-ReportLine "| Correlated request | Browser to headers ms | Backend ms | Difference ms |"
Add-ReportLine "|---|---:|---:|---:|"
foreach ($row in $correlations) { Add-ReportLine "| $($row.browserOperation) | $(Format-TraceNumber $row.browserObservedHeadersMs) | $(Format-TraceNumber $row.backendRequestMs) | $(Format-TraceNumber $row.differenceMs) |" }
Add-ReportLine
Add-ReportLine "The difference is not pure network time: it also includes browser scheduling, listener queueing and boundary differences (server response-close versus browser headers). Body reading, JSON parsing and paint readiness have separate spans. Missing browser exports mean frontend latency is unavailable, not zero. Navigation timings are included in the JSON summary."
Add-ReportLine
Add-ReportLine "## B. Hierarchical execution tree"
Add-ReportLine
Add-ReportLine "Offsets and durations are milliseconds. Exclusive time subtracts the UNION of completed direct-child intervals clipped to the parent, not the sum of overlapping workers. An incomplete child can make exclusive time an upper bound."
Add-ReportLine
Add-ReportLine '```text'
$visited = @{}
function Add-TraceTree {
    param($Span, [int]$Depth = 0)
    $key = "$($Span.traceId)|$($Span.spanId)"
    if ($visited.ContainsKey($key)) { return }
    $visited[$key] = $true
    Add-ReportLine (("  " * [Math]::Min($Depth, 40)) + "$($Span.operation) [$($Span.source)] start=$(Format-TraceNumber $Span.startMs) end=$(Format-TraceNumber $Span.endMs) inclusive=$(Format-TraceNumber $Span.inclusiveMs) exclusive=$(Format-TraceNumber $Span.exclusiveMs) status=$($Span.status)" + $(if ($Span.missingStart -or $Span.missingParent) { " MISSING CONTEXT" } else { "" }))
    foreach ($child in @($children[$key] | Sort-Object startMs, spanId)) { Add-TraceTree $child ($Depth + 1) }
}
foreach ($root in @($all | Where-Object { -not $_.parentSpanId -or $_.missingParent })) { Add-TraceTree $root }
foreach ($span in $all) { if (-not $visited.ContainsKey("$($span.traceId)|$($span.spanId)")) { Add-TraceTree $span } }
Add-ReportLine '```'
Add-ReportLine
Add-ReportLine "## C. Slowest individual operations"
Add-ReportLine
Add-ReportLine "| Operation | Component | Type | Duration ms | Parent span | Resource | Status |"
Add-ReportLine "|---|---|---|---:|---|---|---|"
foreach ($span in @($all | Where-Object parentSpanId | Sort-Object inclusiveMs -Descending | Select-Object -First 30)) { Add-ReportLine "| $($span.operation) | $($span.component) | $($span.operationType) | $(Format-TraceNumber $span.inclusiveMs) | $($span.parentSpanId) | $($span.resourceId) | $($span.status) |" }
Add-ReportLine
Add-ReportLine "## D. Repeated operations"
Add-ReportLine
Add-ReportLine "Inclusive sums below are NOT additive wall-clock time. Repeated calls can be necessary; call counts alone do not establish a bottleneck."
Add-ReportLine
Add-ReportLine "| Operation | Calls | Inclusive sum ms | Unique resources | Repeated resources |"
Add-ReportLine "|---|---:|---:|---:|---:|"
foreach ($row in @($repeated | Where-Object calls -gt 1 | Sort-Object inclusiveSumMs -Descending | Select-Object -First 40)) { Add-ReportLine "| $($row.operation) | $($row.calls) | $(Format-TraceNumber $row.inclusiveSumMs) | $($row.uniqueResources) | $($row.repeatedResources) |" }
Add-ReportLine
Add-ReportLine "## E. Shared filesystem activity"
Add-ReportLine
Add-ReportLine "Detailed shared application calls: $($sharedFs.Count); metadata: $($summary.filesystem.metadata); enumerations: $($summary.filesystem.enumerations); reads: $($summary.filesystem.reads); retry attempts: $($summary.filesystem.retryAttempts). Latency median: $(Format-TraceNumber $summary.filesystem.medianMs) ms; p95: $(Format-TraceNumber $summary.filesystem.p95Ms) ms. These are application-level calls, not SMB packets. OS caches, security scanning and provider processing can contribute to their duration."
Add-ReportLine
Add-ReportLine "| Shared operation | Resource category | Duration ms | Retry index | Resource |"
Add-ReportLine "|---|---|---:|---:|---|"
foreach ($span in @($sharedFs | Sort-Object inclusiveMs -Descending | Select-Object -First 20)) { Add-ReportLine "| $($span.operation) | $($span.resourceCategory) | $(Format-TraceNumber $span.inclusiveMs) | $($span.retryCount) | $($span.resourceId) |" }
Add-ReportLine
Add-ReportLine "## F. Parallelism analysis"
Add-ReportLine
Add-ReportLine "| Trace | Limit | Observed maximum | Workers | Prefetch wall ms | Worker inclusive sum ms | Slowest ms | Average ms |"
Add-ReportLine "|---|---:|---:|---:|---:|---:|---:|---:|"
foreach ($row in $parallel) { Add-ReportLine "| $($row.traceId) | $($row.configuredLimit) | $($row.maximumConcurrency) | $($row.workerCount) | $(Format-TraceNumber $row.prefetchWallMs) | $(Format-TraceNumber $row.workerInclusiveSumMs) | $(Format-TraceNumber $row.slowestWorkerMs) | $(Format-TraceNumber $row.averageWorkerMs) |" }
Add-ReportLine
Add-ReportLine "Runspaces.CreatePool, OpenPool, CreateInvocation, ScheduleWorker, Worker.LoadFileStore, CollectWorker, MergeResults, DisposeInvocations and DisposePool are individually timed. Worker scheduling-delay arrays are in JSON. Delay before worker entry includes slot scheduling and engine dispatch; collection waits overlap worker execution. Worker duration sums can exceed wall time because workers overlap."
Add-ReportLine
Add-ReportLine "## G. Cache analysis"
Add-ReportLine
Add-ReportLine "Detailed cache events: $($cacheEvents.Count). Full per-event reasons, sizes, model categories and affected-model counts are in JSON. Aggregate summaries also preserve file, read-model, authentication, contribution-recompute, invalidation and eviction counters when summary-level spans omit individual calls."
foreach ($item in $summaries) {
    Add-ReportLine
    Add-ReportLine "Trace $($item.traceId):"
    foreach ($property in @($item.summary.operations.PSObject.Properties | Where-Object { $_.Name -like 'cache.*' -or $_.Name -like 'fs.*' } | Sort-Object Name)) { Add-ReportLine "- $($property.Name): $($property.Value)" }
}
Add-ReportLine
Add-ReportLine "## H. Bottleneck summary"
Add-ReportLine
foreach ($trace in @($traces.Values | Where-Object source -eq "backend")) {
    $calls = @($sharedFs | Where-Object traceId -eq $trace.traceId)
    $coverage = Get-TraceIntervalUnionMs $calls
    Add-ReportLine "- Measured: trace $($trace.traceId) spans $(Format-TraceNumber $trace.durationMs) ms; shared filesystem-call interval coverage is $(Format-TraceNumber $coverage) ms. Remaining elapsed time is not automatically CPU time."
}
Add-ReportLine "- Interpretation: compare the largest measured filesystem calls, runspace lifecycle spans, serializer spans and exclusive service spans with the correlated browser request/rendering stages."
Add-ReportLine "- Hypotheses requiring a corporate capture: antivirus scanning, SMB authentication, corporate network latency, process startup and power-management differences. Domestic SMB results do not establish which one is responsible."
Add-ReportLine "- Blind spots: launcher activity before this backend process, OS-level network/CPU sampling, private domain-module calls inside a measured facade, time queued before HttpListener.GetContext returns, browser work before AppShell loads, and unfinished/lost/dropped events. Navigation timings partly cover browser work before AppShell; summary mode is intentionally less granular."
Add-ReportLine "- Durability: the local writer flushes approximately every 250 ms or 64 events to the OS, not fsync per event. A blocked/failed disk, saturated queue, forced termination or power loss can lose more than this expected healthy-disk window. Rotated/expired files can remove context."
[IO.File]::WriteAllText($OutputBase + ".md", $markdown.ToString(), $encoding)
Write-Host "Markdown report: $OutputBase.md"
Write-Host "JSON summary: $OutputBase.json"
if ($Csv) { Write-Host "Operation CSV: $OutputBase.csv" }
