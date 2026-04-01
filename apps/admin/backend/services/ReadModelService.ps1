if (-not $script:ReadModelCache) {
    $script:ReadModelCache = @{}
}

if (-not $script:ReadModelCacheVersion) {
    $script:ReadModelCacheVersion = $null
}

if (-not $script:EmployeeEntryFileCache) {
    $script:EmployeeEntryFileCache = @{}
}

function Get-ReadModelVersionKey {
    $state = Get-SyncState
    if ($state -and $null -ne $state.version) {
        return [string]([int]$state.version)
    }

    return "0"
}

function Invoke-ReadModelCache {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][scriptblock]$Factory
    )

    $versionKey = Get-ReadModelVersionKey
    if ($script:ReadModelCacheVersion -ne $versionKey) {
        $script:ReadModelCache = @{}
        $script:ReadModelCacheVersion = $versionKey
    }

    if ($script:ReadModelCache.ContainsKey($Key)) {
        return $script:ReadModelCache[$Key]
    }

    $value = & $Factory
    $script:ReadModelCache[$Key] = $value
    return $value
}

function Convert-SecondsToTimeText {
    param([double]$Seconds)

    $safeSeconds = [math]::Max(0, [int][math]::Round([double]$Seconds))
    return (New-TimeSpan -Seconds $safeSeconds).ToString("hh\:mm\:ss")
}

function Get-OvertimeSecondsFromText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or [string]$Value -eq "N/A") {
        return 0
    }

    try {
        return [int][math]::Round(([TimeSpan]::Parse([string]$Value)).TotalSeconds)
    }
    catch {
        return 0
    }
}

function Get-EntryDateOrNull {
    param($Entry)

    try {
        return [DateTime]::ParseExact([string]$Entry.date, "yyyy-MM-dd", $null)
    }
    catch {
        return $null
    }
}

function Get-EntryDateTimeOrMin {
    param($Entry)

    try {
        return [DateTime]::ParseExact(("{0} {1}" -f [string]$Entry.date, [string]$Entry.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Test-EntryOpen {
    param($Entry)

    return ($null -ne $Entry -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchIn) -and [string]::IsNullOrWhiteSpace([string]$Entry.punchOut))
}

function New-EmployeeEntryProjection {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [Parameter(Mandatory = $true)]$Entry
    )

    return [PSCustomObject]@{
        name         = [string]$Entry.name
        date         = [string]$Entry.date
        punchIn      = [string]$Entry.punchIn
        punchOut     = if ($null -ne $Entry.punchOut) { [string]$Entry.punchOut } else { $null }
        overtime     = if ($null -ne $Entry.overtime) { [string]$Entry.overtime } else { $null }
        status       = if ($null -ne $Entry.status) { [string]$Entry.status } else { "pending" }
        message      = if ($null -ne $Entry.message) { [string]$Entry.message } else { "" }
        projectCode  = if ($null -ne $Entry.projectCode) { [string]$Entry.projectCode } else { "" }
        overtimeCode = if ($null -ne $Entry.overtimeCode) { [string]$Entry.overtimeCode } else { "" }
        employeeCode = $EmployeeCode
        employeeName = $EmployeeName
    }
}

function Get-CachedEmployeeEntriesForFile {
    param([Parameter(Mandatory = $true)][string]$DataFile)

    $metadata = Get-FileMetadataSnapshot -Path $DataFile
    if ($null -eq $metadata) {
        if ($script:EmployeeEntryFileCache.ContainsKey($DataFile)) {
            $script:EmployeeEntryFileCache.Remove($DataFile) | Out-Null
        }
        return @()
    }

    $cacheEntry = $script:EmployeeEntryFileCache[$DataFile]
    if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
        return $cacheEntry.Entries
    }

    $entries = @(Read-JsonArrayFile -Path $DataFile)
    $script:EmployeeEntryFileCache[$DataFile] = [PSCustomObject]@{
        LastWriteTicks = $metadata.LastWriteTicks
        Length         = $metadata.Length
        Entries        = $entries
    }

    return $entries
}

function Get-EmployeeDataSnapshot {
    return (Invoke-ReadModelCache -Key "employee-data-snapshot" -Factory {
        $employees = @()
        $entriesByEmployee = @{}
        $flattenedEntries = @()
        $users = @(Get-Users | Where-Object { [string]$_.role -eq "employee" -and -not [bool]$_.disabled } | Sort-Object username)

        foreach ($user in $users) {
            $employeeCode = if ($user.employeeCode) { [string]$user.employeeCode } else { [string]$user.username }
            $displayName = if ($user.displayName) { [string]$user.displayName } else { [string](Get-EmployeeName $employeeCode) }
            $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode
            $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)

            $employees += [PSCustomObject]@{
                code       = $employeeCode
                name       = $displayName
                entryCount = $entries.Count
            }

            $entriesByEmployee[$employeeCode] = $entries

            foreach ($entry in $entries) {
                $flattenedEntries += (New-EmployeeEntryProjection -EmployeeCode $employeeCode -EmployeeName $displayName -Entry $entry)
            }
        }

        return [PSCustomObject]@{
            employees        = $employees
            entriesByEmployee = $entriesByEmployee
            flattenedEntries = $flattenedEntries
        }
    })
}

