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

        # Create a new log entry.
        $newLogEntry = [PSCustomObject]@{
            action    = $action
            message   = $message
            employee  = $employeeName
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        $existingHistory += $newLogEntry
        Write-JsonAtomic -Path $historyFile -Value $existingHistory -Depth 6
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    Publish-DataChange -Category "history" -Resource $employeeName
}
