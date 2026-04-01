if (-not $script:CachedSyncState) {
    $script:CachedSyncState = $null
}

if (-not $script:CachedSyncStateLastWriteTicks) {
    $script:CachedSyncStateLastWriteTicks = $null
}

if (-not $script:CachedSyncStateLength) {
    $script:CachedSyncStateLength = $null
}

if (-not $script:SyncStateDirty) {
    $script:SyncStateDirty = $true
}

if (-not $script:SyncStateLastValidatedUtc) {
    $script:SyncStateLastValidatedUtc = $null
}

if (-not $script:SyncStateValidationIntervalMs) {
    $script:SyncStateValidationIntervalMs = 4000
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

function New-DefaultSyncState {
    return [PSCustomObject]@{
        version      = 0
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        category     = "bootstrap"
        resource     = "system"
    }
}

function Clear-SyncStateCache {
    $script:CachedSyncState = $null
    $script:CachedSyncStateLastWriteTicks = $null
    $script:CachedSyncStateLength = $null
    $script:SyncStateDirty = $true
    $script:SyncStateLastValidatedUtc = $null
    Clear-CachedFileContent -Path $syncStateFile
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
        $watcher.EnableRaisingEvents = $true
        $script:SyncStateWatcher = $watcher

        $syncStatePath = $syncStateFile
        $subscriptionAction = {
            $targetPath = [string]$Event.MessageData
            $script:CachedSyncState = $null
            $script:CachedSyncStateLastWriteTicks = $null
            $script:CachedSyncStateLength = $null
            $script:SyncStateDirty = $true
            $script:SyncStateLastValidatedUtc = $null

            if (Get-Command -Name Clear-CachedFileContent -ErrorAction SilentlyContinue) {
                Clear-CachedFileContent -Path $targetPath
            }
        }

        $script:SyncStateWatcherSubscriptions = @(
            Register-ObjectEvent -InputObject $watcher -EventName Changed -MessageData $syncStatePath -Action $subscriptionAction
            Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $syncStatePath -Action $subscriptionAction
            Register-ObjectEvent -InputObject $watcher -EventName Deleted -MessageData $syncStatePath -Action $subscriptionAction
            Register-ObjectEvent -InputObject $watcher -EventName Renamed -MessageData $syncStatePath -Action $subscriptionAction
        )
    }
    catch {
        $script:SyncStateWatcher = $null
        $script:SyncStateWatcherSubscriptions = @()
    }
}

function Read-SyncStateUnsafe {
    $nowUtc = (Get-Date).ToUniversalTime()
    if ($script:CachedSyncState -and -not $script:SyncStateDirty -and $script:SyncStateLastValidatedUtc) {
        $cacheAgeMs = ($nowUtc - $script:SyncStateLastValidatedUtc).TotalMilliseconds
        if ($cacheAgeMs -lt $script:SyncStateValidationIntervalMs) {
            return $script:CachedSyncState
        }
    }

    if (-not (Test-Path -Path $syncStateFile)) {
        return (New-DefaultSyncState)
    }

    try {
        $item = Get-Item -Path $syncStateFile
        if ($script:CachedSyncState -and -not $script:SyncStateDirty -and $script:CachedSyncStateLastWriteTicks -eq $item.LastWriteTimeUtc.Ticks -and $script:CachedSyncStateLength -eq $item.Length) {
            $script:SyncStateLastValidatedUtc = $nowUtc
            return $script:CachedSyncState
        }

        $parsed = Read-TextFileCached -Path $syncStateFile | ConvertFrom-Json
        $script:CachedSyncState = $parsed
        $script:CachedSyncStateLastWriteTicks = $item.LastWriteTimeUtc.Ticks
        $script:CachedSyncStateLength = $item.Length
        $script:SyncStateDirty = $false
        $script:SyncStateLastValidatedUtc = $nowUtc
        return $parsed
    }
    catch {
        return (New-DefaultSyncState)
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

function Publish-DataChange {
    param(
        [string]$Category = "data",
        [string]$Resource = "shared"
    )

    Ensure-SyncState

    $lockHandle = Acquire-ResourceLock -ResourcePath $syncStateFile
    try {
        $state = Read-SyncStateUnsafe
        $nextVersion = 1
        if ($state.version) {
            $nextVersion = [int]$state.version + 1
        }

        $updatedState = [PSCustomObject]@{
            version      = $nextVersion
            updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            category     = $Category
            resource     = $Resource
        }

        Write-JsonAtomic -Path $syncStateFile -Value $updatedState -Depth 6
        $syncStateItem = Get-Item -Path $syncStateFile
        $script:CachedSyncState = $updatedState
        $script:CachedSyncStateLastWriteTicks = $syncStateItem.LastWriteTimeUtc.Ticks
        $script:CachedSyncStateLength = $syncStateItem.Length
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
