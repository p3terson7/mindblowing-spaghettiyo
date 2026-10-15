function Get-EmployeeFileReadConcurrency {
    $configured = 0
    [int]::TryParse([string]$env:SAPHIR_EMPLOYEE_READ_CONCURRENCY, [ref]$configured) | Out-Null
    if ($configured -in @(1, 2, 4, 8)) { return $configured }
    # The repeated SMB experiment showed useful gains through 8 readers.
    # Operators can select 1/2/4/8; never infer an unbounded thread count.
    return 8
}

function Merge-EmployeeFileReadMetrics {
    param($Metrics)
    $record = $script:SaphirPerformanceRecord
    if ($null -eq $record -or $null -eq $Metrics) { return }
    foreach ($key in $Metrics.operations.Keys) { $record.operations[$key] = [int]$record.operations[$key] + [int]$Metrics.operations[$key] }
    foreach ($id in $Metrics.resources.Keys) {
        if (-not $record.resources.ContainsKey($id)) { $record.resources[$id] = @{} }
        foreach ($key in $Metrics.resources[$id].Keys) { $record.resources[$id][$key] = [int]$record.resources[$id][$key] + [int]$Metrics.resources[$id][$key] }
    }
    # Worker durations overlap. Prefix them so they are not mistaken for the
    # request's sequential spans; the enclosing preload span is wall time.
    foreach ($name in $Metrics.functions.Keys) {
        $key = "worker.$name"
        if (-not $record.functions.ContainsKey($key)) { $record.functions[$key] = @{ count = 0; ticks = [long]0; selfTicks = [long]0 } }
        $record.functions[$key].count += $Metrics.functions[$name].count
        $record.functions[$key].ticks += $Metrics.functions[$name].ticks
        $record.functions[$key].selfTicks += $Metrics.functions[$name].selfTicks
    }
}

