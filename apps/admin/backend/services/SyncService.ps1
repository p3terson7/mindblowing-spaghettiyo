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
        return (Get-Content -Path $syncStateFile -Raw | ConvertFrom-Json)
    }
    catch {
        return (New-DefaultSyncState)
    }
}

function Ensure-SyncState {
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
        return $updatedState
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

Ensure-SyncState
