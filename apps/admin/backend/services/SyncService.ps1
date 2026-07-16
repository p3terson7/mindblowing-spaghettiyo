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

    if (-not (Test-Path -Path $syncStateFile -PathType Leaf)) {
        if ($ThrowOnError) {
            throw "Sync state file does not exist: $syncStateFile"
        }
        return (New-DefaultSyncState)
    }

    try {
        $raw = [System.IO.File]::ReadAllText($syncStateFile)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "Sync state file is empty: $syncStateFile"
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
    if (Test-Path -Path $syncStateFile) {
        return
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $syncStateFile
    try {
        if (Test-Path -Path $syncStateFile) {
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
    Ensure-SyncState
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

function Publish-DataChange {
    param(
        [string]$Category = "data",
        [string]$Resource = "shared",
        [string[]]$AffectedEmployeeCodes = @()
    )

    Ensure-SyncState

    $lockHandle = Acquire-ResourceLock -ResourcePath $syncStateFile
    try {
        # Force a raw read only after acquiring the cross-process lock so a
        # cached state cannot overwrite another process's completed update.
        $state = Read-SyncStateFromDisk -ThrowOnError:$true
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