function Get-FilteredEmployeeEntriesSnapshot {
    param(
        [string]$StartDate,
        [string]$EndDate
    )

    $cacheKey = "filtered-employee-entries|{0}|{1}" -f [string]$StartDate, [string]$EndDate
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $snapshot = Get-EmployeeDataSnapshot
        $entries = @($snapshot.flattenedEntries)
        $startDt = $null
        $endDt = $null

        if ($StartDate) {
            try {
                $startDt = [DateTime]::ParseExact($StartDate, "yyyy-MM-dd", $null)
            }
            catch { }
        }

        if ($EndDate) {
            try {
                $endDt = [DateTime]::ParseExact($EndDate, "yyyy-MM-dd", $null)
            }
            catch { }
        }

        if (-not $startDt -and -not $endDt) {
            return $entries
        }

        $filtered = @()
        foreach ($entry in $entries) {
            $entryDate = Get-EntryDateOrNull -Entry $entry
            if ($null -eq $entryDate) {
                continue
            }

            if ($startDt -and $entryDate -lt $startDt) {
                continue
            }

            if ($endDt -and $entryDate -gt $endDt) {
                continue
            }

            $filtered += $entry
        }

        return $filtered
    })
}

function Get-HistoryEntriesSnapshot {
    return (Invoke-ReadModelCache -Key "history-entries" -Factory {
        if (-not (Test-Path -Path $historyFile)) {
            return @()
        }

        return @(Read-JsonArrayFile -Path $historyFile)
    })
}

function Get-RecentHistoryEntriesSnapshot {
    param([int]$Limit = 7)

    $entries = @(Get-HistoryEntriesSnapshot | Sort-Object {
        try {
            [DateTime]::Parse(($_.timestamp -replace " ", "T"))
        }
        catch {
            [DateTime]::MinValue
        }
    } -Descending)

    if ($Limit -le 0) {
        return $entries
    }

    return @($entries | Select-Object -First $Limit)
}

function Get-DashboardBootstrapModel {
    param([string]$SelectedEmployeeCode)

    $cacheKey = "dashboard-bootstrap|{0}" -f [string]$SelectedEmployeeCode
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $snapshot = Get-EmployeeDataSnapshot
        $flattenedEntries = @($snapshot.flattenedEntries)
        $now = Get-Date
        $currentMonthEntries = @()

        foreach ($entry in $flattenedEntries) {
            $entryDate = Get-EntryDateOrNull -Entry $entry
            if ($null -eq $entryDate) {
                continue
            }

            if ($entryDate.Month -eq $now.Month -and $entryDate.Year -eq $now.Year) {
                $currentMonthEntries += $entry
            }
        }

        $totalSeconds = 0
        foreach ($entry in $currentMonthEntries) {
            $totalSeconds += Get-OvertimeSecondsFromText -Value ([string]$entry.overtime)
        }

        $pendingEntries = @($flattenedEntries | Where-Object { [string]$_.status -eq "pending" -and -not (Test-EntryOpen $_) } | Sort-Object { Get-EntryDateTimeOrMin -Entry $_ } -Descending)
        $activeEntries = @($flattenedEntries | Where-Object { Test-EntryOpen $_ } | Sort-Object { Get-EntryDateTimeOrMin -Entry $_ } -Descending)
        $preferredEntry = $pendingEntries | Select-Object -First 1
        $defaultEmployeeCode = if ($preferredEntry) { [string]$preferredEntry.employeeCode } elseif ($snapshot.employees.Count -gt 0) { [string]$snapshot.employees[0].code } else { "" }
        $resolvedEmployeeCode = if ([string]::IsNullOrWhiteSpace([string]$SelectedEmployeeCode)) { $defaultEmployeeCode } else { [string]$SelectedEmployeeCode }
        if ($resolvedEmployeeCode -and -not $snapshot.entriesByEmployee.ContainsKey($resolvedEmployeeCode)) {
            $resolvedEmployeeCode = $defaultEmployeeCode
        }
        $selectedEmployeeEntries = if ($resolvedEmployeeCode -and $snapshot.entriesByEmployee.ContainsKey($resolvedEmployeeCode)) { @($snapshot.entriesByEmployee[$resolvedEmployeeCode]) } else { @() }

        return [PSCustomObject]@{
            employees             = $snapshot.employees
            totalOvertime         = Convert-SecondsToTimeText -Seconds $totalSeconds
            pendingApprovals      = @($flattenedEntries | Where-Object { [string]$_.status -eq "pending" }).Count
            activeEmployees       = $activeEntries.Count
            trackedEmployees      = $snapshot.employees.Count
            pendingQueue          = @($pendingEntries | Select-Object -First 6)
            activeSessions        = @($activeEntries | Select-Object -First 6)
            recentHistory         = Get-RecentHistoryEntriesSnapshot -Limit 7
            defaultEmployeeCode   = $defaultEmployeeCode
            selectedEmployeeCode  = $resolvedEmployeeCode
            selectedEmployeeEntries = $selectedEmployeeEntries
        }
    })
}

