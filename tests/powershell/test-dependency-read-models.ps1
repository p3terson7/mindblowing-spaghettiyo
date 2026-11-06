param([switch]$Isolated)
$ErrorActionPreference = "Stop"
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw "Dependency read-model subprocess failed." }
    return
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("cache-coherence-" + [Guid]::NewGuid().ToString("N"))
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert-Coherence($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expire-CoherenceSourceObservations {
    foreach ($entry in @($script:FileMetadataCache.Values)) {
        if ($entry.Metadata -and $entry.Metadata.ObservedAtUtc) { $entry.Metadata.ObservedAtUtc = [DateTime]::UtcNow.AddMinutes(-1) }
    }
}
try {
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $fixture -Create
    $manager = Get-UserByUsername "audit-super"
    $limited = Get-UserByUsername "audit-limited"
    $first = Get-DashboardBootstrapModel -CurrentUser $manager
    $snapshot = Get-EmployeeDataSnapshot
    $other = @($snapshot.flattenedEntries | Where-Object employeeCode -eq "000710002")[0]
    $directoryBefore = @(Get-EmployeeDirectoryList -CurrentUser $manager)
    Publish-DataChange -Category "bug-reports" -Resource "issue" | Out-Null
    $second = Get-DashboardBootstrapModel -CurrentUser $manager
    Assert-Coherence ([object]::ReferenceEquals($first.selectedEmployeeEntries, $second.selectedEmployeeEntries)) "A ticket edit discarded the dashboard's employee contribution."
    Assert-Coherence ([object]::ReferenceEquals($snapshot, (Get-EmployeeDataSnapshot))) "A ticket edit rebuilt the employee snapshot."
    $directoryAfter = @(Get-EmployeeDirectoryList -CurrentUser $manager)
    Assert-Coherence ([object]::ReferenceEquals($directoryBefore[0], $directoryAfter[0])) "A ticket edit rebuilt Personnel rows."
    Publish-DataChange -Category "compensation" -Resource "shared" | Out-Null
    Assert-Coherence ([object]::ReferenceEquals($snapshot, (Get-EmployeeDataSnapshot))) "A compensation update invalidated nonmonetary data."
    $scopedBeforeProject = Get-ScopedEmployeeDataSnapshot -CurrentUser $limited
    Publish-DataChange -Category "project" -Resource "P1" | Out-Null
    Assert-Coherence ([object]::ReferenceEquals($snapshot, (Get-EmployeeDataSnapshot))) "A catalog change discarded independent employee contributions."
    Assert-Coherence (-not [object]::ReferenceEquals($scopedBeforeProject, (Get-ScopedEmployeeDataSnapshot -CurrentUser $limited))) "A catalog/assignment change preserved an authorization-sensitive projection."
    $money = Get-EmployeeDataSnapshot -IncludeMonetary
    Publish-DataChange -Category "compensation" -Resource "shared" | Out-Null
    Assert-Coherence (-not [object]::ReferenceEquals($money, (Get-EmployeeDataSnapshot -IncludeMonetary))) "Compensation-dependent data stayed stale."
    $personnelOther = @(Get-EmployeeDirectoryList -CurrentUser $manager | Where-Object code -eq "000710002")[0]

    # A child powershell is another workstation/cache owner, not a runspace.
    $worker = Join-Path $repo "tests/lib/CacheCoherenceWorker.ps1"
    foreach ($operation in @("modify", "add", "approve", "reject", "reassign", "delete")) {
        & (Get-Command pwsh).Source -NoProfile -File $worker -FixtureFolder $fixture -Operation $operation
        Assert-Coherence ($LASTEXITCODE -eq 0) "Remote mutation failed."
        Clear-SyncStateCache
        $incremental = Get-EmployeeDataSnapshot
        $unchanged = @($incremental.flattenedEntries | Where-Object employeeCode -eq "000710002")[0]
        Assert-Coherence ([object]::ReferenceEquals($other, $unchanged)) "$operation recomputed an unrelated employee."
        $personnelCurrent = @(Get-EmployeeDirectoryList -CurrentUser $manager | Where-Object code -eq "000710002")[0]
        Assert-Coherence ([object]::ReferenceEquals($personnelOther.projectStats[0], $personnelCurrent.projectStats[0])) "$operation recalculated independent Personnel statistics."
        $expected = @(foreach ($user in @(Get-Users | Where-Object employeeCode)) {
            foreach ($entry in @(Read-JsonArrayFile (Join-Path $fixture "$($user.employeeCode)_data.json"))) {
                New-EmployeeEntryProjection -EmployeeCode $user.employeeCode -EmployeeName $user.displayName -Entry $entry -EmployeeRole $user.role
            }
        })
        $a = ConvertTo-Json -InputObject @($incremental.flattenedEntries | Sort-Object employeeCode, entryId) -Depth 12 -Compress
        $b = ConvertTo-Json -InputObject @($expected | Sort-Object employeeCode, entryId) -Depth 12 -Compress
        Assert-Coherence ($a -ceq $b) "$operation incremental projection differs from fresh reconstruction."
        $statistics = Get-ProjectStatisticsOverview -CurrentUser $manager
        foreach ($project in @("P1", "P2")) {
            $approved = @($expected | Where-Object { $_.projectCode -eq $project -and $_.status -eq "approved" })
            $seconds = [long]0
            foreach ($entry in $approved) { $seconds += Get-OvertimeSecondsFromText $entry.overtime }
            $actual = if ($statistics.ContainsKey($project)) { [long]$statistics[$project].totalSeconds } else { [long]0 }
            Assert-Coherence ($actual -eq $seconds) "$operation project totals diverged from reconstruction."
        }
        $scoped = Get-ScopedEmployeeDataSnapshot -CurrentUser $limited
        # Current business rules let admins VIEW all projects but MODIFY only
        # their assignments. Do not accidentally narrow this during caching.
        Assert-Coherence (@($scoped.flattenedEntries | Where-Object { $_.projectCode -eq "P2" -and $_.canModify }).Count -eq 0) "Scoped cache reused super-admin modification permissions."
        Assert-Coherence (@((Get-ScopedEmployeeDataSnapshot -CurrentUser (Get-UserByUsername "000710002")).flattenedEntries).Count -eq 0) "Employee identity reused a manager projection."
    }
    $before = Get-EmployeeDataSnapshot
    Invoke-CoherenceFixtureMutation -Code "000710001" -Operation modify
    Invoke-CoherenceFixtureMutation -Code "000710002" -Operation modify
    Publish-DataChange -Category "bug-reports" -Resource "gap" | Out-Null
    $after = Get-EmployeeDataSnapshot
    $thirdBefore = @($before.flattenedEntries | Where-Object employeeCode -eq "000710003")[0]
    $thirdAfter = @($after.flattenedEntries | Where-Object employeeCode -eq "000710003")[0]
    Assert-Coherence ([object]::ReferenceEquals($thirdBefore, $thirdAfter)) "A complete cumulative vector lost an unchanged employee across categories."
    Disable-EmployeeUser -EmployeeCode "000710003" | Out-Null
    Publish-DataChange -Category "employee-directory" -Resource "000710003" | Out-Null
    Assert-Coherence (@((Get-EmployeeDataSnapshot).employees | Where-Object code -eq "000710003").Count -eq 0) "Deleted/disabled employee remained in the active snapshot."
    Restore-EmployeeUser -EmployeeCode "000710003" | Out-Null
    Publish-DataChange -Category "employee-directory" -Resource "000710003" | Out-Null
    Assert-Coherence (@((Get-EmployeeDataSnapshot).employees | Where-Object code -eq "000710003").Count -eq 1) "Restored employee remained hidden by a cache."

    # Commit succeeds with no revision: metadata fallback, then equal-metadata
    # external writes: forced content reconciliation. No mutation is repeated.
    $oldVersion = (Get-SyncState).version
    & (Get-Command pwsh).Source -NoProfile -File $worker -FixtureFolder $fixture -Operation add -WithoutPublication
    $script:ReadModelReconciledUtc = [DateTime]::UtcNow.AddMinutes(-1)
    Expire-CoherenceSourceObservations
    $afterFailure = Get-EmployeeDataSnapshot
    Assert-Coherence ($afterFailure.flattenedEntries.Count -eq $after.flattenedEntries.Count + 1) "Fallback missed a committed but unpublished mutation."
    Assert-Coherence ((Get-SyncState).version -eq $oldVersion) "Reconciliation republished or repeated a business mutation."
    $path = Join-Path $fixture "000710001_data.json"
    $timestamp = [IO.File]::GetLastWriteTimeUtc($path)
    $raw = [IO.File]::ReadAllText($path)
    [IO.File]::WriteAllText($path, $raw.Replace('02:00:00', '03:00:00'))
    [IO.File]::SetLastWriteTimeUtc($path, $timestamp)
    $script:ReadModelContentReconciledUtc = [DateTime]::UtcNow.AddMinutes(-6)
    $external = Get-EmployeeDataSnapshot
    Assert-Coherence (@($external.flattenedEntries | Where-Object overtime -eq "03:00:00").Count -gt 0) "Equal-metadata external changes were missed."

    # Session publication and fallback both invalidate the auth source; scopes
    # stay cached only while their requesting identity is still authorized.
    $token = New-SessionForUser $limited
    $request = [PSCustomObject]@{ Headers = @{ Authorization = "Bearer $token" } }
    Assert-Coherence ($null -ne (Get-AuthenticatedUserFromRequest $request)) "Session was not authenticated."
    & (Get-Command pwsh).Source -NoProfile -File $worker -FixtureFolder $fixture -Operation revoke
    Clear-SyncStateCache; Sync-ReadModelCaches
    Assert-Coherence ($null -eq (Get-AuthenticatedUserFromRequest $request)) "Revoked session remained authorized across processes."
    $token = New-SessionForUser $limited
    $request.Headers.Authorization = "Bearer $token"
    Get-AuthenticatedUserFromRequest $request | Out-Null
    & (Get-Command pwsh).Source -NoProfile -File $worker -FixtureFolder $fixture -Operation failed-revoke
    $script:ReadModelReconciledUtc = [DateTime]::UtcNow.AddMinutes(-1)
    Expire-CoherenceSourceObservations
    Sync-ReadModelCaches
    Assert-Coherence ($null -eq (Get-AuthenticatedUserFromRequest $request)) "Failed revocation publication survived source reconciliation."
    $token = New-SessionForUser $limited
    $request.Headers.Authorization = "Bearer $token"
    Get-AuthenticatedUserFromRequest $request | Out-Null
    & (Get-Command pwsh).Source -NoProfile -File $worker -FixtureFolder $fixture -Operation disable -WithoutPublication
    $script:ReadModelReconciledUtc = [DateTime]::UtcNow.AddMinutes(-1)
    Expire-CoherenceSourceObservations
    Sync-ReadModelCaches
    Assert-Coherence ($null -eq (Get-AuthenticatedUserFromRequest $request)) "Unpublished account disabling survived reconciliation."

    # Network/read failure and reconnect with the SAME revision force reset.
    $originalRead = ${function:Read-SyncStateFromDisk}
    function Read-SyncStateFromDisk { param([bool]$ThrowOnError) throw "simulated network interruption" }
    Clear-SyncStateCache; Sync-ReadModelCaches
    Assert-Coherence ($script:ReadModelCache.Count -eq 0) "Network failure retained dependency models."
    ${function:Read-SyncStateFromDisk} = $originalRead
    Clear-SyncStateCache; Sync-ReadModelCaches
    Assert-Coherence (-not $script:ReadModelSyncReadFailed) "Reconnect did not reset the failure state."
    Write-Host "Dependency models passed: selective/transitive invalidation, remote entry mutations, reconstruction equivalence, scope isolation, partial commits, external writes, session revocation and reconnect."
} finally { if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
