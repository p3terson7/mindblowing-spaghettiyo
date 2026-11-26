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
    # Production enters a read-model factory (and reconciles) before prefetch.
    # Match that order so the first sync does not discard the fixture's cache.
    Sync-ReadModelCaches
    $script:TextFileCache = @{}; $script:EmployeeEntryFileCache = @{}
    Prime-EmployeeFileMetadata $paths
    Prefetch-EmployeeFileText $paths -ParseEntries
    Assert-Prefetch ($script:EmployeeEntryFileCache.Count -eq 12) "Existing readers did not publish a parsed file for each employee."
    foreach ($path in $paths) {
        $parsed = $script:EmployeeEntryFileCache[$path]
        $expected = @([IO.File]::ReadAllText($path) | ConvertFrom-Json)
        Assert-Prefetch ($parsed.RawEntries -is [array] -and $parsed.RawEntries.Count -eq 1 -and $null -eq $parsed.Entries) "Worker collapsed a single entry or normalized UI fields."
        Assert-Prefetch ((ConvertTo-Json -InputObject $parsed.RawEntries -Depth 12 -Compress) -ceq (ConvertTo-Json -InputObject $expected -Depth 12 -Compress)) "Worker JSON shape changed after crossing runspaces."
        Assert-Prefetch ($parsed.LastWriteTicks -eq $script:TextFileCache[$path].LastWriteTicks) "Parsed and text cache stamps diverged."
    }
    $readJson = (Get-Command Read-JsonArrayFile).ScriptBlock
    function Read-JsonArrayFile {
        param([string]$Path)
        if ($paths -contains $Path) { throw "A file already parsed by an existing worker was parsed again." }
        & $readJson -Path $Path
    }
    try {
        $reused = @(Get-CachedEmployeeEntriesForFile -DataFile $paths[0] -Raw)
        Assert-Prefetch ($reused.Count -eq 1 -and [object]::ReferenceEquals($reused[0], $script:EmployeeEntryFileCache[$paths[0]].RawEntries[0])) "The HTTP runspace did not reuse the parsed entry."
    } finally { Set-Item Function:Read-JsonArrayFile -Value $readJson }
    # An invalid file in the last batch must not publish earlier successful
    # observations or turn corruption into a successful empty view.
    $corruptPath = $paths[-1]
    $originalContent = [IO.File]::ReadAllText($corruptPath)
    [IO.File]::WriteAllText($corruptPath, "{invalid-json")
    $script:TextFileCache = @{}; $script:EmployeeEntryFileCache = @{}
    Clear-FileMetadataValidationCache -Path $corruptPath
    try {
        $failure = $null
        try { Prefetch-EmployeeFileText $paths -ParseEntries } catch { $failure = $_.Exception }
        Assert-Prefetch ($failure -is [IO.InvalidDataException] -and $script:TextFileCache.Count -eq 0 -and $script:EmployeeEntryFileCache.Count -eq 0) "Invalid JSON was hidden or published a partial batch."
    } finally {
        [IO.File]::WriteAllText($corruptPath, $originalContent)
        Clear-FileMetadataValidationCache -Path $corruptPath
    }
    $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = "9999"
    # Exercise the defaults without needing a mapped drive or Windows on CI.
    function Test-EmployeeDataOnWindowsFixedDrive {
        param([string]$Path)
        return $Path -eq "C:\SAPHIR\DATA"
    }
    $originalSharedFolder = $sharedFolder
    try {
        $sharedFolder = "C:\SAPHIR\DATA"
        Assert-Prefetch ((Get-EmployeeFileReadConcurrency) -eq 1) "Windows fixed-disk data did not default to sequential reads."
        $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = "4"
        Assert-Prefetch ((Get-EmployeeFileReadConcurrency) -eq 4) "An explicit worker setting was ignored on a fixed disk."
        $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = ""
        $sharedFolder = "R:\SAPHIR\DATA"
        Assert-Prefetch ((Get-EmployeeFileReadConcurrency) -eq 8) "Mapped share lost parallel prefetch by default."
    } finally { $sharedFolder = $originalSharedFolder }

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
