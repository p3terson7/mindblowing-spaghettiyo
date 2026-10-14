param([switch]$Isolated, [string]$ApplicationRoot = "")
$ErrorActionPreference = "Stop"
if (-not $Isolated) {
    $childArguments = @("-NoProfile", "-File", $PSCommandPath, "-Isolated")
    if ($ApplicationRoot) { $childArguments += @("-ApplicationRoot", $ApplicationRoot) }
    & (Get-Process -Id $PID).Path @childArguments
    if ($LASTEXITCODE -ne 0) { throw "Cold dashboard subprocess failed." }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("cold-dashboard-test-" + [Guid]::NewGuid().ToString("N"))
$oldConcurrency = $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY
$oldCapacity = $env:SAPHIR_READ_MODEL_CACHE_CAPACITY
function Assert-Cold($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reset-ColdCaches {
    Remove-DependentReadModels
    Clear-AllEmployeeEntryCaches
    Clear-AllReadModelCoreFileCaches
    $script:TextFileCache = @{}; $script:FileMetadataCache = @{}
    $script:ReadModelSourceStamps = @{}
    $script:ReadModelReconciledUtc = [DateTime]::UtcNow
    $script:ReadModelContentReconciledUtc = [DateTime]::UtcNow
}
try {
    $env:SAPHIR_READ_MODEL_CACHE_CAPACITY = "2048"
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $fixture -Create -EmployeeCount 32 -ApplicationRoot $ApplicationRoot
    $manager = Get-UserByUsername "audit-super"
    $admin = Get-UserByUsername "audit-limited"
    $expected = ""
    foreach ($level in @(1, 2, 4, 8)) {
        $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = [string]$level
        Reset-ColdCaches
        $result = Get-DashboardBootstrapModel -CurrentUser $manager
        Assert-Cold ($result.trackedEmployees -eq 32 -and $result.pendingApprovals -eq 32 -and $result.totalOvertime -eq "32:00:00") "Cold totals changed at concurrency $level : employees=$($result.trackedEmployees), pending=$($result.pendingApprovals), hours=$($result.totalOvertime)."
        Assert-Cold ($result.pendingQueue.Count -eq 6 -and $result.activeSessions.Count -eq 0 -and $result.selectedEmployeeEntries.Count -eq 1) "Cold queues/selected employee changed."
        $serialized = ConvertTo-Json -InputObject $result -Depth 12 -Compress
        if ($expected) { Assert-Cold ($expected -ceq $serialized) "Parallel DTO differs from sequential projection at level $level." }
        $expected = $serialized
        $warm = Get-DashboardBootstrapModel -CurrentUser $manager
        Assert-Cold ([object]::ReferenceEquals($result.selectedEmployeeEntries, $warm.selectedEmployeeEntries)) "A cold load was not cached."
        $scoped = Get-ScopedEmployeeDataSnapshot -CurrentUser $admin
        Assert-Cold (@($scoped.flattenedEntries | Where-Object { $_.projectCode -eq "P2" -and $_.canModify }).Count -eq 0) "Parallel loading widened admin modification scope."
        $employee = Get-UserByUsername "000710002"
        Assert-Cold (@((Get-ScopedEmployeeDataSnapshot -CurrentUser $employee).flattenedEntries).Count -eq 0) "Employee reused manager projections."
        Assert-Cold ($script:ReadModelCache.Count -eq $script:ReadModelDependencies.Count) "Cold cache and dependency registry diverged."

        # Separate cache owner/OS process, not another worker sharing state.
        $unchanged = @((Get-EmployeeDataSnapshot).flattenedEntries | Where-Object employeeCode -eq "000710002")[0]
        & (Get-Command pwsh).Source -NoProfile -File (Join-Path $repo "tests/lib/CacheCoherenceWorker.ps1") -FixtureFolder $fixture -Operation modify | Out-Null
        Assert-Cold ($LASTEXITCODE -eq 0) "Remote mutation failed."
        Clear-SyncStateCache
        $changed = Get-DashboardBootstrapModel -CurrentUser $manager
        Assert-Cold ($changed.totalOvertime -eq "33:00:00") "Remote mutation stayed stale after cold loading."
        $current = @((Get-EmployeeDataSnapshot).flattenedEntries | Where-Object employeeCode -eq "000710002")[0]
        Assert-Cold ([object]::ReferenceEquals($unchanged, $current)) "Remote change discarded unrelated contributions."
        $path = Join-Path $fixture "000710001_data.json"
        $entries = @(Read-JsonArrayFile $path); $entries[0].overtime = "01:00:00"
        Write-CoherenceFixtureJson $path $entries
        Publish-DataChange -Category employee -Resource "000710001" | Out-Null
    }

    # Orphans cannot bypass users/permissions, even when metadata is batched.
    Write-CoherenceFixtureJson (Join-Path $fixture "000711111_data.json") @([PSCustomObject]@{ overtime = "99:00:00" })
    Reset-ColdCaches
    Assert-Cold ((Get-DashboardBootstrapModel -CurrentUser $manager).trackedEmployees -eq 32) "An orphan file became a dashboard employee."
    $missing = Join-Path $fixture "000710002_data.json"
    [IO.File]::Move($missing, "$missing.saved")
    Reset-ColdCaches
    $without = Get-DashboardBootstrapModel -CurrentUser $manager
    Assert-Cold ($without.pendingApprovals -eq 31 -and $without.trackedEmployees -eq 31) "Missing employee file changed optional-file semantics: pending=$($without.pendingApprovals), employees=$($without.trackedEmployees)."
    [IO.File]::Move("$missing.saved", $missing)
    $corrupt = Join-Path $fixture "000710003_data.json"
    $original = [IO.File]::ReadAllText($corrupt)
    [IO.File]::WriteAllText($corrupt, "{invalid-json")
    Reset-ColdCaches
    $failed = $false
    try { Get-DashboardBootstrapModel -CurrentUser $manager | Out-Null } catch { $failed = $true }
    Assert-Cold ($failed) "Corrupt employee data was served as empty data."
    Assert-Cold ([IO.File]::ReadAllText($corrupt) -eq "{invalid-json") "Read path repaired/overwrote corrupt business data."
    Assert-Cold ($script:ReadModelFactoryDepth -eq 0 -and $script:ReadModelDependencyFrames.Count -eq 0) "Partial failure leaked in-flight cache state."
    [IO.File]::WriteAllText($corrupt, $original)
    Reset-ColdCaches
    Assert-Cold ((Get-DashboardBootstrapModel -CurrentUser $manager).pendingApprovals -eq 32) "Cold load did not recover after corrupt file repair."
    # Simulate an unreachable DATA root without disconnecting any real share.
    $offline = $fixture + ".offline"
    [IO.Directory]::Move($fixture, $offline)
    try {
        Reset-ColdCaches
        $failed = $false
        try { Get-DashboardBootstrapModel -CurrentUser $manager | Out-Null } catch { $failed = $true }
        Assert-Cold ($failed) "An unavailable DATA root produced a successful empty dashboard."
    } finally { [IO.Directory]::Move($offline, $fixture) }
    Reset-ColdCaches
    Assert-Cold ((Get-DashboardBootstrapModel -CurrentUser $manager).pendingApprovals -eq 32) "Cold dashboard did not recover after DATA root reconnect."
    Write-Host "Cold dashboard passed: empty caches, DTO parity at 1/2/4/8, queues/totals, scope boundaries, remote change, orphan/missing/corrupt files and recovery."
} finally {
    $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = $oldConcurrency
    $env:SAPHIR_READ_MODEL_CACHE_CAPACITY = $oldCapacity
    if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
