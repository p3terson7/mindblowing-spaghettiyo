# Review keeps private, dependency-aware references in memory. Only the requested
# page becomes public entry DTOs; no employee statistics or salary lookup is used.
function Get-ReviewEntryIndex {
    param($CurrentUser)
    $access = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $super = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $scope = (Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser) + '|' + (@($access.ProjectCodes) -join ',')
    return (Invoke-ReadModelCache -Key "review-index|$scope" -Dependencies @('directory', 'auth', 'projects') -Factory {
        $rows = New-Object Collections.ArrayList
        $employees = New-Object Collections.ArrayList
        $projectCodes = @{}
        if (-not $super -and $access.ProjectCodes.Count -eq 0) { return [PSCustomObject]@{ rows = @(); employees = @() } }
        $users = @(Get-Users | Where-Object { (Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode '') -and -not [bool]$_.disabled } | Sort-Object username)
        $paths = @($users | ForEach-Object { Get-EmployeeDataFilePath -EmployeeCode (Get-UserEmployeeCodeValue $_) })
        Prime-EmployeeFileMetadata -Paths $paths
        Prefetch-EmployeeFileText -Paths $paths
        foreach ($user in $users) {
            $code = Get-UserEmployeeCodeValue $user
            $contribution = Invoke-ReadModelCache -Key "review-employee|$scope|$code" -Dependencies @("employee:$code", 'directory', 'auth', 'projects') -Factory {
                $name = if ($user.displayName) { [string]$user.displayName } else { [string](Get-EmployeeName $code) }
                $role = Get-EffectiveUserRole -UserRecord $user
                $items = New-Object Collections.ArrayList
                foreach ($entry in @(Get-CachedEmployeeEntriesForFile -DataFile (Get-EmployeeDataFilePath -EmployeeCode $code))) {
                    if (-not $super -and -not $access.ProjectCodeSet.ContainsKey([string]$entry.projectCode)) { continue }
                    $status = if ([string]::IsNullOrWhiteSpace([string]$entry.status)) { 'pending' } else { ([string]$entry.status).ToLowerInvariant() }
                    [void]$items.Add([PSCustomObject]@{
                        entry = $entry; employeeCode = $code; employeeName = $name; employeeRole = $role
                        status = $status; open = [bool](Test-EntryOpen $entry)
                        attention = (@(Get-EntryReviewIssues -Entry $entry).Count -gt 0)
                        order = (Get-EntryDateTimeOrMin -Entry $entry)
                    })
                    if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind 'review.entry.indexed' }
                }
                return [PSCustomObject]@{ rows = @($items.ToArray()); employee = [PSCustomObject]@{ employeeCode = $code; employeeName = $name } }
            }
            if ($contribution.rows.Count) { [void]$employees.Add($contribution.employee) }
            foreach ($row in $contribution.rows) {
                [void]$rows.Add($row)
                if ([string]$row.entry.projectCode) { $projectCodes[[string]$row.entry.projectCode] = $true }
            }
        }
        return [PSCustomObject]@{ rows = @($rows | Sort-Object @{ Expression = { $_.order }; Descending = $true }, employeeCode, @{ Expression = { [string]$_.entry.entryId } }); employees = @($employees.ToArray()); projectCodes = @($projectCodes.Keys | Sort-Object) }
    })
}

