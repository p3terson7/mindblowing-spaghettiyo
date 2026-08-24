if (-not $script:CachedSyncState) {
    $script:CachedSyncState = $null
}

if (-not $script:SyncStateDirty) {
    $script:SyncStateDirty = $true
}

if (-not $script:SyncStateLastValidatedUtc) {
    $script:SyncStateLastValidatedUtc = $null
}

if (-not $script:SyncStateValidationIntervalMs) {
    $configuredSyncStateCacheMs = 0
    $configuredSyncStateCacheValue = [string]$env:SAPHIR_SYNC_STATE_CACHE_MS
    if ([string]::IsNullOrWhiteSpace($configuredSyncStateCacheValue)) {
        $configuredSyncStateCacheValue = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_SYNC_STATE_CACHE_MS"))
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredSyncStateCacheValue)) {
        [int]::TryParse($configuredSyncStateCacheValue, [ref]$configuredSyncStateCacheMs) | Out-Null
    }

    $script:SyncStateValidationIntervalMs = if ($configuredSyncStateCacheMs -gt 0) { $configuredSyncStateCacheMs } else { 10000 }
}

if (-not $script:SyncStateWatcherInitialized) {
    $script:SyncStateWatcherInitialized = $false
}

if (-not $script:SyncStateWatcher) {
    $script:SyncStateWatcher = $null
}

if (-not $script:SyncStateWatcherSubscriptions) {
    $script:SyncStateWatcherSubscriptions = @()
}

if (-not $script:SyncStateWatcherSourceIdentifiers) {
    $script:SyncStateWatcherSourceIdentifiers = @()
}

function New-DefaultSyncState {
    $changeId = [Guid]::NewGuid().ToString("N")
    return [PSCustomObject]@{
        version               = 0
        changeId              = $changeId
        updatedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
        category              = "bootstrap"
        resource              = "system"
        employeeDataEpoch     = [Guid]::NewGuid().ToString("N")
        employeeDataRevisions = [PSCustomObject]@{}
    }
}

function Test-SyncGuidValue {
    param($Value)

    $parsedGuid = [Guid]::Empty
    return (-not [string]::IsNullOrWhiteSpace([string]$Value) -and
        [Guid]::TryParse([string]$Value, [ref]$parsedGuid) -and
        $parsedGuid -ne [Guid]::Empty)
}

function Test-SyncEmployeeCode {
    param($Value)

    return (-not [string]::IsNullOrWhiteSpace([string]$Value) -and
        ([string]$Value).Trim() -match "^\d+$")
}

function Test-SyncStateRevisionSchema {
    param($State)

    if ($null -eq $State) {
        return $false
    }

    $propertyNames = @($State.PSObject.Properties.Name)
    if (-not ($propertyNames -contains "changeId") -or
        -not ($propertyNames -contains "employeeDataEpoch") -or
        -not ($propertyNames -contains "employeeDataRevisions")) {
        return $false
    }

    if (-not (Test-SyncGuidValue -Value $State.changeId) -or
        -not (Test-SyncGuidValue -Value $State.employeeDataEpoch)) {
        return $false
    }

    $revisions = $State.employeeDataRevisions
    if ($null -eq $revisions -or
        -not (($revisions -is [System.Collections.IDictionary]) -or
        ($revisions.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject"))) {
        return $false
    }

    $revisionMap = ConvertTo-SyncStateRevisionMap -Value $revisions
    foreach ($employeeCode in @($revisionMap.Keys)) {
        if (-not (Test-SyncEmployeeCode -Value $employeeCode) -or
            -not (Test-SyncGuidValue -Value $revisionMap[$employeeCode])) {
            return $false
        }
    }

    return $true
}

function ConvertTo-SyncStateRevisionMap {
    param($Value)

    $result = [ordered]@{}
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $result[[string]$key] = [string]$Value[$key]
        }
        return $result
    }

    if ($null -ne $Value -and ($Value.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject")) {
        foreach ($property in @($Value.PSObject.Properties)) {
            $result[[string]$property.Name] = [string]$property.Value
        }
    }

    return $result
}

function Read-SyncStateFromDisk {
    param([bool]$ThrowOnError = $false)

    try {
        if (-not (Test-SaphirFileExists -Path $syncStateFile)) {
            if ($ThrowOnError) {
                throw (New-Object System.IO.FileNotFoundException("Sync state file does not exist: $syncStateFile", $syncStateFile))
            }
            return (New-DefaultSyncState)
        }
        # SyncService owns its own validation cache. Always bypass the generic
        # file-content cache here so an external publisher is observable as
        # soon as sync validation runs.
        $raw = Read-TextFileWithRetry -Path $syncStateFile
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw (New-Object System.IO.InvalidDataException("Sync state file is empty: $syncStateFile"))
        }

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $parsedVersion = 0
        if ($null -eq $parsed -or
            -not ($parsed.PSObject.Properties.Name -contains "version") -or
            -not [int]::TryParse([string]$parsed.version, [ref]$parsedVersion) -or
            $parsedVersion -lt 0) {
            throw "Sync state file has an invalid version: $syncStateFile"
        }

        return $parsed
    }
    catch {
        if ($ThrowOnError) {
            throw
        }
        return (New-DefaultSyncState)
    }
}

