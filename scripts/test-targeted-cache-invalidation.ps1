$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-cache-test-{0}" -f ([Guid]::NewGuid().ToString("N")))

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Write-ExternalEmployeeFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Nullable[DateTime]]$LastWriteUtc = $null
    )

    $json = ConvertTo-Json -InputObject @([PSCustomObject]@{ marker = $Marker }) -Compress
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    if ($null -ne $LastWriteUtc) {
        [System.IO.File]::SetLastWriteTimeUtc([string]$Path, [DateTime]$LastWriteUtc)
    }
}

function Get-EmployeeMarker {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $Path)
    if ($entries.Count -eq 0) {
        return ""
    }
    return [string]$entries[0].marker
}

try {
    New-Item -ItemType Directory -Path $tempFolder | Out-Null
    $script:sharedFolder = $tempFolder
    $script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
    $script:syncStateFile = Join-Path -Path $tempFolder -ChildPath "sync-state.json"
    $script:projectsFile = Join-Path -Path $tempFolder -ChildPath "projects.json"
    $script:mappingFile = Join-Path -Path $tempFolder -ChildPath "employeeNames.json"
    $script:usersFile = Join-Path -Path $tempFolder -ChildPath "users.json"
    $script:sessionsFile = Join-Path -Path $tempFolder -ChildPath "sessions.json"
    $script:historyFile = Join-Path -Path $tempFolder -ChildPath "history.json"
    $script:overtimeCodesFile = Join-Path -Path $tempFolder -ChildPath "overtimeCodes.json"
    $script:paymentOptionsFile = Join-Path -Path $tempFolder -ChildPath "paymentOptions.json"
    $script:reasonCodesFile = Join-Path -Path $tempFolder -ChildPath "reasonCodes.json"
    $script:SyncStateWatcherInitialized = $true
    $script:SyncStateValidationIntervalMs = 1

    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/SyncService.ps1")

    foreach ($coreArrayFile in @(
        $script:projectsFile,
        $script:usersFile,
        $script:sessionsFile,
        $script:historyFile,
        $script:overtimeCodesFile,
        $script:paymentOptionsFile,
        $script:reasonCodesFile
    )) {
        [System.IO.File]::WriteAllText($coreArrayFile, "[]", (New-Object System.Text.UTF8Encoding($false)))
    }
    [System.IO.File]::WriteAllText($script:mappingFile, "{}", (New-Object System.Text.UTF8Encoding($false)))

    $script:AuthRuntimeClearCount = 0
    $script:ProjectAccessClearCount = 0
    function Clear-AuthRuntimeCaches {
        $script:AuthRuntimeClearCount++
    }
    function Clear-ProjectAccessRuntimeCaches {
        $script:ProjectAccessClearCount++
    }

    function Convert-ToNormalizedEntryObject {
        param($Entry)
        return $Entry
    }

    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/ReadModelService.ps1")

    $script:OriginalReadJsonArrayFile = ${function:Read-JsonArrayFile}
    $script:EmployeeJsonReadCount = 0
    $script:EmployeeJsonReadsByPath = @{}
    function Read-JsonArrayFile {
        param([Parameter(Mandatory = $true)][string]$Path)

        $script:EmployeeJsonReadCount++
        if (-not $script:EmployeeJsonReadsByPath.ContainsKey($Path)) {
            $script:EmployeeJsonReadsByPath[$Path] = 0
        }
        $script:EmployeeJsonReadsByPath[$Path]++
        return (& $script:OriginalReadJsonArrayFile -Path $Path)
    }

    $employeeCodes = @("000000001", "000000002", "000000003")
    $employeeFiles = @{}
    foreach ($employeeCode in $employeeCodes) {
        $employeeFiles[$employeeCode] = Join-Path -Path $tempFolder -ChildPath ("{0}_data.json" -f $employeeCode)
        Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCode] -Marker "alpha"
        Assert-Equal -Expected "alpha" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCode]) -Message "Initial employee cache load failed."
    }
    Assert-Equal -Expected 3 -Actual $script:EmployeeJsonReadCount -Message "Initial cache priming should parse each employee once."

    $script:OriginalGetSyncState = ${function:Get-SyncState}
    $script:SyncStateReadCount = 0
    function Get-SyncState {
        $script:SyncStateReadCount++
        return (& $script:OriginalGetSyncState)
    }
    $beforeSnapshotSyncReads = $script:SyncStateReadCount
    Invoke-ReadModelCache -Key "sync-once-snapshot-fixture" -Factory {
        foreach ($employeeCode in $employeeCodes) {
            Get-CachedEmployeeEntriesForFile -DataFile $employeeFiles[$employeeCode] | Out-Null
        }
        return $true
    } | Out-Null
    Assert-Equal -Expected 1 -Actual ($script:SyncStateReadCount - $beforeSnapshotSyncReads) -Message "A multi-employee model factory should reconcile sync state only once."

    $publicSyncState = Get-PublicSyncState
    Assert-Equal -Expected 5 -Actual @($publicSyncState.PSObject.Properties).Count -Message "The public sync DTO should contain only client-facing change metadata."
    Assert-True -Condition (-not ($publicSyncState.PSObject.Properties.Name -contains "employeeDataEpoch")) -Message "The public sync DTO exposed the internal employee epoch."
    Assert-True -Condition (-not ($publicSyncState.PSObject.Properties.Name -contains "employeeDataRevisions")) -Message "The public sync DTO exposed employee revision identifiers."

    # A revision must defeat content and metadata caches even when another
    # process preserves both file length and LastWriteTimeUtc.
    $employeeOneTimestamp = (Get-Item -Path $employeeFiles[$employeeCodes[0]]).LastWriteTimeUtc
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[0]] -Marker "bravo" -LastWriteUtc $employeeOneTimestamp
    $beforeTargetedReadCount = $script:EmployeeJsonReadCount
    Publish-DataChange -Category "employee" -Resource $employeeCodes[0] | Out-Null
    Assert-Equal -Expected "alpha" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[1]]) -Message "An unrelated employee cache changed during targeted reconciliation."
    Assert-Equal -Expected "bravo" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]]) -Message "Targeted reconciliation retained stale equal-metadata content."
    Assert-Equal -Expected ($beforeTargetedReadCount + 1) -Actual $script:EmployeeJsonReadCount -Message "A single employee change should reparse exactly one file."

    function Prime-CoreFileCaches {
        foreach ($corePath in @(
            $script:projectsFile,
            $script:mappingFile,
            $script:usersFile,
            $script:sessionsFile,
            $script:historyFile,
            $script:overtimeCodesFile,
            $script:paymentOptionsFile,
            $script:reasonCodesFile
        )) {
            Read-TextFileCached -Path $corePath | Out-Null
        }
    }

    function Assert-CoreFileCached {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][bool]$Expected,
            [Parameter(Mandatory = $true)][string]$Message
        )

        Assert-Equal -Expected $Expected -Actual ([bool]$script:TextFileCache.ContainsKey($Path)) -Message $Message
    }

    # A sequential history publication invalidates history-derived models but
    # keeps unrelated shared-file and authentication caches warm.
    Prime-CoreFileCaches
    $script:AuthRuntimeClearCount = 0
    $script:ProjectAccessClearCount = 0
    $beforeHistoryReadCount = $script:EmployeeJsonReadCount
    Publish-DataChange -Category "history" -Resource "audit" | Out-Null
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected $beforeHistoryReadCount -Actual $script:EmployeeJsonReadCount -Message "History changes should not reparse employee files."
    Assert-CoreFileCached -Path $script:historyFile -Expected:$false -Message "History changes should invalidate history content."
    Assert-CoreFileCached -Path $script:projectsFile -Expected:$true -Message "History changes should preserve the project file cache."
    Assert-CoreFileCached -Path $script:usersFile -Expected:$true -Message "History changes should preserve the users file cache."
    Assert-Equal -Expected 0 -Actual $script:AuthRuntimeClearCount -Message "History changes should preserve authentication runtime caches."
    Assert-Equal -Expected 0 -Actual $script:ProjectAccessClearCount -Message "History changes should preserve project access caches."

    # Project changes clear project/history dependencies but keep users,
    # sessions, employee data and unrelated lookup files warm.
    Prime-CoreFileCaches
    $script:AuthRuntimeClearCount = 0
    $script:ProjectAccessClearCount = 0
    Publish-DataChange -Category "project" -Resource "P001" | Out-Null
    Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]] | Out-Null
    Assert-CoreFileCached -Path $script:projectsFile -Expected:$false -Message "Project changes should invalidate project content."
    Assert-CoreFileCached -Path $script:historyFile -Expected:$false -Message "Coalesced project changes should invalidate audit history."
    Assert-CoreFileCached -Path $script:usersFile -Expected:$true -Message "Project changes should preserve users content."
    Assert-CoreFileCached -Path $script:sessionsFile -Expected:$true -Message "Project changes should preserve sessions content."
    Assert-Equal -Expected 0 -Actual $script:AuthRuntimeClearCount -Message "Project changes should not clear users/session authentication caches."
    Assert-Equal -Expected 1 -Actual $script:ProjectAccessClearCount -Message "Project changes should clear only project access projections."

    # Authentication changes invalidate authentication/history dependencies
    # without throwing away project or employee-file caches.
    Prime-CoreFileCaches
    $script:AuthRuntimeClearCount = 0
    $script:ProjectAccessClearCount = 0
    Publish-DataChange -Category "auth" -Resource $employeeCodes[0] | Out-Null
    Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]] | Out-Null
    Assert-CoreFileCached -Path $script:usersFile -Expected:$false -Message "Auth changes should invalidate users content."
    Assert-CoreFileCached -Path $script:sessionsFile -Expected:$false -Message "Auth changes should invalidate sessions content."
    Assert-CoreFileCached -Path $script:historyFile -Expected:$false -Message "Coalesced auth changes should invalidate audit history."
    Assert-CoreFileCached -Path $script:projectsFile -Expected:$true -Message "Auth changes should preserve project content."
    Assert-Equal -Expected 1 -Actual $script:AuthRuntimeClearCount -Message "Auth changes should clear authentication runtime caches once."

    # If this process misses one or more publications, the last category cannot
    # describe every changed core file. Fall back to a complete core reset.
    Prime-CoreFileCaches
    $script:AuthRuntimeClearCount = 0
    Publish-DataChange -Category "history" -Resource "gap-history" | Out-Null
    Publish-DataChange -Category "project" -Resource "gap-project" | Out-Null
    Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]] | Out-Null
    foreach ($corePath in @(
        $script:projectsFile,
        $script:mappingFile,
        $script:usersFile,
        $script:sessionsFile,
        $script:historyFile,
        $script:overtimeCodesFile,
        $script:paymentOptionsFile,
        $script:reasonCodesFile
    )) {
        Assert-CoreFileCached -Path $corePath -Expected:$false -Message "A skipped sync revision should conservatively clear every core file cache."
    }
    Assert-Equal -Expected 1 -Actual $script:AuthRuntimeClearCount -Message "A skipped sync revision should conservatively clear authentication caches."

    # Cumulative revisions must retain multiple employee changes even when this
    # process skips intermediate employee/history versions.
    $employeeOneTimestamp = (Get-Item -Path $employeeFiles[$employeeCodes[0]]).LastWriteTimeUtc
    $employeeTwoTimestamp = (Get-Item -Path $employeeFiles[$employeeCodes[1]]).LastWriteTimeUtc
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[0]] -Marker "cello" -LastWriteUtc $employeeOneTimestamp
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[1]] -Marker "delta" -LastWriteUtc $employeeTwoTimestamp
    Publish-DataChange -Category "employee" -Resource $employeeCodes[0] | Out-Null
    Publish-DataChange -Category "history" -Resource "audit" | Out-Null
    Publish-DataChange -Category "employee" -Resource $employeeCodes[1] | Out-Null
    $beforeSkippedReadCount = $script:EmployeeJsonReadCount
    Assert-Equal -Expected "alpha" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[2]]) -Message "Skipped revisions evicted an unrelated employee."
    Assert-Equal -Expected "cello" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]]) -Message "The first skipped employee revision was lost."
    Assert-Equal -Expected "delta" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[1]]) -Message "The second skipped employee revision was lost."
    Assert-Equal -Expected ($beforeSkippedReadCount + 2) -Actual $script:EmployeeJsonReadCount -Message "Skipped revisions should reparse only both changed files."

    # A wildcard event with explicit affected codes remains targetable.
    $employeeOneTimestamp = (Get-Item -Path $employeeFiles[$employeeCodes[0]]).LastWriteTimeUtc
    $employeeTwoTimestamp = (Get-Item -Path $employeeFiles[$employeeCodes[1]]).LastWriteTimeUtc
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[0]] -Marker "echoo" -LastWriteUtc $employeeOneTimestamp
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[1]] -Marker "foxtt" -LastWriteUtc $employeeTwoTimestamp
    Publish-DataChange -Category "employee" -Resource "*" -AffectedEmployeeCodes @($employeeCodes[0], $employeeCodes[1]) | Out-Null
    $beforeBatchReadCount = $script:EmployeeJsonReadCount
    Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[2]] | Out-Null
    Assert-Equal -Expected "echoo" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]]) -Message "Explicit wildcard revision missed employee one."
    Assert-Equal -Expected "foxtt" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[1]]) -Message "Explicit wildcard revision missed employee two."
    Assert-Equal -Expected ($beforeBatchReadCount + 2) -Actual $script:EmployeeJsonReadCount -Message "Explicit wildcard revisions should preserve unrelated parsed files."

    # An unbounded wildcard must rotate the epoch and conservatively clear all.
    $beforeWildcardReadCount = $script:EmployeeJsonReadCount
    Publish-DataChange -Category "employee" -Resource "*" | Out-Null
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected ($beforeWildcardReadCount + 3) -Actual $script:EmployeeJsonReadCount -Message "Wildcard publication without affected codes should fully clear employee caches."

    # Delete/recreate must not retain a parsed object or a negative metadata hit.
    Remove-Item -Path $employeeFiles[$employeeCodes[0]] -Force
    Publish-DataChange -Category "employee" -Resource $employeeCodes[0] | Out-Null
    Assert-Equal -Expected "" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]]) -Message "Deleted employee data remained cached."
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[0]] -Marker "golfy"
    Publish-DataChange -Category "employee" -Resource $employeeCodes[0] | Out-Null
    Assert-Equal -Expected "golfy" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]]) -Message "Recreated employee data was hidden by a negative cache hit."

    # A state can have all required fields yet still be unsafe for targeting if
    # its current employee event is not represented by the current change ID.
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    $beforeInconsistentState = Read-SyncStateFromDisk -ThrowOnError:$true
    $inconsistentChangeId = [Guid]::NewGuid().ToString("N")
    $inconsistentState = [PSCustomObject]@{
        version               = [int]$beforeInconsistentState.version + 1
        changeId              = $inconsistentChangeId
        updatedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
        category              = "employee"
        resource              = $employeeCodes[0]
        employeeDataEpoch     = [string]$beforeInconsistentState.employeeDataEpoch
        employeeDataRevisions = [PSCustomObject](ConvertTo-SyncStateRevisionMap -Value $beforeInconsistentState.employeeDataRevisions)
    }
    $inconsistentTimestamp = (Get-Item -Path $employeeFiles[$employeeCodes[0]]).LastWriteTimeUtc
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[0]] -Marker "hotel" -LastWriteUtc $inconsistentTimestamp
    Write-JsonAtomic -Path $script:syncStateFile -Value $inconsistentState -Depth 8
    Clear-SyncStateCache
    $beforeInconsistentReadCount = $script:EmployeeJsonReadCount
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected "hotel" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[0]]) -Message "An inconsistent employee revision retained equal-metadata stale content."
    Assert-Equal -Expected ($beforeInconsistentReadCount + 3) -Actual $script:EmployeeJsonReadCount -Message "An inconsistent current employee revision should force a full clear."

    # Invalid revision keys and values must never enter the cumulative map.
    $invalidMapState = [PSCustomObject]@{
        version               = [int]$inconsistentState.version + 1
        changeId              = [Guid]::NewGuid().ToString("N")
        updatedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
        category              = "history"
        resource              = "invalid-map-fixture"
        employeeDataEpoch     = [string]$inconsistentState.employeeDataEpoch
        employeeDataRevisions = [PSCustomObject]@{ "../not-an-employee" = [Guid]::NewGuid().ToString("N") }
    }
    $invalidMapTimestamp = (Get-Item -Path $employeeFiles[$employeeCodes[1]]).LastWriteTimeUtc
    Write-ExternalEmployeeFixture -Path $employeeFiles[$employeeCodes[1]] -Marker "india" -LastWriteUtc $invalidMapTimestamp
    Write-JsonAtomic -Path $script:syncStateFile -Value $invalidMapState -Depth 8
    Clear-SyncStateCache
    $beforeInvalidMapReadCount = $script:EmployeeJsonReadCount
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected "india" -Actual (Get-EmployeeMarker -Path $employeeFiles[$employeeCodes[1]]) -Message "An invalid revision map retained equal-metadata stale content."
    Assert-Equal -Expected ($beforeInvalidMapReadCount + 3) -Actual $script:EmployeeJsonReadCount -Message "An invalid revision map should force a full clear."

    Publish-DataChange -Category "history" -Resource "schema-recovery" | Out-Null
    $beforeInvalidAffectedState = Read-SyncStateFromDisk -ThrowOnError:$true
    Publish-DataChange -Category "employee" -Resource "*" -AffectedEmployeeCodes @($employeeCodes[0], "../not-an-employee") | Out-Null
    $afterInvalidAffectedState = Read-SyncStateFromDisk -ThrowOnError:$true
    Assert-True -Condition ([string]$beforeInvalidAffectedState.employeeDataEpoch -ne [string]$afterInvalidAffectedState.employeeDataEpoch) -Message "An invalid affected employee code should rotate the employee epoch."
    $afterInvalidAffectedMap = ConvertTo-SyncStateRevisionMap -Value $afterInvalidAffectedState.employeeDataRevisions
    Assert-True -Condition (-not $afterInvalidAffectedMap.Contains("../not-an-employee")) -Message "An invalid affected employee code entered the revision map."

    # Legacy and malformed states cannot safely identify skipped resources and
    # therefore must force a full employee-cache clear.
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    $legacyVersion = [int](Get-SyncState).version + 1
    $legacyState = [PSCustomObject]@{
        version      = $legacyVersion
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        category     = "employee"
        resource     = $employeeCodes[0]
    }
    [System.IO.File]::WriteAllText($script:syncStateFile, ($legacyState | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Clear-SyncStateCache
    $beforeLegacyReadCount = $script:EmployeeJsonReadCount
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected ($beforeLegacyReadCount + 3) -Actual $script:EmployeeJsonReadCount -Message "Legacy sync state should force a full clear."

    Publish-DataChange -Category "history" -Resource "migration" | Out-Null
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    $validStateBeforeMalformed = Read-SyncStateFromDisk -ThrowOnError:$true
    $knownGoodState = Get-SyncState
    [System.IO.File]::WriteAllText($script:syncStateFile, "{malformed", (New-Object System.Text.UTF8Encoding($false)))
    $script:SyncStateDirty = $true
    $fallbackStateOne = Get-SyncState
    Start-Sleep -Milliseconds 5
    $script:SyncStateDirty = $true
    $fallbackStateTwo = Get-SyncState
    Assert-Equal -Expected ([string]$knownGoodState.changeId) -Actual ([string]$fallbackStateOne.changeId) -Message "A transient read failure discarded the last known-good state."
    Assert-Equal -Expected ([string]$fallbackStateOne.changeId) -Actual ([string]$fallbackStateTwo.changeId) -Message "Repeated read failures invented new bootstrap identities."

    Clear-SyncStateCache
    $beforeMalformedReadCount = $script:EmployeeJsonReadCount
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected ($beforeMalformedReadCount + 3) -Actual $script:EmployeeJsonReadCount -Message "Malformed sync state should force a full clear."

    # This file is derived invalidation metadata rather than business data. A
    # publisher should preserve the damaged bytes, rebuild a conservative
    # state, and continue so one corrupt notification file cannot disable all
    # later cross-machine refreshes.
    $syncRecoveryFolder = Join-Path -Path $tempFolder -ChildPath ".recovery"
    $recoveryFilesBefore = if (Test-Path -LiteralPath $syncRecoveryFolder -PathType Container) {
        @(Get-ChildItem -LiteralPath $syncRecoveryFolder -Filter "sync-state.corrupt.*.json" -File)
    }
    else {
        @()
    }
    $recoveryPathsBefore = @($recoveryFilesBefore | ForEach-Object { $_.FullName })
    $recoveredPublishState = Publish-DataChange -Category "history" -Resource "recover-malformed" -WarningAction SilentlyContinue
    Assert-Equal -Expected "history" -Actual ([string]$recoveredPublishState.category) -Message "Publishing did not recover from malformed derived sync state."
    Assert-Equal -Expected "recover-malformed" -Actual ([string]$recoveredPublishState.resource) -Message "The recovered publication lost its requested resource."
    Assert-True -Condition (Test-SyncStateRevisionSchema -State $recoveredPublishState) -Message "Malformed-state recovery did not rebuild the revision schema."
    $recoveryFilesAfter = @(Get-ChildItem -LiteralPath $syncRecoveryFolder -Filter "sync-state.corrupt.*.json" -File)
    $newRecoveryFiles = @($recoveryFilesAfter | Where-Object { $recoveryPathsBefore -notcontains $_.FullName })
    Assert-Equal -Expected 1 -Actual $newRecoveryFiles.Count -Message "Malformed sync-state recovery should preserve exactly one new backup."
    Assert-Equal -Expected "{malformed" -Actual ([System.IO.File]::ReadAllText($newRecoveryFiles[0].FullName)) -Message "Malformed sync-state recovery did not preserve the original bytes."
    Assert-True -Condition (([System.IO.File]::ReadAllText($script:syncStateFile) | ConvertFrom-Json) -ne $null) -Message "Malformed sync-state recovery did not replace the derived metadata with valid JSON."

    [System.IO.File]::WriteAllText(
        $script:syncStateFile,
        ($validStateBeforeMalformed | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Clear-SyncStateCache

    # Unknown and seed categories rotate the cumulative epoch.
    $beforeUnknownReadCount = $script:EmployeeJsonReadCount
    Publish-DataChange -Category "unknown-change" -Resource "system" | Out-Null
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected ($beforeUnknownReadCount + 3) -Actual $script:EmployeeJsonReadCount -Message "Unknown categories should force a full clear."

    $beforeSeedReadCount = $script:EmployeeJsonReadCount
    Publish-DataChange -Category "seed" -Resource "fixture" | Out-Null
    foreach ($employeeCode in $employeeCodes) {
        Get-EmployeeMarker -Path $employeeFiles[$employeeCode] | Out-Null
    }
    Assert-Equal -Expected ($beforeSeedReadCount + 3) -Actual $script:EmployeeJsonReadCount -Message "Seed changes should force a full clear."

    # The watcher must dirty this script scope (not an event-job scope) so an
    # external update is visible well before the long validation TTL expires.
    $script:SyncStateWatcherInitialized = $false
    Initialize-SyncStateWatcher
    Assert-True -Condition ($null -ne $script:SyncStateWatcher) -Message "The sync-state watcher failed to initialize."
    Assert-Equal -Expected 4 -Actual @($script:SyncStateWatcherSourceIdentifiers).Count -Message "The sync-state watcher did not register all file events."
    $script:SyncStateValidationIntervalMs = 600000
    $watcherBaseline = Get-SyncState
    $watcherChangeId = [Guid]::NewGuid().ToString("N")
    $watcherState = [PSCustomObject]@{
        version               = [int]$watcherBaseline.version + 1
        changeId              = $watcherChangeId
        updatedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
        category              = "history"
        resource              = "watcher-fixture"
        employeeDataEpoch     = [string]$watcherBaseline.employeeDataEpoch
        employeeDataRevisions = $watcherBaseline.employeeDataRevisions
    }
    Write-JsonAtomic -Path $script:syncStateFile -Value $watcherState -Depth 8
    $watcherDeadline = (Get-Date).AddSeconds(2)
    $watcherObservedState = $watcherBaseline
    while ((Get-Date) -lt $watcherDeadline -and [string]$watcherObservedState.changeId -ne $watcherChangeId) {
        Start-Sleep -Milliseconds 50
        $watcherObservedState = Get-SyncState
    }
    Assert-Equal -Expected $watcherChangeId -Actual ([string]$watcherObservedState.changeId) -Message "The watcher did not invalidate the server-scope cache before TTL expiry."
    $script:SyncStateValidationIntervalMs = 1

    # Two independent publishers must serialize their raw read/increment/write
    # transactions and retain both employee revisions.
    $childScriptPath = Join-Path -Path $tempFolder -ChildPath "publish-child.ps1"
    $childScript = @'
param(
    [string]$SharedFolder,
    [string]$RepoRoot,
    [string]$EmployeeCode,
    [string]$ReadyFile,
    [string]$StartFile
)
$ErrorActionPreference = "Stop"
$script:sharedFolder = $SharedFolder
$script:lockFolder = Join-Path -Path $SharedFolder -ChildPath ".locks"
$script:syncStateFile = Join-Path -Path $SharedFolder -ChildPath "sync-state.json"
$script:SyncStateWatcherInitialized = $true
. (Join-Path -Path $RepoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")
. (Join-Path -Path $RepoRoot -ChildPath "apps/admin/backend/services/SyncService.ps1")
[System.IO.File]::WriteAllText($ReadyFile, "ready")
$startDeadline = (Get-Date).AddSeconds(10)
while (-not (Test-Path -Path $StartFile -PathType Leaf)) {
    if ((Get-Date) -ge $startDeadline) {
        throw "Timed out waiting for the concurrent publisher barrier."
    }
    Start-Sleep -Milliseconds 10
}
Publish-DataChange -Category "employee" -Resource $EmployeeCode | Out-Null
'@
    [System.IO.File]::WriteAllText($childScriptPath, $childScript, (New-Object System.Text.UTF8Encoding($false)))

    $beforeConcurrentState = Read-SyncStateFromDisk
    $pwshPath = (Get-Command -Name pwsh -ErrorAction Stop).Source
    $readyFileOne = Join-Path -Path $tempFolder -ChildPath "publisher-one.ready"
    $readyFileTwo = Join-Path -Path $tempFolder -ChildPath "publisher-two.ready"
    $publisherStartFile = Join-Path -Path $tempFolder -ChildPath "publishers.start"
    $processOne = Start-Process -FilePath $pwshPath -ArgumentList @("-NoProfile", "-File", $childScriptPath, "-SharedFolder", $tempFolder, "-RepoRoot", $repoRoot, "-EmployeeCode", $employeeCodes[0], "-ReadyFile", $readyFileOne, "-StartFile", $publisherStartFile) -PassThru
    $processTwo = Start-Process -FilePath $pwshPath -ArgumentList @("-NoProfile", "-File", $childScriptPath, "-SharedFolder", $tempFolder, "-RepoRoot", $repoRoot, "-EmployeeCode", $employeeCodes[1], "-ReadyFile", $readyFileTwo, "-StartFile", $publisherStartFile) -PassThru
    $readyDeadline = (Get-Date).AddSeconds(10)
    while ((-not (Test-Path -Path $readyFileOne -PathType Leaf)) -or (-not (Test-Path -Path $readyFileTwo -PathType Leaf))) {
        if ((Get-Date) -ge $readyDeadline -or $processOne.HasExited -or $processTwo.HasExited) {
            throw "Concurrent publishers did not reach the start barrier."
        }
        Start-Sleep -Milliseconds 10
    }
    [System.IO.File]::WriteAllText($publisherStartFile, "start")
    $processOne.WaitForExit()
    $processTwo.WaitForExit()
    Assert-Equal -Expected 0 -Actual $processOne.ExitCode -Message "First concurrent publisher failed."
    Assert-Equal -Expected 0 -Actual $processTwo.ExitCode -Message "Second concurrent publisher failed."

    $afterConcurrentState = Read-SyncStateFromDisk
    Assert-Equal -Expected ([int]$beforeConcurrentState.version + 2) -Actual ([int]$afterConcurrentState.version) -Message "Concurrent publishers lost a version increment."
    $finalRevisionMap = ConvertTo-SyncStateRevisionMap -Value $afterConcurrentState.employeeDataRevisions
    Assert-True -Condition $finalRevisionMap.Contains($employeeCodes[0]) -Message "Concurrent state lost employee one's revision."
    Assert-True -Condition $finalRevisionMap.Contains($employeeCodes[1]) -Message "Concurrent state lost employee two's revision."

    Write-Host "Targeted cache invalidation test passed: exact and skipped changes reparse only affected files; fallback cases clear safely."
}
finally {
    foreach ($sourceIdentifier in @($script:SyncStateWatcherSourceIdentifiers)) {
        Get-Event -SourceIdentifier ([string]$sourceIdentifier) -ErrorAction SilentlyContinue |
            Remove-Event -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier ([string]$sourceIdentifier) -ErrorAction SilentlyContinue
    }
    if ($script:SyncStateWatcher) {
        $script:SyncStateWatcher.EnableRaisingEvents = $false
        $script:SyncStateWatcher.Dispose()
    }
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force
    }
}
