# Cache normalized employee contributions, not delta arithmetic on totals.
# Aggregates concatenate/re-sort these immutable-by-convention projections.
# Entry writes never consume these cached values.
function Get-EmployeeReadContribution {
    param([Parameter(Mandatory = $true)]$User, [switch]$IncludeMonetary, [switch]$SkipProjection)
    $employeeCode = Get-UserEmployeeCodeValue -UserRecord $User
    $key = "employee-contribution|$employeeCode|$([bool]$IncludeMonetary)|$([bool]$SkipProjection)"
    $sources = @("employee:$employeeCode", "directory", "auth")
    if ($IncludeMonetary) { $sources += "compensation" }
    return (Invoke-ReadModelCache -Key $key -Dependencies $sources -Factory {
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.employee-contribution.recomputed" }
        $name = if ($User.displayName) { [string]$User.displayName } else { [string](Get-EmployeeName $employeeCode) }
        $role = Get-EffectiveUserRole -UserRecord $User
        $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode
        $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile -IncludeMonetary:$IncludeMonetary)
        $projectCodes = @($entries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.projectCode) } | ForEach-Object { [string]$_.projectCode } | Sort-Object -Unique)
        $projected = if ($SkipProjection) { @() } else { @($entries | ForEach-Object { New-EmployeeEntryProjection -EmployeeCode $employeeCode -EmployeeName $name -Entry $_ -EmployeeRole $role }) }
        $types = if ($SkipProjection) { @("overtime") } else { @(Get-EmployeeTimeEntryTypesFromUserRecord -UserRecord $User) }
        return [PSCustomObject]@{
            employee = [PSCustomObject]@{ code = $employeeCode; name = $name; role = $role; entryCount = $entries.Count; projectCodes = $projectCodes; timeEntryTypes = $types }
            entries = $entries
            projectedEntries = $projected
        }
    })
}

function Get-ScopedEmployeeReadContribution {
    param(
        [Parameter(Mandatory = $true)]$Contribution,
        [Parameter(Mandatory = $true)][string]$ScopeIdentity,
        [Parameter(Mandatory = $true)]$AccessModel,
        [Parameter(Mandatory = $true)]$ModifyAccessModel,
        $CurrentUser,
        [bool]$IsSuperAdmin,
        [bool]$IncludeMonetary = $false,
        [bool]$Archived = $false
    )
    $employee = $Contribution.employee
    $employeeCode = [string]$employee.code
    $sources = @("employee:$employeeCode", "directory", "auth", "projects")
    if ($IncludeMonetary) { $sources += "compensation" }
    $key = "scoped-employee-contribution|$employeeCode|$ScopeIdentity|$IncludeMonetary|$Archived"
    return (Invoke-ReadModelCache -Key $key -Dependencies $sources -Factory {
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.employee-scope.recomputed" }
        $visible = @($Contribution.entries | Where-Object { $IsSuperAdmin -or $AccessModel.ProjectCodeSet.ContainsKey([string]$_.projectCode) })
        $canApprove = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole ([string]$employee.role)
        $projected = @(foreach ($entry in $visible) {
            $projection = New-EmployeeEntryProjectionForAccessModel -EmployeeCode $employeeCode -EmployeeName ([string]$employee.name) -Entry $entry -ModifyProjectCodeSet $ModifyAccessModel.ProjectCodeSet -EmployeeRole ([string]$employee.role) -IsSuperAdmin:$IsSuperAdmin -CanApproveEmployeeRole:$canApprove
            if ($IncludeMonetary) { $projection | Add-Member -NotePropertyName employeeArchived -NotePropertyValue $Archived -Force }
            $projection
        })
        $codes = @($visible | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.projectCode) } | ForEach-Object { [string]$_.projectCode } | Sort-Object -Unique)
        return [PSCustomObject]@{
            employee = [PSCustomObject]@{ code = $employeeCode; name = $employee.name; entryCount = $visible.Count; projectCodes = $codes; role = $employee.role; timeEntryTypes = $employee.timeEntryTypes }
            entries = $projected
        }
    })
}

function Get-EmployeeDirectoryContribution {
    param($User, [string]$ScopeIdentity, $VisibleProjectCodeSet, [bool]$Scoped)
    $code = Get-UserEmployeeCodeValue $User
    $key = "employee-directory-contribution|$code|$ScopeIdentity|$Scoped"
    $sources = @("employee:$code", "directory", "auth", "compensation")
    if ($Scoped) { $sources += "projects" }
    return (Invoke-ReadModelCache -Key $key -Dependencies $sources -Factory {
        $source = Get-EmployeeReadContribution -User $User -IncludeMonetary -SkipProjection
        $entries = @($source.entries | Where-Object { -not $Scoped -or $VisibleProjectCodeSet.ContainsKey([string]$_.projectCode) })
        return [PSCustomObject]@{
            entries = $entries
            stats = Get-EmployeeDirectoryStats -Entries $entries
        }
    })
}
