function Get-ReviewAttentionFlags {
    param([object[]]$Entries, [Collections.Generic.HashSet[string]]$ValidatedDates)

    $flags = [bool[]]::new($Entries.Length)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $style = [Globalization.DateTimeStyles]::None
    $date = $start = $end = [DateTime]::MinValue
    for ($i = 0; $i -lt $Entries.Length; $i++) {
        $entry = $Entries[$i]
        $forgotten = $entry.forgottenClockOut
        $review = $entry.needsClockOutReview
        if (($null -eq $forgotten -or ($forgotten -is [bool] -and -not $forgotten)) -and
            ($null -eq $review -or ($review -is [bool] -and -not $review))) {
            $punchIn = $entry.exactPunchIn
            $punchOut = $entry.exactPunchOut
            # With no full quarter, at most two partial quarters are touched.
            # If neither overlaps by ten minutes, the span is under 20 min.
            # Only take this shortcut for validated, increasing exact times;
            # all short, missing, malformed and legacy intervals use the rule.
            if ($punchIn -is [string] -and $punchOut -is [string] -and
                [DateTime]::TryParseExact($punchIn, 'HH:mm:ss', $culture, $style, [ref]$start) -and
                [DateTime]::TryParseExact($punchOut, 'HH:mm:ss', $culture, $style, [ref]$end) -and
                ($end.TimeOfDay - $start.TimeOfDay).TotalMinutes -ge 20) {
                $dateKey = [string]$entry.date
                if ($ValidatedDates.Contains($dateKey)) { continue }
                if ([DateTime]::TryParseExact($dateKey, 'yyyy-MM-dd', $culture, $style, [ref]$date)) {
                    [void]$ValidatedDates.Add($dateKey)
                    continue
                }
            }
        }
        $flags[$i] = Get-EntryReviewIssues -Entry $entry -AsBoolean
    }
    return ,$flags
}

# Review keeps private, dependency-aware references in memory. Only the requested
# page becomes public entry DTOs; no employee statistics or salary lookup is used.
function Get-ReviewEntryIndex {
    param($CurrentUser)
    $access = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $super = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $scope = (Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser) + '|' + (@($access.ProjectCodes) -join ',')
    return (Invoke-ReadModelCache -Key "review-index|$scope" -Dependencies @('directory', 'auth', 'projects') -Factory {
        $groups = New-Object Collections.ArrayList
        $employees = New-Object Collections.ArrayList
        $projectCodes = @{}
        $validatedDates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if (-not $super -and $access.ProjectCodes.Count -eq 0) { return [PSCustomObject]@{ groups = @(); employees = @(); projectCodes = @() } }
        $users = @(Get-Users | Where-Object { (Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode '') -and -not [bool]$_.disabled } | Sort-Object username)
        $paths = @($users | ForEach-Object { Get-EmployeeDataFilePath -EmployeeCode (Get-UserEmployeeCodeValue $_) })
        Prime-EmployeeFileMetadata -Paths $paths
        Prefetch-EmployeeFileText -Paths $paths -ParseEntries
        foreach ($user in $users) {
            $code = Get-UserEmployeeCodeValue $user
            $contribution = Invoke-ReadModelCache -Key "review-employee|$scope|$code" -Dependencies @("employee:$code", 'directory', 'auth', 'projects') -Factory {
                $name = if ($user.displayName) { [string]$user.displayName } else { [string](Get-EmployeeName $code) }
                $role = Get-EffectiveUserRole -UserRecord $user
                $entries = @(Get-CachedEmployeeEntriesForFile -DataFile (Get-EmployeeDataFilePath -EmployeeCode $code) -Raw)
                if (-not $super) {
                    $entries = @(foreach ($entry in $entries) {
                        if ($access.ProjectCodeSet.ContainsKey([string]$entry.projectCode)) { $entry }
                    })
                }
                $attention = Get-ReviewAttentionFlags -Entries $entries -ValidatedDates $validatedDates
                $statuses = [string[]]::new($entries.Count)
                $pending = [bool[]]::new($entries.Count)
                $contributionProjectCodes = @{}
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    $entry = $entries[$i]
                    $status = if ([string]::IsNullOrWhiteSpace([string]$entry.status)) { 'pending' } else { ([string]$entry.status).Trim().ToLowerInvariant() }
                    $statuses[$i] = $status
                    $pending[$i] = ($status -eq 'pending' -and (Test-EntryPendingApproval -Entry $entry))
                    $projectCode = [string]$entry.projectCode
                    if ($projectCode) { $contributionProjectCodes[$projectCode] = $true }
                    if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind 'review.entry.indexed' }
                }
                return [PSCustomObject]@{
                    entries = $entries; statuses = $statuses; pending = $pending; attention = $attention
                    employee = [PSCustomObject]@{ employeeCode = $code; employeeName = $name }
                    employeeRole = $role; projectCodes = @($contributionProjectCodes.Keys)
                }
            }
            if (-not $contribution.entries.Count) { continue }
            [void]$employees.Add($contribution.employee)
            [void]$groups.Add($contribution)
            foreach ($projectCode in $contribution.projectCodes) { $projectCodes[$projectCode] = $true }
        }
        return [PSCustomObject]@{ groups = @($groups.ToArray()); employees = @($employees.ToArray()); projectCodes = @($projectCodes.Keys | Sort-Object) }
    })
}

