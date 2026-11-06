param([switch]$Isolated)
$ErrorActionPreference = "Stop"
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw "Prefetch subprocess failed." }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("prefetch-test-" + [Guid]::NewGuid().ToString("N"))
$oldConcurrency = $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY
function Assert-Prefetch($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $fixture -Create -EmployeeCount 12
    . (Join-Path $repo "app/backend/services/EmployeeFileReadService.ps1")
    # Exercise the actual collector assignment, not a copy of its expression.
    # PS7 gives scalar PSCustomObjects a synthetic Count=1; an explicit null
    # Count reproduces the Windows PowerShell 5.1 behavior on every test host.
    $collectorAssignments = @((Get-Command Prefetch-EmployeeFileText).ScriptBlock.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq "output"
    }, $true))
    Assert-Prefetch ($collectorAssignments.Count -eq 1) "Worker collector assignment was not found."
    $collectWorker = [scriptblock]::Create($collectorAssignments[0].Extent.Text)
    $originalTracing = $script:SaphirPerformanceEnabled
    try {
        foreach ($tracing in @($false, $true)) {
            $script:SaphirPerformanceEnabled = $tracing
            foreach ($resultCount in @(1, 0, 2)) {
                $results = @(for ($index = 0; $index -lt $resultCount; $index++) {
                    [PSCustomObject]@{ path = "synthetic-worker-$index"; Count = $null }
                })
                $fakeShell = [PSCustomObject]@{ Results = $results }
                $fakeShell | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value { param($handle) return $this.Results }
                $job = [PSCustomObject]@{ shell = $fakeShell; handle = $null }
                . $collectWorker
                Assert-Prefetch ($output -is [array]) "Worker results were unwrapped (tracing=$tracing, results=$resultCount)."
                Assert-Prefetch ($output.Count -eq $resultCount) "Worker result count changed (tracing=$tracing, results=$resultCount)."
                if ($resultCount -eq 1) {
                    Assert-Prefetch ($null -eq $output[0].Count -and $output[0].path -eq "synthetic-worker-0") "Collector changed the worker result instead of preserving its array."
                }
            }
        }
    } finally { $script:SaphirPerformanceEnabled = $originalTracing }
    $paths = @(1..12 | ForEach-Object { Join-Path $fixture ("{0:000000000}_data.json" -f (710000 + $_)) })
    $script:TextFileCache = @{}; $script:FileMetadataCache = @{}
    Prime-EmployeeFileMetadata $paths
    $originalStamp = $script:FileMetadataCache[$paths[0]].Metadata
    $observed = $originalStamp.ObservedAtUtc
    $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = "1"
    Prefetch-EmployeeFileText $paths
    Assert-Prefetch ($script:TextFileCache.Count -eq 0) "Sequential mode created workers or prefetched data."
    foreach ($level in @(2, 4, 8)) {
        $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = [string]$level
        $script:TextFileCache = @{}
        Prefetch-EmployeeFileText $paths
        Assert-Prefetch ($script:TextFileCache.Count -eq 12) "Prefetch failed to load every independent file at level $level."
        foreach ($path in $paths) {
            Assert-Prefetch ($script:TextFileCache[$path].Content -ceq [IO.File]::ReadAllText($path)) "Prefetch content diverged from source."
            Assert-Prefetch ($script:TextFileCache[$path].LastWriteTicks -eq $script:FileMetadataCache[$path].Metadata.LastWriteTicks) "Text cache/stamp diverged."
        }
        Assert-Prefetch ($originalStamp.ObservedAtUtc -eq $observed) "A worker mutated its parent's metadata object."
        Assert-Prefetch ($script:ReadModelCache.Count -eq 0 -and $script:ReadModelDependencies.Count -eq 0) "Worker/controller registered models outside the owning factory."
    }
    $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = "9999"
    Assert-Prefetch ((Get-EmployeeFileReadConcurrency) -in @(1, 4, 8)) "An invalid setting allowed unbounded workers."

    # All-or-nothing raw cache publication on terminal I/O failure. No actual
    # share is disconnected; this is only our owned temporary fixture root.
    $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = "4"
    $script:TextFileCache = @{}
    $script:SharedDataReadRetryCount = 1; $script:SharedDataRetryDelayMs = 1
    $offline = $fixture + ".offline"
    [IO.Directory]::Move($fixture, $offline)
    try {
        $failed = $false
        try { Prefetch-EmployeeFileText $paths } catch { $failed = $true }
        Assert-Prefetch ($failed -and $script:TextFileCache.Count -eq 0) "Failed workers published a partial raw cache or hid the outage."
    } finally { [IO.Directory]::Move($offline, $fixture) }
    Prefetch-EmployeeFileText $paths
    Assert-Prefetch ($script:TextFileCache.Count -eq 12) "Prefetch failed to recover after reconnect."

    # Once files are cached, changes still use fresh reads under writer locks.
    $path = $paths[0]
    $old = [IO.File]::ReadAllText($path)
    $lock = Acquire-ResourceLock $path
    try {
        $fresh = $old.Replace("01:00:00", "02:00:00")
        [IO.File]::WriteAllText($path, $fresh)
        Assert-Prefetch ((Read-TextFileCached $path) -ceq $fresh) "A writer consumed prefetched/stale bytes under its lock."
    } finally { Release-ResourceLock $lock }
    Write-Host "Prefetch passed: bounded levels, exact bytes/stamps, detached metadata, no model registration, failed I/O atomic publication, reconnect and fresh writer-lock reads."
} finally {
    $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = $oldConcurrency
    if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