function Clear-SyncStateCache {
    $script:CachedSyncState = $null
    $script:SyncStateDirty = $true
    $script:SyncStateLastValidatedUtc = $null
    Clear-CachedFileContent -Path $syncStateFile
}

function Update-SyncStateDirtyFromWatcher {
    $receivedEvent = $false
    foreach ($sourceIdentifier in @($script:SyncStateWatcherSourceIdentifiers)) {
        $pendingEvents = @(Get-Event -SourceIdentifier ([string]$sourceIdentifier) -ErrorAction SilentlyContinue)
        foreach ($pendingEvent in $pendingEvents) {
            $receivedEvent = $true
            Remove-Event -EventIdentifier $pendingEvent.EventIdentifier -ErrorAction SilentlyContinue
        }
    }

    if ($receivedEvent) {
        # Event actions execute in a separate script scope. Drain the event
        # queue here so these assignments happen in the server's scope.
        $script:SyncStateDirty = $true
        $script:SyncStateLastValidatedUtc = $null
        Clear-CachedFileContent -Path $syncStateFile
    }
}

function Initialize-SyncStateWatcher {
    if ($script:SyncStateWatcherInitialized) {
        return
    }

    $script:SyncStateWatcherInitialized = $true
    $watchFolder = Split-Path -Path $syncStateFile -Parent
    if ([string]::IsNullOrWhiteSpace($watchFolder) -or -not (Test-Path -Path $watchFolder)) {
        return
    }

    try {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $watchFolder
        $watcher.Filter = Split-Path -Path $syncStateFile -Leaf
        $watcher.IncludeSubdirectories = $false
        $watcher.NotifyFilter = [System.IO.NotifyFilters]"FileName, LastWrite, Size, CreationTime"
        $script:SyncStateWatcher = $watcher

        $watcherId = [Guid]::NewGuid().ToString("N")
        $script:SyncStateWatcherSourceIdentifiers = @(
            "SAPHIR.SyncState.$watcherId.Changed"
            "SAPHIR.SyncState.$watcherId.Created"
            "SAPHIR.SyncState.$watcherId.Deleted"
            "SAPHIR.SyncState.$watcherId.Renamed"
        )
        $eventNames = @("Changed", "Created", "Deleted", "Renamed")
        $subscriptions = New-Object System.Collections.ArrayList
        for ($index = 0; $index -lt $eventNames.Count; $index++) {
            $subscription = Register-ObjectEvent -InputObject $watcher -EventName $eventNames[$index] -SourceIdentifier $script:SyncStateWatcherSourceIdentifiers[$index]
            [void]$subscriptions.Add($subscription)
        }
        $script:SyncStateWatcherSubscriptions = @($subscriptions.ToArray())
        $watcher.EnableRaisingEvents = $true
    }
    catch {
        foreach ($sourceIdentifier in @($script:SyncStateWatcherSourceIdentifiers)) {
            Unregister-Event -SourceIdentifier ([string]$sourceIdentifier) -ErrorAction SilentlyContinue
        }
        if ($script:SyncStateWatcher) {
            $script:SyncStateWatcher.Dispose()
        }
        $script:SyncStateWatcher = $null
        $script:SyncStateWatcherSubscriptions = @()
        $script:SyncStateWatcherSourceIdentifiers = @()
    }
}

