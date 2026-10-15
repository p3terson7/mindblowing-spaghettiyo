param([string]$Path, [string]$DataRoot, [string]$BackendRoot, $Metadata, [DateTime]$ValidatedAtUtc, [int]$RetryCount, [int]$RetryDelayMs, [bool]$Tracing, $TraceContext = $null)
$ErrorActionPreference = "Stop"
$workerEntryTicks = if ($Tracing) { [Diagnostics.Stopwatch]::GetTimestamp() } else { [long]0 }
$workerEntryUtc = if ($Tracing) { [DateTime]::UtcNow.ToString("o") } else { "" }
if (-not (Test-Path Function:\Read-TextFileCached)) {
    . (Join-Path $BackendRoot "lib/PerformanceTrace.ps1")
    $script:SaphirPerformanceEnabled = $Tracing
}
$script:sharedFolder = $DataRoot
if ($Tracing -and $TraceContext) { Start-SaphirPerformanceWorker -Context $TraceContext -Path $Path -EntryTicks $workerEntryTicks -EntryUtc $workerEntryUtc }
if (-not (Test-Path Function:\Read-TextFileCached)) {
    $loadSpan = if ($Tracing -and $TraceContext) { Start-SaphirPerformanceSpan -Name "Worker.LoadFileStore" -Component "Runspaces" -Type "infrastructure" } else { $null }
    try { . (Join-Path $BackendRoot "lib/FileStore.ps1") }
    finally { if ($loadSpan) { Stop-SaphirPerformanceSpan $loadSpan } }
}
# This runspace receives only path/scalar metadata, never users, permissions,
# normalized entries, parent hashtables, cache frames, or dependency registries.
$script:sharedFolder = $DataRoot
$script:SharedDataReadRetryCount = $RetryCount
$script:SharedDataRetryDelayMs = $RetryDelayMs
$script:TextFileCache = @{}; $script:BinaryFileCache = @{}; $script:FileMetadataCache = @{}
$script:HeldResourceLocks = @{}
if ($null -ne $Metadata) {
    $script:FileMetadataCache[$Path] = [PSCustomObject]@{ Metadata = $Metadata; ValidatedAtUtc = $ValidatedAtUtc }
}
if (-not $TraceContext) { $script:SaphirPerformanceRecord = $null }
$failure = $null; $content = $null
try { $content = Read-TextFileCached -Path $Path }
catch { $failure = $_.Exception }
if ($script:SaphirPerformanceRecord -and $script:SaphirPerformanceRecord.workerRoot) {
    if ($failure) { $script:SaphirPerformanceRecord.workerRoot.fields.errorCategory = $failure.GetType().FullName }
    Stop-SaphirPerformanceSpan $script:SaphirPerformanceRecord.workerRoot -Status $(if ($failure -is [OperationCanceledException] -or $failure -is [Management.Automation.PipelineStoppedException]) { "cancelled" } elseif ($failure) { "error" } else { "success" })
    Write-SaphirPerformanceEvent "worker_event" $null @{ workerIndex = $TraceContext.workerIndex; reason = "completed"; status = if ($failure) { "error" } else { "success" } }
}
$entry = $script:FileMetadataCache[$Path]
return [PSCustomObject]@{
    path = $Path; content = $content; failure = $failure
    metadata = if ($entry) { $entry.Metadata } else { $null }
    validatedAtUtc = if ($entry) { $entry.ValidatedAtUtc } else { [DateTime]::MinValue }
    metrics = $script:SaphirPerformanceRecord
}