function Prefetch-EmployeeFileText {
    param([string[]]$Paths)
    $concurrency = Get-EmployeeFileReadConcurrency
    if ($concurrency -eq 1) { return }
    $cold = @($Paths | Where-Object {
        $metadata = $script:FileMetadataCache[$_].Metadata
        $text = $script:TextFileCache[$_]
        (Get-HeldResourceLockCount $_) -eq 0 -and
            ($null -eq $text -or $null -eq $metadata -or $text.LastWriteTicks -ne $metadata.LastWriteTicks -or $text.Length -ne $metadata.Length)
    })
    # Leave incremental refreshes on their existing fast path. No pool creation
    # for one changed employee or an already-populated file cache.
    if ($cold.Count -lt 8) { return }
    $pool = $null; $jobs = New-Object Collections.ArrayList
    $results = New-Object Collections.ArrayList
    $span = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name "EmployeeFileReadService.Prefetch" -Component "EmployeeFileReadService" -Type "workflow" -Fields @{ workerLimit = $concurrency; workerCount = $cold.Count } } else { $null }
    $prefetchStatus = "success"; $prefetchFailure = $null
    try {
        $pool = if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Runspaces.CreatePool" -Component "Runspaces" -Type "infrastructure" -Action { [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $concurrency) } } else { [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $concurrency) }
        if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Runspaces.OpenPool" -Component "Runspaces" -Type "infrastructure" -Action { $pool.Open() } } else { $pool.Open() }
        $workerPath = Join-Path $PSScriptRoot "EmployeeFileReadWorker.ps1"
        $worker = if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Runspaces.ReadWorkerSource" -Path $workerPath -Action { [IO.File]::ReadAllText($workerPath) } } else { [IO.File]::ReadAllText($workerPath) }
        $backendRoot = Split-Path $PSScriptRoot -Parent
        # At most concurrency PowerShell invocations exist at a time, not one
        # pending invocation/runspace per employee. Merge in original path order.
        for ($offset = 0; $offset -lt $cold.Count; $offset += $concurrency) {
            $batchSpan = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name "Runspaces.ReadBatch" -Component "Runspaces" -Type "worker" } else { $null }
            $jobs.Clear()
            for ($index = $offset; $index -lt [Math]::Min($cold.Count, $offset + $concurrency); $index++) {
                $path = $cold[$index]; $entry = $script:FileMetadataCache[$path]
                $metadata = if ($entry -and $entry.Metadata) { $entry.Metadata.PSObject.Copy() } else { $null }
                $validated = if ($entry) { $entry.ValidatedAtUtc } else { [DateTime]::MinValue }
                $shell = if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Runspaces.CreateInvocation" -Component "Runspaces" -Type "infrastructure" -Action { [Management.Automation.PowerShell]::Create() } } else { [Management.Automation.PowerShell]::Create() }
                $shell.RunspacePool = $pool
                [void]$shell.AddScript($worker).AddArgument($path).AddArgument([string]$sharedFolder).AddArgument($backendRoot).AddArgument($metadata).AddArgument($validated).AddArgument([int]$script:SharedDataReadRetryCount).AddArgument([int]$script:SharedDataRetryDelayMs).AddArgument([bool]$script:SaphirPerformanceEnabled)
                if ($span) { [void]$shell.AddArgument((Get-SaphirPerformanceWorkerContext -Parent $batchSpan -Index $index -Path $path)) }
                try {
                    $handle = if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Runspaces.ScheduleWorker" -Component "Runspaces" -Type "infrastructure" -Path $path -Action { $shell.BeginInvoke() } } else { $shell.BeginInvoke() }
                }
                catch { $shell.Dispose(); throw }
                [void]$jobs.Add([PSCustomObject]@{ shell = $shell; handle = $handle })
            }
            foreach ($job in $jobs) {
                # Wrap the entire conditional: arrays inside its branches are
                # enumerated again by if. A single PSCustomObject has no Count
                # in Windows PowerShell 5.1 and would be rejected as a failure.
                $output = @(if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Runspaces.CollectWorker" -Component "Runspaces" -Type "wait" -Action { $job.shell.EndInvoke($job.handle) } } else { $job.shell.EndInvoke($job.handle) })
                # HadErrors also records handled Get-Item misses/retries; the
                # worker returns an explicit terminal failure after FileStore.
                if ($output.Count -ne 1) {
                    throw [InvalidOperationException]::new("Employee read worker returned $($output.Count) results: $(@($job.shell.Streams.Error) -join '; ')")
                }
                $result = $output[0]
                Merge-EmployeeFileReadMetrics $result.metrics
                if ($null -ne $result.failure) { throw $result.failure }
                [void]$results.Add($result)
            }
            $disposeSpan = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name "Runspaces.DisposeInvocations" -Component "Runspaces" -Type "infrastructure" } else { $null }
            foreach ($job in $jobs) { $job.shell.Dispose() }
            if ($disposeSpan) { Stop-SaphirPerformanceSpan $disposeSpan }
            $jobs.Clear()
            if ($batchSpan) { Stop-SaphirPerformanceSpan $batchSpan }
        }
        # Publish raw cache observations ONLY after every worker succeeded.
        # JSON validation, normalization, projections and registration still
        # happen on the HTTP runspace. Writer reads never use this preloader.
        $mergeSpan = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name "Runspaces.MergeResults" -Component "Runspaces" -Type "infrastructure" } else { $null }
        foreach ($result in $results) {
            if ($null -eq $result.metadata) { Clear-CachedFileContent -Path $result.path; continue }
            $script:FileMetadataCache[$result.path] = [PSCustomObject]@{ Metadata = $result.metadata; ValidatedAtUtc = $result.validatedAtUtc }
            $script:TextFileCache[$result.path] = [PSCustomObject]@{ LastWriteTicks = $result.metadata.LastWriteTicks; Length = $result.metadata.Length; Content = $result.content }
        }
        if ($mergeSpan) { Stop-SaphirPerformanceSpan $mergeSpan }
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.employee-prefetch.completed" }
    } catch { $prefetchStatus = "error"; $prefetchFailure = $_; throw }
    finally {
        foreach ($job in $jobs) {
            try { if (-not $job.handle.IsCompleted) { $job.shell.Stop() } } finally { $job.shell.Dispose() }
        }
        if ($pool) {
            if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Runspaces.DisposePool" -Component "Runspaces" -Type "infrastructure" -Action { $pool.Close(); $pool.Dispose() } }
            else { $pool.Close(); $pool.Dispose() }
        }
        if ($span) { Stop-SaphirPerformanceSpan -Frame $span -Status $prefetchStatus -ErrorRecord $prefetchFailure }
    }
}
