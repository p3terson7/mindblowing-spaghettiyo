# Internal references only: never serialize these objects to an HTTP response.
# Raw entries retain their private compensation snapshot; public projections
# are constructed only after the requested period/project has been selected.
function Get-ProjectStatisticsEntriesSnapshot {
    param($CurrentUser, [AllowNull()][string]$StartDate, [AllowNull()][string]$EndDate)

    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) { return @() }
    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $scopeKey = if ($isSuperAdmin) { "global" } else { @($accessModel.ProjectCodes) -join "," }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $start = ConvertTo-ProjectDateOrNull -Value $StartDate
    $end = ConvertTo-ProjectDateOrNull -Value $EndDate
    $hasBounds = ($null -ne $start -or $null -ne $end)
    $boundsKey = "$($start.Ticks)|$($end.Ticks)"
    $cacheKey = "project-statistics-entry-snapshot|$scopeKey|$userScopeKey|$boundsKey"

    return (Invoke-ReadModelCache -Key $cacheKey -Dependencies @("directory", "auth", "projects", "compensation") -Factory {
        $entriesList = New-Object Collections.ArrayList
        $seenEmployeeCodes = @{}
        $culture = [Globalization.CultureInfo]::CurrentCulture
        $canCompareKeys = $culture.Calendar -is [Globalization.GregorianCalendar]
        $startKey = if ($canCompareKeys -and $null -ne $start) { $start.ToString("yyyy-MM-dd", $culture) } else { "" }
        $endKey = if ($canCompareKeys -and $null -ne $end) { $end.ToString("yyyy-MM-dd", $culture) } else { "" }
        # Disabled employees still contribute to the history of active projects.
        $users = @(Get-Users | Where-Object { Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode "" } | Sort-Object username)
        if (Get-Command Prime-EmployeeFileMetadata -ErrorAction SilentlyContinue) {
            try { Prime-EmployeeFileMetadata -Paths @($users | ForEach-Object { Get-EmployeeDataFilePath -EmployeeCode (Get-UserEmployeeCodeValue $_) }) }
            catch {
                # Enumeration is optional; direct file reads retain their normal
                # freshness/error behavior when listing the share is unavailable.
                if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.metadata.batch.fallback" }
            }
        }
        foreach ($user in $users) {
            $employeeCode = Get-UserEmployeeCodeValue -UserRecord $user
            if ([string]::IsNullOrWhiteSpace($employeeCode) -or $seenEmployeeCodes.ContainsKey($employeeCode)) { continue }
            $seenEmployeeCodes[$employeeCode] = $true
            $archived = ($user.PSObject.Properties.Name -contains "disabled" -and [bool]$user.disabled)
            # Reuse Vue d'ensemble's entry contribution. This parent already
            # owns compensation dependencies; the source carries saved amounts.
            $source = Get-EmployeeReadContribution -User $user -RawEntries
            # A one-month portfolio should not build a year's worth of facts.
            # Reuse this employee's selected facts after another employee edits.
            $facts = @(Invoke-ReadModelCache -Key "project-entry-facts|$employeeCode|$archived|$boundsKey" -Dependencies @("employee:$employeeCode", "directory", "auth", "compensation") -Factory {
                foreach ($entry in @($source.entries)) {
                    $projectCode = [string]$entry.projectCode
                    if ([string]::IsNullOrWhiteSpace($projectCode)) { continue }
                    $dateKey = [string]$entry.date
                    if ($hasBounds) {
                        if (($startKey -and [string]::CompareOrdinal($dateKey, $startKey) -lt 0) -or
                            ($endKey -and [string]::CompareOrdinal($dateKey, $endKey) -gt 0)) { continue }
                        # Still reject invalid legacy dates that sort in range.
                        $entryDate = Get-EntryDateOrNull -Entry $entry
                        if ($null -eq $entryDate -or ($null -ne $start -and $entryDate -lt $start) -or ($null -ne $end -and $entryDate -gt $end)) { continue }
                    }
                    [PSCustomObject]@{
                        rawEntry = $entry
                        employeeCode = $employeeCode
                        employeeName = [string]$source.employee.name
                        employeeRole = [string]$source.employee.role
                        employeeArchived = $archived
                        entryId = if ([string]::IsNullOrWhiteSpace([string]$entry.entryId)) { "" } else { [string]$entry.entryId }
                        projectCode = $projectCode
                        # The only non-overtime type is diverse. Legacy unknown
                        # or omitted values still have the overtime default.
                        entryType = if (([string]$entry.entryType).Trim().ToLowerInvariant() -eq "diverse") { "diverse" } else { "overtime" }
                        date = $dateKey
                        punchIn = [string]$entry.punchIn
                        punchOut = $entry.punchOut
                        status = [string]$entry.status
                        overtime = [string]$entry.overtime
                    }
                }
            })
            foreach ($fact in $facts) {
                if ($isSuperAdmin -or $accessModel.ProjectCodeSet.ContainsKey([string]$fact.projectCode)) { [void]$entriesList.Add($fact) }
            }
        }
        return @($entriesList.ToArray())
    })
}

function Get-ProjectStatisticsEntriesForPeriod {
    param([AllowNull()][string]$StartDate, [AllowNull()][string]$EndDate, $CurrentUser)
    return (Get-ProjectStatisticsEntriesSnapshot -CurrentUser $CurrentUser -StartDate $StartDate -EndDate $EndDate)
}

function Get-ProjectEntryMonetary {
    param($Entry)
    if ($null -ne $Entry.PSObject.Properties["rawEntry"]) { return (New-EntryMonetaryReadModel -Entry $Entry.rawEntry) }
    # Supports existing callers that supply already-public entry projections.
    if ($null -ne $Entry.PSObject.Properties["monetary"]) { return $Entry.monetary }
    return $null
}

function ConvertTo-ProjectEntryAccessProjection {
    param($Entry, $CurrentUser, $ModifyAccessModel, [bool]$IsSuperAdmin, $CanApproveByEmployee)
    if ($Entry.PSObject.Properties.Name -notcontains "rawEntry") { return $Entry }
    $employeeCode = [string]$Entry.employeeCode
    if (-not $CanApproveByEmployee.ContainsKey($employeeCode)) {
        $CanApproveByEmployee[$employeeCode] = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole ([string]$Entry.employeeRole)
    }
    $normalized = ConvertTo-EmployeeFileReadEntry -Entry $Entry.rawEntry
    $projection = New-EmployeeEntryProjectionForAccessModel -EmployeeCode $employeeCode -EmployeeName ([string]$Entry.employeeName) -Entry $normalized -ModifyProjectCodeSet $ModifyAccessModel.ProjectCodeSet -EmployeeRole ([string]$Entry.employeeRole) -IsSuperAdmin:$IsSuperAdmin -CanApproveEmployeeRole:([bool]$CanApproveByEmployee[$employeeCode])
    $projection | Add-Member -NotePropertyName employeeArchived -NotePropertyValue ([bool]$Entry.employeeArchived) -Force
    if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "project.entry.detail.projected" }
    return $projection
}
