if (-not $script:CachedSyncState) {
    $script:CachedSyncState = $null
}

if (-not $script:CachedSyncStateLastWriteTicks) {
    $script:CachedSyncStateLastWriteTicks = $null
}

if (-not $script:CachedSyncStateLength) {
    $script:CachedSyncStateLength = $null
}

function New-DefaultSyncState {
    return [PSCustomObject]@{
        version      = 0
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        category     = "bootstrap"
        resource     = "system"
    }
}

function Read-SyncStateUnsafe {
    if (-not (Test-Path -Path $syncStateFile)) {
        return (New-DefaultSyncState)
    }

    try {
        $item = Get-Item -Path $syncStateFile
        if ($script:CachedSyncState -and $script:CachedSyncStateLastWriteTicks -eq $item.LastWriteTimeUtc.Ticks -and $script:CachedSyncStateLength -eq $item.Length) {
            return $script:CachedSyncState
        }

        $parsed = Read-TextFileCached -Path $syncStateFile | ConvertFrom-Json
        $script:CachedSyncState = $parsed
        $script:CachedSyncStateLastWriteTicks = $item.LastWriteTimeUtc.Ticks
        $script:CachedSyncStateLength = $item.Length
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
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
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
        return $updatedState
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

Ensure-SyncState