function Read-SyncStateUnsafe {
    Update-SyncStateDirtyFromWatcher

    $nowUtc = (Get-Date).ToUniversalTime()
    if ($script:CachedSyncState -and -not $script:SyncStateDirty -and $script:SyncStateLastValidatedUtc) {
        $cacheAgeMs = ($nowUtc - $script:SyncStateLastValidatedUtc).TotalMilliseconds
        if ($cacheAgeMs -lt $script:SyncStateValidationIntervalMs) {
            return $script:CachedSyncState
        }
    }

    try {
        # The watcher is only an optimization. At validation expiry, bypass the
        # text/metadata caches so timestamp-preserving replacements are observed.
        $parsed = Read-SyncStateFromDisk -ThrowOnError:$true
        $script:CachedSyncState = $parsed
        $script:SyncStateDirty = $false
        $script:SyncStateLastValidatedUtc = $nowUtc
        return $parsed
    }
    catch {
        # A transient cross-process replacement or parse failure must not invent
        # a fresh change identity. Retain the last known-good state, or create a
        # single stable bootstrap state if no valid state has ever been read.
        if (-not $script:CachedSyncState) {
            $script:CachedSyncState = New-DefaultSyncState
        }
        $script:SyncStateDirty = $false
        $script:SyncStateLastValidatedUtc = $nowUtc
        return $script:CachedSyncState
    }
}