function Get-ApprovalsEntriesModel {
    return (Invoke-ReadModelCache -Key "approvals-entries" -Factory {
        return @((Get-EmployeeDataSnapshot).flattenedEntries | Sort-Object { Get-EntryDateTimeOrMin -Entry $_ } -Descending)
    })
}

function Get-ProjectStatisticsOverview {
    param(
        [string]$StartDate,
        [string]$EndDate
    )

    $cacheKey = "project-statistics-overview|{0}|{1}" -f [string]$StartDate, [string]$EndDate
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $stats = @{}
        $entries = @(Get-FilteredEmployeeEntriesSnapshot -StartDate $StartDate -EndDate $EndDate)

        foreach ($entry in $entries) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.projectCode)) {
                continue
            }

            $projectCode = [string]$entry.projectCode
            $seconds = Get-OvertimeSecondsFromText -Value ([string]$entry.overtime)

            if (-not $stats.ContainsKey($projectCode)) {
                $stats[$projectCode] = [PSCustomObject]@{
                    totalSeconds = 0
                    entryCount   = 0
                    breakdown    = @{}
                }
            }

            $stats[$projectCode].totalSeconds += $seconds
            $stats[$projectCode].entryCount++

            $employeeName = if ($entry.employeeName) { [string]$entry.employeeName } else { [string]$entry.name }
            if (-not $stats[$projectCode].breakdown.ContainsKey($employeeName)) {
                $stats[$projectCode].breakdown[$employeeName] = @{
                    totalSeconds = 0
                    entryCount   = 0
                    entries      = @()
                }
            }

            $stats[$projectCode].breakdown[$employeeName].totalSeconds += $seconds
            $stats[$projectCode].breakdown[$employeeName].entryCount++
            $stats[$projectCode].breakdown[$employeeName].entries += [PSCustomObject]@{
                date     = $entry.date
                punchIn  = $entry.punchIn
                punchOut = $entry.punchOut
                overtime = if ($entry.overtime) { [string]$entry.overtime } else { "00:00:00" }
            }
        }

        return $stats
    })
}

function Get-ProjectSummaryList {
    param(
        [string]$StartDate,
        [string]$EndDate
    )

    $projects = @(Get-Projects)
    $stats = Get-ProjectStatisticsOverview -StartDate $StartDate -EndDate $EndDate
    $orderedCodes = New-Object System.Collections.ArrayList

    foreach ($project in ($projects | Sort-Object projectCode)) {
        if (-not $orderedCodes.Contains([string]$project.projectCode)) {
            [void]$orderedCodes.Add([string]$project.projectCode)
        }
    }

    foreach ($projectCode in ($stats.Keys | Sort-Object)) {
        if (-not $orderedCodes.Contains([string]$projectCode)) {
            [void]$orderedCodes.Add([string]$projectCode)
        }
    }

    $summaries = @()
    foreach ($projectCode in $orderedCodes) {
        $project = $projects | Where-Object { [string]$_.projectCode -eq [string]$projectCode } | Select-Object -First 1
        $projectStats = if ($stats.ContainsKey($projectCode)) { $stats[$projectCode] } else { $null }
        $totalSeconds = if ($projectStats) { [double]$projectStats.totalSeconds } else { 0 }
        $entryCount = if ($projectStats) { [int]$projectStats.entryCount } else { 0 }
        $averageSeconds = if ($entryCount -gt 0) { [math]::Round($totalSeconds / $entryCount) } else { 0 }

        $summaries += [PSCustomObject]@{
            projectCode     = [string]$projectCode
            projectName     = if ($project) { [string]$project.projectName } else { [string]$projectCode }
            totalOvertime   = Convert-SecondsToTimeText -Seconds $totalSeconds
            entryCount      = $entryCount
            averageOvertime = Convert-SecondsToTimeText -Seconds $averageSeconds
        }
    }

    return $summaries
}