function New-ReviewPage {
    param($CurrentUser, [string]$Tab = 'pending', [int]$Page = 1, [string]$Search = '',
        [string]$EmployeeCode = '', [string]$ProjectCode = '', [string]$StartDate = '', [string]$EndDate = '',
        [string]$Range = 'default', [switch]$SelectionOnly, [switch]$ActionableOnly)
    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) { throw [UnauthorizedAccessException]::new('Manager access is required.') }
    if ($Tab -notin @('pending', 'attention', 'approved', 'rejected') -or $Range -notin @('default', 'all', 'custom') -or $Page -lt 1 -or $Page -gt 100000 -or $Search.Length -gt 200 -or $ProjectCode.Length -gt 200 -or ($EmployeeCode -and $EmployeeCode -notmatch '^\d+$')) { throw [ArgumentException]::new('Invalid review page or filter.') }
    foreach ($date in @($StartDate, $EndDate)) {
        if (-not $date) { continue }
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { throw [ArgumentException]::new('Invalid review date.') }
    }
    if ($StartDate -and $EndDate -and $StartDate -gt $EndDate) { throw [ArgumentException]::new('Review start date must not follow end date.') }
    if (($SelectionOnly -or $ActionableOnly) -and $Tab -ne 'pending') { throw [ArgumentException]::new('The approval filter is only available for pending entries.') }
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
    $ownEmployeeCode = ([string]$CurrentUser.employeeCode).Trim()
    $rolePermissions = @{}
    $counts = @{ pending = 0; attention = 0; approved = 0; rejected = 0 }
    $matched = New-Object Collections.ArrayList
    $actionable = 0
    $tokens = @($Search.Trim() -split '\s+' | Where-Object { $_ })
    $pendingTab = $Tab -eq 'pending'
    $attentionTab = $Tab -eq 'attention'
    $searchingDates = $Range -eq 'custom'
    $currentMonthHistory = $Range -eq 'default'
    foreach ($group in $index.groups) {
        $code = $group.employee.employeeCode
        if ($EmployeeCode -and $code -ne $EmployeeCode) { continue }
        $name = $group.employee.employeeName
        $role = $group.employeeRole
        $isOwnEmployee = ($ownEmployeeCode -and $code.Trim() -eq $ownEmployeeCode)
        for ($i = 0; $i -lt $group.entries.Count; $i++) {
            $entry = $group.entries[$i]
            if ($ProjectCode -and [string]$entry.projectCode -ne $ProjectCode) { continue }
            $date = [string]$entry.date
            if ($searchingDates -and (($StartDate -and $date -lt $StartDate) -or ($EndDate -and $date -gt $EndDate))) { continue }
            $status = $group.statuses[$i]
            if ($tokens.Count) {
                $statusSearch = switch ($status) { 'pending' { 'Pending En attente' } 'approved' { 'Approved Approuvé' } 'rejected' { 'Rejected Rejeté' } default { $status } }
                $entryType = Saphir.BusinessRules\ConvertTo-SaphirEntryType -Value ([string]$entry.entryType)
                $payment = [string]$entry.paymentOption
                if ([string]::IsNullOrWhiteSpace($payment) -and $entryType -eq 'overtime') { $payment = 'cash' }
                $searchText = @($name, $code, $entry.date, $entry.punchIn, $entry.punchOut, $entry.projectCode, $entry.workComment, $entry.message, $entry.messageAuthorName, $entry.messageAuthorUsername, $entry.reasonCode, $entry.overtimeCode, $payment, $entryType, $entry.diverseReason, $entry.diverseSummary, $statusSearch) -join ' '
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
            $pending = $group.pending[$i]
            $attention = $group.attention[$i]
            if ($pending) { $counts.pending++ }
            if ($attention) { $counts.attention++ }
            if (($status -eq 'approved' -or $status -eq 'rejected') -and
                (-not $currentMonthHistory -or ($date -ge $monthStart -and $date -le $monthEnd))) { $counts[$status]++ }
            $inTab = if ($pendingTab) { $pending } elseif ($attentionTab) { $attention } else { $status -eq $Tab }
            if (-not $inTab -or ($effectiveStart -and $date -lt $effectiveStart) -or ($effectiveEnd -and $date -gt $effectiveEnd)) { continue }
            $canAct = $false
            if ($pending -and -not $isOwnEmployee) {
                if (-not $rolePermissions.ContainsKey($role)) { $rolePermissions[$role] = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $role }
                if ($rolePermissions[$role] -and ($super -or ((([string]$entry.entryType).Trim().ToLowerInvariant() -ne 'diverse') -and $modify.ProjectCodeSet.ContainsKey([string]$entry.projectCode)))) {
                    $canAct = $true
                    $actionable++
                }
            }
            if ((-not $SelectionOnly -and -not $ActionableOnly) -or $canAct) {
                [void]$matched.Add([PSCustomObject]@{
                    entry = $entry; employeeCode = $code; employeeName = $name; employeeRole = $role; status = $status
                })
            }
        }
    }
    # The index only needs to count out-of-tab entries. Parse dates and sort
    # once after the tab, date, employee and authorization filters.
    $sorted = @($matched | Sort-Object @{ Expression = { Get-EntryDateTimeOrMin -Entry $_.entry }; Descending = $true }, employeeCode, @{ Expression = { [string](Get-EntryIdentifierValue $_.entry) } })
    if ($SelectionOnly) {
        $selection = @(foreach ($row in $sorted) {
            [PSCustomObject]@{ employeeCode = $row.employeeCode; entryId = Get-EntryIdentifierValue $row.entry; date = [string]$row.entry.date; punchIn = [string]$row.entry.punchIn }
        })
        return [PSCustomObject]@{ selection = $selection; total = $actionable }
    }
    $pages = [Math]::Max(1, [int][Math]::Ceiling($matched.Count / 25.0))
    $resolved = [Math]::Min($Page, $pages)
    $items = @(foreach ($row in @($sorted | Select-Object -Skip (($resolved - 1) * 25) -First 25)) {
        if (-not $rolePermissions.ContainsKey($row.employeeRole)) { $rolePermissions[$row.employeeRole] = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $row.employeeRole }
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind 'review.entry.projected' }
        # Preserve saved amount pills on explicitly viewed approved cards.
        # Pending pages never need monetary projections or salary calculations.
        $isOwnEntry = ($ownEmployeeCode -and $row.employeeCode.Trim() -eq $ownEmployeeCode)
        $entry = ConvertTo-EmployeeFileReadEntry -Entry $row.entry
        New-EmployeeEntryProjectionForAccessModel -EmployeeCode $row.employeeCode -EmployeeName $row.employeeName -Entry $entry -ModifyProjectCodeSet $modify.ProjectCodeSet -EmployeeRole $row.employeeRole -IsSuperAdmin:$super -CanApproveEmployeeRole:$rolePermissions[$row.employeeRole] -IncludeMonetary:($row.status -eq 'approved') -IsOwnEntry:$isOwnEntry
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
        [string]$Range = 'default', [switch]$SelectionOnly, [switch]$ActionableOnly)
    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) { throw [UnauthorizedAccessException]::new('Manager access is required.') }
    $arguments = @{ CurrentUser = $CurrentUser; Tab = $Tab; Page = $Page; Search = $Search; EmployeeCode = $EmployeeCode; ProjectCode = $ProjectCode; StartDate = $StartDate; EndDate = $EndDate; Range = $Range; SelectionOnly = [bool]$SelectionOnly; ActionableOnly = [bool]$ActionableOnly }
    if ($SelectionOnly) { return (New-ReviewPage @arguments) }
    $scope = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $filterKey = @($Tab, $Page, $Search, $EmployeeCode, $ProjectCode, $StartDate, $EndDate, $Range, [bool]$ActionableOnly) | ConvertTo-Json -Compress
    $key = 'review-page|' + $scope + '|' + (Get-Date -Format yyyy-MM) + '|' + $filterKey
    return (Invoke-ReadModelCache -Key $key -Dependencies @('directory', 'auth', 'projects') -Factory { New-ReviewPage @arguments })
}