function Ensure-SyncState {
    if (Test-SaphirFileExists -Path $syncStateFile) {
        return
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $syncStateFile
    try {
        if (Test-SaphirFileExists -Path $syncStateFile) {
            return
        }

        $initialState = New-DefaultSyncState
        Write-JsonAtomic -Path $syncStateFile -Value $initialState -Depth 6
        Clear-SyncStateCache
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    Initialize-SyncStateWatcher
}

function Get-SyncState {
    # This runs before every HTTP route. It must remain a read-only,
    # best-effort operation: synchronization metadata can be temporarily
    # unavailable without blocking the business request that follows.
    return (Read-SyncStateUnsafe)
}

function Get-PublicSyncState {
    param($State = $null)

    $resolvedState = if ($null -ne $State) { $State } else { Get-SyncState }
    return [PSCustomObject]@{
        version      = [int]$resolvedState.version
        changeId     = [string]$resolvedState.changeId
        updatedAtUtc = [string]$resolvedState.updatedAtUtc
        category     = [string]$resolvedState.category
        resource     = [string]$resolvedState.resource
    }
}

function Read-SyncStateForPublication {
    try {
        return (Read-SyncStateFromDisk -ThrowOnError:$true)
    }
    catch {
        if ($null -ne $_.Exception.Data -and
            $_.Exception.Data.Contains("SaphirHttpStatusCode") -and
            [int]$_.Exception.Data["SaphirHttpStatusCode"] -eq 503) {
            throw
        }

        # sync-state.json is derived cache-invalidation metadata, not business
        # data. Preserve its corrupt bytes before rebuilding it so one damaged
        # notification file cannot permanently disable every future publish.
        $recoveryFolder = Join-Path -Path $sharedFolder -ChildPath ".recovery"
        New-Item -ItemType Directory -Path $recoveryFolder -Force -ErrorAction Stop | Out-Null
        $recoveryName = "sync-state.corrupt.{0}.{1}.json" -f (
            (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ"),
            [Guid]::NewGuid().ToString("N")
        )
        $recoveryPath = Join-Path -Path $recoveryFolder -ChildPath $recoveryName
        if (Test-Path -LiteralPath $syncStateFile -PathType Leaf) {
            Copy-Item -LiteralPath $syncStateFile -Destination $recoveryPath -ErrorAction Stop
        }

        Write-Warning "Recovered invalid sync-state metadata. The original was preserved at $recoveryPath"
        return (New-DefaultSyncState)
    }
}

function Publish-DataChange {
    param(
        [string]$Category = "data",
        [string]$Resource = "shared",
        [string[]]$AffectedEmployeeCodes = @()
    )

    $lockHandle = Acquire-ResourceLock -ResourcePath $syncStateFile
    try {
        # Force a raw read only after acquiring the cross-process lock so a
        # cached state cannot overwrite another process's completed update.
        $state = Read-SyncStateForPublication
        $currentVersion = 0
        [int]::TryParse([string]$state.version, [ref]$currentVersion) | Out-Null
        $nextVersion = $currentVersion + 1

        $normalizedCategory = ([string]$Category).Trim().ToLowerInvariant()
        $normalizedResource = ([string]$Resource).Trim()
        $stateHasRevisionSchema = Test-SyncStateRevisionSchema -State $state
        $employeeDataEpoch = if ($stateHasRevisionSchema) { [string]$state.employeeDataEpoch } else { [Guid]::NewGuid().ToString("N") }
        $employeeDataRevisions = if ($stateHasRevisionSchema) {
            ConvertTo-SyncStateRevisionMap -Value $state.employeeDataRevisions
        }
        else {
            [ordered]@{}
        }

        $affectedCodes = New-Object System.Collections.ArrayList
        $affectedCodeSet = @{}
        $hasInvalidAffectedCode = $false
        foreach ($employeeCodeValue in @($AffectedEmployeeCodes)) {
            $employeeCode = ([string]$employeeCodeValue).Trim()
            if (-not (Test-SyncEmployeeCode -Value $employeeCode)) {
                $hasInvalidAffectedCode = $true
                continue
            }
            if (-not $affectedCodeSet.ContainsKey($employeeCode)) {
                $affectedCodeSet[$employeeCode] = $true
                [void]$affectedCodes.Add($employeeCode)
            }
        }

        if (($normalizedCategory -eq "employee" -or $normalizedCategory -eq "employee-directory") -and
            (Test-SyncEmployeeCode -Value $normalizedResource) -and
            -not $affectedCodeSet.ContainsKey($normalizedResource)) {
            $affectedCodeSet[$normalizedResource] = $true
            [void]$affectedCodes.Add($normalizedResource)
        }

        $requiresEmployeeEpochReset = (-not $stateHasRevisionSchema) -or $hasInvalidAffectedCode
        if ($normalizedCategory -eq "employee" -or $normalizedCategory -eq "employee-directory") {
            if (($normalizedResource -ne "*" -and -not (Test-SyncEmployeeCode -Value $normalizedResource)) -or
                $affectedCodes.Count -eq 0) {
                $requiresEmployeeEpochReset = $true
            }
        }
        elseif (@("history", "project", "auth") -notcontains $normalizedCategory) {
            $requiresEmployeeEpochReset = $true
        }

        if ($requiresEmployeeEpochReset) {
            $employeeDataEpoch = [Guid]::NewGuid().ToString("N")
            $employeeDataRevisions = [ordered]@{}
        }

        $changeId = [Guid]::NewGuid().ToString("N")
        foreach ($employeeCode in @($affectedCodes.ToArray())) {
            $employeeDataRevisions[[string]$employeeCode] = $changeId
        }

        $updatedState = [PSCustomObject]@{
            version               = $nextVersion
            changeId              = $changeId
            updatedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
            category              = $normalizedCategory
            resource              = $normalizedResource
            employeeDataEpoch     = $employeeDataEpoch
            employeeDataRevisions = [PSCustomObject]$employeeDataRevisions
        }

        Write-JsonAtomic -Path $syncStateFile -Value $updatedState -Depth 8
        $script:CachedSyncState = $updatedState
        $script:SyncStateDirty = $false
        $script:SyncStateLastValidatedUtc = (Get-Date).ToUniversalTime()
        return $updatedState
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

Ensure-SyncState
Initialize-SyncStateWatcher
