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

function Add-HistoryEntries {
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [bool]$PublishChange = $true,
        [string]$PublishResource = ""
    )

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

    $newEntries = New-Object System.Collections.ArrayList
    $employeeNames = @{}
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }

        $action = if ($entry.PSObject.Properties.Name -contains "action") { [string]$entry.action } else { "" }
        $message = if ($entry.PSObject.Properties.Name -contains "message") { [string]$entry.message } else { "" }
        $employeeName = if ($entry.PSObject.Properties.Name -contains "employeeName") {
            [string]$entry.employeeName
        }
        elseif ($entry.PSObject.Properties.Name -contains "employee") {
            [string]$entry.employee
        }
        else {
            ""
        }

        if ([string]::IsNullOrWhiteSpace($action) -or [string]::IsNullOrWhiteSpace($message) -or [string]::IsNullOrWhiteSpace($employeeName)) {
            continue
        }

        $employeeNames[$employeeName] = $true
        [void]$newEntries.Add([PSCustomObject]@{
            action         = $action
            message        = $message
            employee       = $employeeName
            targetEmployee = $employeeName
            author         = $actorName
            authorUsername = $actorUsername
            authorRole     = $actorRole
            timestamp      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }

    if ($newEntries.Count -eq 0) {
        return 0
    }

    $targetHistoryFile = Join-Path -Path $sharedFolder -ChildPath "history.json"
    $lockHandle = Acquire-ResourceLock -ResourcePath $targetHistoryFile
    try {
        # Refresh after acquiring the cross-process lock so a completed writer
        # cannot be overwritten by this process's metadata/content cache.
        Clear-CachedFileContent -Path $targetHistoryFile
        $existingHistory = @(Read-JsonArrayFile -Path $targetHistoryFile)
        $combinedHistory = New-Object System.Collections.ArrayList
        foreach ($historyEntry in $existingHistory) {
            [void]$combinedHistory.Add($historyEntry)
        }
        foreach ($historyEntry in $newEntries) {
            [void]$combinedHistory.Add($historyEntry)
        }

        Write-JsonAtomic -Path $targetHistoryFile -Value @($combinedHistory.ToArray()) -Depth 6
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    if ($PublishChange) {
        $resource = [string]$PublishResource
        if ([string]::IsNullOrWhiteSpace($resource)) {
            $resource = if ($employeeNames.Count -eq 1) { [string](@($employeeNames.Keys)[0]) } else { "*" }
        }
        Publish-DataChange -Category "history" -Resource $resource | Out-Null
    }

    return $newEntries.Count
}

# Backwards-compatible one-entry wrapper used by existing routes and services.
function logHistory($action, $message, $employeeName) {
    Add-HistoryEntries -Entries @([PSCustomObject]@{
        action       = $action
        message      = $message
        employeeName = $employeeName
    }) -PublishResource $employeeName | Out-Null
}
