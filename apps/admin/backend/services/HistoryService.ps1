function Get-HistoryCallerUser {
    foreach ($scopeLevel in 1..4) {
        $currentUserVariable = Get-Variable -Name currentUser -Scope $scopeLevel -ErrorAction SilentlyContinue
        if ($null -ne $currentUserVariable -and $null -ne $currentUserVariable.Value) {
            return $currentUserVariable.Value
        }
    }

    $scriptCurrentUserVariable = Get-Variable -Name currentUser -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $scriptCurrentUserVariable -and $null -ne $scriptCurrentUserVariable.Value) {
        return $scriptCurrentUserVariable.Value
    }

    return $null
}

function Get-HistoryActorName {
    param($CurrentUser)

    if ($null -eq $CurrentUser) {
        return "System"
    }

    if ($CurrentUser.PSObject.Properties.Name -contains "displayName" -and -not [string]::IsNullOrWhiteSpace([string]$CurrentUser.displayName)) {
        return [string]$CurrentUser.displayName
    }

    if ($CurrentUser.PSObject.Properties.Name -contains "username" -and -not [string]::IsNullOrWhiteSpace([string]$CurrentUser.username)) {
        return [string]$CurrentUser.username
    }

    return "System"
}

# Helper: Log a history entry by appending an object with an action string and timestamp to history.json.
function logHistory($action, $message, $employeeName) {
    $historyFile = Join-Path -Path $sharedFolder -ChildPath "history.json"
    
    # If any of the required parameters is null or empty, skip logging.
    if ([string]::IsNullOrWhiteSpace($action) -or [string]::IsNullOrWhiteSpace($message) -or [string]::IsNullOrWhiteSpace($employeeName)) {
        return
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $historyFile
    try {
        $existingHistory = @(Read-JsonArrayFile -Path $historyFile)

        $historyActor = Get-HistoryCallerUser
        $actorName = Get-HistoryActorName -CurrentUser $historyActor
        $actorUsername = ""
        $actorRole = ""

        if ($null -ne $historyActor) {
            if ($historyActor.PSObject.Properties.Name -contains "username") {
                $actorUsername = [string]$historyActor.username
            }
            if ($historyActor.PSObject.Properties.Name -contains "role") {
                $actorRole = [string]$historyActor.role
            }
        }

        # Create a new log entry. "employee" is kept as the affected person
        # for backwards compatibility with existing frontend/data conventions.
        $newLogEntry = [PSCustomObject]@{
            action         = $action
            message        = $message
            employee       = $employeeName
            targetEmployee = $employeeName
            author         = $actorName
            authorUsername = $actorUsername
            authorRole     = $actorRole
            timestamp      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        $existingHistory += $newLogEntry
        Write-JsonAtomic -Path $historyFile -Value $existingHistory -Depth 6
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    Publish-DataChange -Category "history" -Resource $employeeName
}