function New-ReviewPage {
    param($CurrentUser, [string]$Tab = 'pending', [int]$Page = 1, [string]$Search = '',
        [string]$EmployeeCode = '', [string]$ProjectCode = '', [string]$StartDate = '', [string]$EndDate = '',
        [string]$Range = 'default', [switch]$SelectionOnly)
    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) { throw [UnauthorizedAccessException]::new('Manager access is required.') }
    if ($Tab -notin @('pending', 'attention', 'approved', 'rejected') -or $Range -notin @('default', 'all', 'custom') -or $Page -lt 1 -or $Page -gt 100000 -or $Search.Length -gt 200 -or $ProjectCode.Length -gt 200 -or ($EmployeeCode -and $EmployeeCode -notmatch '^\d+$')) { throw [ArgumentException]::new('Invalid review page or filter.') }
    foreach ($date in @($StartDate, $EndDate)) {
        if (-not $date) { continue }
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { throw [ArgumentException]::new('Invalid review date.') }
    }
    if ($StartDate -and $EndDate -and $StartDate -gt $EndDate) { throw [ArgumentException]::new('Review start date must not follow end date.') }
    if ($SelectionOnly -and $Tab -ne 'pending') { throw [ArgumentException]::new('Only pending entries can be batch-selected.') }
    $monthStart = (Get-Date -Day 1).Date.ToString('yyyy-MM-dd')
    $monthEnd = (Get-Date -Day 1).Date.AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd')
    # Pending/issues always cover old unresolved work. History defaults to the
    # current month; explicit date filters apply consistently to every tab.
    $effectiveStart = $StartDate; $effectiveEnd = $EndDate
    if ($Range -eq 'default') {
        $effectiveStart = ''; $effectiveEnd = ''
        if ($Tab -in @('approved', 'rejected')) { $effectiveStart = $monthStart; $effectiveEnd = $monthEnd }
    } elseif ($Range -eq 'all') { $effectiveStart = ''; $effectiveEnd = '' }
    $index = Get-ReviewEntryIndex -CurrentUser $CurrentUser
    $modify = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $super = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $rolePermissions = @{}
    $counts = @{ pending = 0; attention = 0; approved = 0; rejected = 0 }
    $matched = New-Object Collections.ArrayList
    $selection = New-Object Collections.ArrayList
    $actionable = 0
    $tokens = @($Search.Trim() -split '\s+' | Where-Object { $_ })
    foreach ($row in $index.rows) {
        $entry = $row.entry
        if (($EmployeeCode -and $row.employeeCode -ne $EmployeeCode) -or ($ProjectCode -and [string]$entry.projectCode -ne $ProjectCode)) { continue }
        if ($tokens.Count) {
            $statusSearch = switch ($row.status) { 'pending' { 'Pending En attente' } 'approved' { 'Approved Approuvé' } 'rejected' { 'Rejected Rejeté' } default { $row.status } }
            $searchText = @($row.employeeName, $row.employeeCode, $entry.date, $entry.punchIn, $entry.punchOut, $entry.projectCode, $entry.workComment, $entry.message, $entry.messageAuthorName, $entry.messageAuthorUsername, $entry.reasonCode, $entry.overtimeCode, $entry.paymentOption, $entry.entryType, $entry.diverseReason, $entry.diverseSummary, $statusSearch) -join ' '
            $displayDate = Get-EntryDateOrNull -Entry $entry
            if ($null -ne $displayDate) {
                foreach ($culture in @('fr-CA', 'en-CA')) { $searchText += ' ' + $displayDate.ToString('D', [Globalization.CultureInfo]::GetCultureInfo($culture)) }
            }
            $matches = $true
            foreach ($token in $tokens) {
                if ([Globalization.CultureInfo]::InvariantCulture.CompareInfo.IndexOf($searchText, $token, ([Globalization.CompareOptions]::IgnoreCase -bor [Globalization.CompareOptions]::IgnoreNonSpace)) -lt 0) { $matches = $false; break }
            }
            if (-not $matches) { continue }
        }
        $date = [string]$entry.date
        if ($Range -eq 'custom' -and (($StartDate -and $date -lt $StartDate) -or ($EndDate -and $date -gt $EndDate))) { continue }
        $inMonth = ($date -ge $monthStart -and $date -le $monthEnd)
        $pending = ($row.status -eq 'pending' -and -not $row.open)
        if ($pending) { $counts.pending++ }
        if ($row.attention) { $counts.attention++ }
        if (($Range -ne 'default' -or $inMonth) -and $row.status -in @('approved', 'rejected')) { $counts[$row.status]++ }
        $inTab = switch ($Tab) { 'pending' { $pending } 'attention' { $row.attention } default { $row.status -eq $Tab } }
        if (-not $inTab -or ($effectiveStart -and $date -lt $effectiveStart) -or ($effectiveEnd -and $date -gt $effectiveEnd)) { continue }
        [void]$matched.Add($row)
        if ($pending -and -not (Test-EntryForgottenClockOut -Entry $entry)) {
            if (-not $rolePermissions.ContainsKey($row.employeeRole)) { $rolePermissions[$row.employeeRole] = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $row.employeeRole }
            if ($rolePermissions[$row.employeeRole] -and ($super -or (([string]$entry.entryType -ne 'diverse') -and $modify.ProjectCodeSet.ContainsKey([string]$entry.projectCode)))) {
                $actionable++
                if ($SelectionOnly) { [void]$selection.Add([PSCustomObject]@{ employeeCode = $row.employeeCode; entryId = Get-EntryIdentifierValue $entry; date = $entry.date; punchIn = $entry.punchIn }) }
            }
        }
    }
    if ($SelectionOnly) { return [PSCustomObject]@{ selection = @($selection.ToArray()); total = $actionable } }
    $pages = [Math]::Max(1, [int][Math]::Ceiling($matched.Count / 25.0))
    $resolved = [Math]::Min($Page, $pages)
    $items = @(foreach ($row in @($matched | Select-Object -Skip (($resolved - 1) * 25) -First 25)) {
        if (-not $rolePermissions.ContainsKey($row.employeeRole)) { $rolePermissions[$row.employeeRole] = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $row.employeeRole }
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind 'review.entry.projected' }
        # Preserve saved amount pills on explicitly viewed approved cards.
        # Pending pages never need monetary projections or salary calculations.
        New-EmployeeEntryProjectionForAccessModel -EmployeeCode $row.employeeCode -EmployeeName $row.employeeName -Entry $row.entry -ModifyProjectCodeSet $modify.ProjectCodeSet -EmployeeRole $row.employeeRole -IsSuperAdmin:$super -CanApproveEmployeeRole:$rolePermissions[$row.employeeRole] -IncludeMonetary:($row.status -eq 'approved')
    })
    $projects = New-Object Collections.ArrayList
    $knownProjects = @{}
    foreach ($project in @(Get-ProjectsForCurrentUser -CurrentUser $CurrentUser -Scope 'all')) {
        [void]$projects.Add($project); $knownProjects[[string]$project.projectCode] = $true
    }
    foreach ($code in @($index.projectCodes)) {
        if ($code -and -not $knownProjects.ContainsKey($code)) { [void]$projects.Add([PSCustomObject]@{ projectCode = $code; projectName = $code }) }
    }
    return [PSCustomObject]@{
        approvals = $items; tab = $Tab; page = $resolved; pageSize = 25; total = $matched.Count; totalPages = $pages
        counts = [PSCustomObject]$counts; actionableCount = $actionable
        employees = $index.employees; projects = @($projects.ToArray())
        startDate = $effectiveStart; endDate = $effectiveEnd
    }
}

function Get-ReviewPage {
    param($CurrentUser, [string]$Tab = 'pending', [int]$Page = 1, [string]$Search = '',
        [string]$EmployeeCode = '', [string]$ProjectCode = '', [string]$StartDate = '', [string]$EndDate = '',
        [string]$Range = 'default', [switch]$SelectionOnly)
    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) { throw [UnauthorizedAccessException]::new('Manager access is required.') }
    $arguments = @{ CurrentUser = $CurrentUser; Tab = $Tab; Page = $Page; Search = $Search; EmployeeCode = $EmployeeCode; ProjectCode = $ProjectCode; StartDate = $StartDate; EndDate = $EndDate; Range = $Range; SelectionOnly = [bool]$SelectionOnly }
    if ($SelectionOnly) { return (New-ReviewPage @arguments) }
    $scope = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $filterKey = @($Tab, $Page, $Search, $EmployeeCode, $ProjectCode, $StartDate, $EndDate, $Range) | ConvertTo-Json -Compress
    $key = 'review-page|' + $scope + '|' + (Get-Date -Format yyyy-MM) + '|' + $filterKey
    return (Invoke-ReadModelCache -Key $key -Dependencies @('directory', 'auth', 'projects') -Factory { New-ReviewPage @arguments })
}