function Get-ProjectDetailModel {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectCode,
        [string]$StartDate,
        [string]$EndDate
    )

    $summaries = @(Get-ProjectSummaryList -StartDate $StartDate -EndDate $EndDate)
    $projectSummary = $summaries | Where-Object { [string]$_.projectCode -eq [string]$ProjectCode } | Select-Object -First 1
    if ($null -eq $projectSummary) {
        return $null
    }

    $stats = Get-ProjectStatisticsOverview -StartDate $StartDate -EndDate $EndDate
    $projectStats = if ($stats.ContainsKey($ProjectCode)) { $stats[$ProjectCode] } else { $null }
    $breakdown = @()

    if ($projectStats) {
        foreach ($employeeName in ($projectStats.breakdown.Keys | Sort-Object)) {
            $employeeStats = $projectStats.breakdown[$employeeName]
            $breakdown += [PSCustomObject]@{
                employee   = $employeeName
                overtime   = Convert-SecondsToTimeText -Seconds $employeeStats.totalSeconds
                entryCount = [int]$employeeStats.entryCount
                entries    = @($employeeStats.entries | Sort-Object date, punchIn)
            }
        }
    }

    return [PSCustomObject]@{
        projectCode         = [string]$projectSummary.projectCode
        projectName         = [string]$projectSummary.projectName
        totalOvertime       = [string]$projectSummary.totalOvertime
        entryCount          = [int]$projectSummary.entryCount
        averageOvertime     = [string]$projectSummary.averageOvertime
        breakdownByEmployee = $breakdown
    }
}

function Get-ProjectTrendModel {
    param(
        [string]$StartDate,
        [string]$EndDate
    )

    $cacheKey = "project-trends|{0}|{1}" -f [string]$StartDate, [string]$EndDate
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $trendStats = @{}
        $entries = @(Get-FilteredEmployeeEntriesSnapshot -StartDate $StartDate -EndDate $EndDate)

        foreach ($entry in $entries) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.projectCode) -or [string]::IsNullOrWhiteSpace([string]$entry.date) -or [string]$entry.date -notmatch '^\d{4}-\d{2}') {
                continue
            }

            $month = $entry.date.Substring(0, 7)
            $seconds = Get-OvertimeSecondsFromText -Value ([string]$entry.overtime)

            if (-not $trendStats.ContainsKey([string]$entry.projectCode)) {
                $trendStats[[string]$entry.projectCode] = @{}
            }

            if (-not $trendStats[[string]$entry.projectCode].ContainsKey($month)) {
                $trendStats[[string]$entry.projectCode][$month] = 0
            }

            $trendStats[[string]$entry.projectCode][$month] += $seconds
        }

        $result = @{}
        foreach ($projectCode in $trendStats.Keys) {
            $months = @()
            foreach ($month in ($trendStats[$projectCode].Keys | Sort-Object)) {
                $months += [PSCustomObject]@{
                    month    = $month
                    overtime = [math]::Round(($trendStats[$projectCode][$month] / 3600), 2)
                }
            }

            $result[$projectCode] = $months
        }

        return $result
    })
}

function Get-ProjectsBootstrapModel {
    param(
        [string]$StartDate,
        [string]$EndDate,
        [string]$SelectedProjectCode
    )

    $summary = @(Get-ProjectSummaryList -StartDate $StartDate -EndDate $EndDate)
    $resolvedProjectCode = [string]$SelectedProjectCode
    if ([string]::IsNullOrWhiteSpace($resolvedProjectCode) -or -not ($summary | Where-Object { [string]$_.projectCode -eq $resolvedProjectCode })) {
        if ($summary.Count -gt 0) {
            $resolvedProjectCode = [string]$summary[0].projectCode
        }
        else {
            $resolvedProjectCode = ""
        }
    }

    return [PSCustomObject]@{
        summary             = $summary
        trends              = Get-ProjectTrendModel -StartDate $StartDate -EndDate $EndDate
        selectedProjectCode = $resolvedProjectCode
        selectedProject     = if ($resolvedProjectCode) { Get-ProjectDetailModel -ProjectCode $resolvedProjectCode -StartDate $StartDate -EndDate $EndDate } else { $null }
    }
}

function Get-SelfBootstrapModel {
    param([Parameter(Mandatory = $true)][string]$EmployeeCode)

    $dataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode)
    $entries = if (Test-Path -Path $dataFile) { @(Read-JsonArrayFile -Path $dataFile) } else { @() }

    return [PSCustomObject]@{
        entries        = $entries
        projects       = @(Get-Projects)
        overtimeCodes  = @(Get-OvertimeCodes)
    }
}
