$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-hot-path-test-{0}" -f ([Guid]::NewGuid().ToString("N")))

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Get-MedianMilliseconds {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$Iterations = 3
    )

    & $Action | Out-Null
    $measurements = @()
    for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
        $measurements += (Measure-Command { & $Action | Out-Null }).TotalMilliseconds
    }
    $sorted = @($measurements | Sort-Object)
    return [double]$sorted[[int][Math]::Floor($sorted.Count / 2)]
}

try {
    New-Item -ItemType Directory -Path $tempFolder | Out-Null
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/EntryService.ps1")

    $entries = New-Object System.Collections.ArrayList
    $start = [DateTime]::ParseExact("2025-01-01 08:00:00", "yyyy-MM-dd HH:mm:ss", $null)
    for ($index = 0; $index -lt 10000; $index++) {
        $timestamp = $start.AddMinutes($index)
        $isActive = ($index % 127) -eq 0
        $entry = [PSCustomObject]@{
            entryId   = "entry-$index"
            date      = $timestamp.ToString("yyyy-MM-dd")
            punchIn   = $timestamp.ToString("HH:mm:ss")
            punchOut  = if ($isActive) { $null } else { $timestamp.AddMinutes(30).ToString("HH:mm:ss") }
            forgottenClockOut = ($isActive -and ($index % 254) -eq 0)
        }
        [void]$entries.Add($entry)
    }

    # Define a deterministic tie policy: the later append wins when two active
    # records share the same timestamp.
    [void]$entries.Add([PSCustomObject]@{
        entryId = "tie-first"; date = "2026-12-31"; punchIn = "23:59:00"; punchOut = $null; forgottenClockOut = $false
    })
    [void]$entries.Add([PSCustomObject]@{
        entryId = "tie-last"; date = "2026-12-31"; punchIn = "23:59:00"; punchOut = $null; forgottenClockOut = $false
    })

    $entryArray = @($entries.ToArray())
    $legacyLatestActive = @(
        $entryArray |
            Sort-Object @{
                Expression = {
                    try {
                        [DateTime]::ParseExact(("{0} {1}" -f $_.date, $_.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
                    }
                    catch {
                        [DateTime]::MinValue
                    }
                }
            } |
            Where-Object { $_.punchIn -and -not $_.punchOut -and -not (Test-EntryForgottenClockOut -Entry $_) }
    ) | Select-Object -Last 1
    $linearLatestActive = Get-LatestActiveEntry -Entries $entryArray
    Assert-Equal -Expected $legacyLatestActive.entryId -Actual $linearLatestActive.entryId -Message "Linear active-entry selection changed behavior."
    Assert-Equal -Expected "tie-last" -Actual $linearLatestActive.entryId -Message "Equal timestamps should retain the last active record."

    # Sort-Object is not stable for equal keys when a lower key follows them
    # (on pwsh 7.4 it returns mixed-lower, mixed-second, mixed-first). The
    # linear helper must keep the append-order rule independent of that shape.
    $mixedTieEntries = @(
        [PSCustomObject]@{ entryId = "mixed-first"; date = "2026-07-02"; punchIn = "09:00:00"; punchOut = $null; forgottenClockOut = $false },
        [PSCustomObject]@{ entryId = "mixed-second"; date = "2026-07-02"; punchIn = "09:00:00"; punchOut = $null; forgottenClockOut = $false },
        [PSCustomObject]@{ entryId = "mixed-lower"; date = "2026-07-01"; punchIn = "09:00:00"; punchOut = $null; forgottenClockOut = $false }
    )
    $mixedTieLatest = Get-LatestActiveEntry -Entries $mixedTieEntries
    Assert-Equal -Expected "mixed-second" -Actual $mixedTieLatest.entryId -Message "Mixed-key ties should prefer the later appended active record."

    $legacyAction = {
        @(
            $entryArray |
                Sort-Object @{
                    Expression = {
                        try {
                            [DateTime]::ParseExact(("{0} {1}" -f $_.date, $_.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
                        }
                        catch {
                            [DateTime]::MinValue
                        }
                    }
                } |
                Where-Object { $_.punchIn -and -not $_.punchOut -and -not (Test-EntryForgottenClockOut -Entry $_) }
        ) | Select-Object -Last 1
    }
    $linearAction = { Get-LatestActiveEntry -Entries $entryArray }
    $legacyMedianMs = Get-MedianMilliseconds -Action $legacyAction
    $linearMedianMs = Get-MedianMilliseconds -Action $linearAction

    $script:sharedFolder = $tempFolder
    $script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
    $script:historyFile = Join-Path -Path $tempFolder -ChildPath "history.json"
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")

    $script:TestSyncState = [PSCustomObject]@{
        version               = 1
        changeId              = "history-state-1"
        updatedAtUtc           = "2026-07-13T00:00:00Z"
        category              = "history"
        resource              = "fixture"
        employeeDataEpoch     = "employee-epoch-1"
        employeeDataRevisions = [PSCustomObject]@{}
    }
    function Get-SyncState {
        return $script:TestSyncState
    }

    $script:ReadModelCache = @{}
    $script:ReadModelCacheVersion = $null
    $script:ReadModelSyncState = $null
    $script:EmployeeEntryFileCache = @{}
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/ReadModelService.ps1")

    $history = New-Object System.Collections.ArrayList
    $historyStart = [DateTime]::ParseExact("2026-01-01 00:00:00", "yyyy-MM-dd HH:mm:ss", $null)
    for ($index = 0; $index -lt 5000; $index++) {
        [void]$history.Add([PSCustomObject]@{
            action    = "Update"
            message   = "History $index"
            employee  = "Employee"
            timestamp = $historyStart.AddSeconds($index).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }
    Write-JsonAtomic -Path $script:historyFile -Value @($history.ToArray()) -Depth 6

    $coldHistoryMs = (Measure-Command { $script:FirstRecentHistory = @(Get-RecentHistoryEntriesSnapshot -Limit 7) }).TotalMilliseconds
    Assert-Equal -Expected 7 -Actual $script:FirstRecentHistory.Count -Message "Recent history returned the wrong limit."
    Assert-Equal -Expected "History 4999" -Actual $script:FirstRecentHistory[0].message -Message "Recent history returned the wrong order."
    Assert-Equal -Expected $true -Actual $script:ReadModelCache.ContainsKey("history-entries-sorted") -Message "The sorted history projection was not cached."

    $warmHistoryMs = Get-MedianMilliseconds -Iterations 5 -Action {
        @(Get-RecentHistoryEntriesSnapshot -Limit 20).Count
    }
    Assert-Equal -Expected 20 -Actual @(Get-RecentHistoryEntriesSnapshot -Limit 20).Count -Message "A second history limit returned the wrong count."

    [void]$history.Add([PSCustomObject]@{
        action = "Update"; message = "Newest history"; employee = "Employee"; timestamp = "2027-01-01 00:00:00"
    })
    Write-JsonAtomic -Path $script:historyFile -Value @($history.ToArray()) -Depth 6
    $script:TestSyncState = [PSCustomObject]@{
        version               = 2
        changeId              = "history-state-2"
        updatedAtUtc           = "2026-07-13T00:01:00Z"
        category              = "history"
        resource              = "fixture"
        employeeDataEpoch     = "employee-epoch-1"
        employeeDataRevisions = [PSCustomObject]@{}
    }
    $refreshedHistory = @(Get-RecentHistoryEntriesSnapshot -Limit 1)
    Assert-Equal -Expected "Newest history" -Actual $refreshedHistory[0].message -Message "A sync change did not invalidate sorted history."

    $linearSpeedup = if ($linearMedianMs -gt 0) { $legacyMedianMs / $linearMedianMs } else { 0 }
    $historySpeedup = if ($warmHistoryMs -gt 0) { $coldHistoryMs / $warmHistoryMs } else { 0 }
    Write-Host ("Small hot-path test passed. Active entry: {0:N1} ms sort/filter vs {1:N1} ms linear ({2:N1}x); history: {3:N1} ms cold sort vs {4:N2} ms cached ({5:N1}x)." -f $legacyMedianMs, $linearMedianMs, $linearSpeedup, $coldHistoryMs, $warmHistoryMs, $historySpeedup)
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force
    }
}
