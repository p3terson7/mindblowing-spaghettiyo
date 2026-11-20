# Internal references only: never serialize these objects to an HTTP response.
# Raw entries retain their private compensation snapshot; public projections
# are constructed only after the requested period/project has been selected.
function Get-ProjectStatisticsEntriesSnapshot {
    param($CurrentUser)

    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) { return @() }
    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $scopeKey = if ($isSuperAdmin) { "global" } else { @($accessModel.ProjectCodes) -join "," }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $cacheKey = "project-statistics-entry-snapshot|$scopeKey|$userScopeKey"

    return (Invoke-ReadModelCache -Key $cacheKey -Dependencies @("directory", "auth", "projects", "compensation") -Factory {
        $entriesList = New-Object Collections.ArrayList
        $seenEmployeeCodes = @{}
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
            # IncludeMonetary declares snapshot dependencies only; it does not
            # project amounts or look up salary settings while reading entries.
            $source = Get-EmployeeReadContribution -User $user -IncludeMonetary -SkipProjection
            # Keep per-employee work reusable when another employee changes.
            $facts = @(Invoke-ReadModelCache -Key "project-entry-facts|$employeeCode|$archived" -Dependencies @("employee:$employeeCode", "directory", "auth", "compensation") -Factory {
                foreach ($entry in @($source.entries)) {
                    if ([string]::IsNullOrWhiteSpace([string]$entry.projectCode)) { continue }
                    [PSCustomObject]@{
                        rawEntry = $entry
                        employeeCode = $employeeCode
                        employeeName = [string]$source.employee.name
                        employeeRole = [string]$source.employee.role
                        employeeArchived = $archived
                        entryId = [string]$entry.entryId
                        projectCode = [string]$entry.projectCode
                        entryType = [string]$entry.entryType
                        date = [string]$entry.date
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

    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $key = "project-period-entries|$StartDate|$EndDate|$userScopeKey"
    return (Invoke-ReadModelCache -Key $key -Dependencies @("directory", "auth", "projects", "compensation") -Factory {
        $start = ConvertTo-ProjectDateOrNull -Value $StartDate
        $end = ConvertTo-ProjectDateOrNull -Value $EndDate
        $entries = @(Get-ProjectStatisticsEntriesSnapshot -CurrentUser $CurrentUser)
        if ($null -eq $start -and $null -eq $end) { return $entries }
        foreach ($entry in $entries) {
            $entryDate = Get-EntryDateOrNull -Entry $entry
            if ($null -eq $entryDate -or ($null -ne $start -and $entryDate -lt $start) -or ($null -ne $end -and $entryDate -gt $end)) { continue }
            $entry
        }
    })
}

function Get-ProjectEntryMonetary {
    param($Entry)
    if ($Entry.PSObject.Properties.Name -contains "rawEntry") { return (New-EntryMonetaryReadModel -Entry $Entry.rawEntry) }
    # Supports existing callers that supply already-public entry projections.
    if ($Entry.PSObject.Properties.Name -contains "monetary") { return $Entry.monetary }
    return $null
}

function ConvertTo-ProjectEntryAccessProjection {
    param($Entry, $CurrentUser, $ModifyAccessModel, [bool]$IsSuperAdmin, $CanApproveByEmployee)
    if ($Entry.PSObject.Properties.Name -notcontains "rawEntry") { return $Entry }
    $employeeCode = [string]$Entry.employeeCode
    if (-not $CanApproveByEmployee.ContainsKey($employeeCode)) {
        $CanApproveByEmployee[$employeeCode] = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole ([string]$Entry.employeeRole)
    }
    $projection = New-EmployeeEntryProjectionForAccessModel -EmployeeCode $employeeCode -EmployeeName ([string]$Entry.employeeName) -Entry $Entry.rawEntry -ModifyProjectCodeSet $ModifyAccessModel.ProjectCodeSet -EmployeeRole ([string]$Entry.employeeRole) -IsSuperAdmin:$IsSuperAdmin -CanApproveEmployeeRole:([bool]$CanApproveByEmployee[$employeeCode])
    $projection | Add-Member -NotePropertyName employeeArchived -NotePropertyValue ([bool]$Entry.employeeArchived) -Force
    if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "project.entry.detail.projected" }
    return $projection
}
