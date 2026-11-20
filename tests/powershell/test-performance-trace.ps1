$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$oldFlag = $env:SAPHIR_PERF_TRACE
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("saphir-trace-{0}" -f [Guid]::NewGuid().ToString("N"))
try {
    $env:SAPHIR_PERF_TRACE = "1"
    . (Join-Path $root "app/backend/lib/PerformanceTrace.ps1")
    $script:sharedFolder = $fixture
    $script:lockFolder = Join-Path $fixture ".locks"
    . (Join-Path $root "app/backend/lib/FileStore.ps1")
    New-Item -ItemType Directory -Path $fixture | Out-Null
    function Get-TraceConstant { return "unchanged" }
    Register-SaphirPerformanceFunctions -Names @("Get-TraceConstant")
    Start-SaphirPerformanceTrace -Name "GET /employee/123456789"
    if ((Get-TraceConstant) -ne "unchanged") { throw "Tracing changed a parameterless function's return value." }
    $path = Join-Path $fixture "secret.json"
    $lock = Acquire-ResourceLock -ResourcePath $path
    try { Write-JsonArrayAtomic -Path $path -Items @([PSCustomObject]@{ privateValue = "secret-test-value" }) }
    finally { Release-ResourceLock -LockHandle $lock }
    $first = @(Read-JsonArrayFile -Path $path)
    $second = @(Read-JsonArrayFile -Path $path)
    if ($first.Count -ne 1 -or $second[0].privateValue -ne "secret-test-value") { throw "Tracing changed collection semantics." }
    $logged = @(Stop-SaphirPerformanceTrace -StatusCode 200 6>&1) -join ""
    if ($logged -match 'secret-test-value|123456789|secret.json|password|tokenHash') { throw "Trace exposed private data." }
    $trace = $logged.Substring($logged.IndexOf("SAPHIR_PERF ") + 12) | ConvertFrom-Json
    if ($trace.operations.'fs.shared.read' -ne 1 -or $trace.operations.'cache.text.hit' -ne 1) { throw "Read/cache counters are incorrect." }
    if ($trace.operations.'fs.shared.write-temp' -ne 1 -or $trace.functions.'Acquire-ResourceLock'.count -ne 1) { throw "Write/lock counters are incorrect." }
    if ($trace.functions.'Read-JsonArrayFile'.count -ne 2 -or $trace.totalMs -lt 0) { throw "Function timings are incorrect." }
    if ($trace.functions.'Get-TraceConstant'.count -ne 1) { throw "Parameterless function was not timed." }
    Start-SaphirPerformanceTrace -Name "long-counter"
    $longSpan = Start-SaphirPerformanceSpan -Name "long-counter"
    $longSpan.start = [Diagnostics.Stopwatch]::GetTimestamp() - [long]3000000000
    Stop-SaphirPerformanceSpan -Frame $longSpan
    if ($script:SaphirPerformanceRecord.functions.'long-counter'.selfTicks -lt [long]3000000000) { throw "Long spans overflowed their Int64 counters." }
    Stop-SaphirPerformanceTrace -StatusCode 200 6>&1 | Out-Null
    $env:SAPHIR_PERF_TRACE = "0"
    . (Join-Path $root "app/backend/lib/PerformanceTrace.ps1")
    Start-SaphirPerformanceTrace -Name "disabled"
    if (@(Stop-SaphirPerformanceTrace 6>&1).Count -ne 0) { throw "Disabled tracing produced output." }
    Write-Host "Performance tracing passed: opt-in counters/timings, collection semantics and privacy."
} finally {
    $env:SAPHIR_PERF_TRACE = $oldFlag
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
