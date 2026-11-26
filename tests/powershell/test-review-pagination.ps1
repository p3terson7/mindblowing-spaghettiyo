param([switch]$Isolated)
$ErrorActionPreference = 'Stop'
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw 'Review pagination regression failed.' }; return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$owned = Join-Path ([IO.Path]::GetTempPath()) ('review-page-test-' + [guid]::NewGuid().ToString('N'))
function Assert-Review($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    . (Join-Path $repo 'tests/lib/CacheCoherenceFixture.ps1') -FixtureFolder $owned -Create -EmployeeCount 40
    # Compare the batch shortcut with the full warnings on both sides of the
    # quarter/ten-minute boundaries, including legacy and invalid stored data.
    $basis = [DateTime]::new(2026, 11, 4, 14, 0, 0)
    $timings = @(foreach ($offset in @(0, 1, 299, 300, 301, 599, 600, 899)) {
        foreach ($seconds in @(599, 600, 601, 900, 1198, 1199, 1200, 1201, 3600)) {
            [PSCustomObject]@{
                date = '2026-11-04'
                exactPunchIn = $basis.AddSeconds($offset).ToString('HH:mm:ss')
                exactPunchOut = $basis.AddSeconds($offset + $seconds).ToString('HH:mm:ss')
            }
        }
    })
    $timings += @(
        [PSCustomObject]@{ date = '2026-11-31'; exactPunchIn = '14:00:00'; exactPunchOut = '15:00:00' }
        [PSCustomObject]@{ date = '2026-11-04'; exactPunchIn = '23:00:00'; exactPunchOut = '24:00:00' }
        [PSCustomObject]@{ date = '2026-11-04'; exactPunchIn = '23:59:59'; exactPunchOut = '00:30:00' }
        [PSCustomObject]@{ date = '2026-11-04'; exactPunchIn = '14:00:00'; exactPunchOut = '15:00:00'; forgottenClockOut = $true }
        [PSCustomObject]@{ date = '2026-11-04'; exactPunchIn = '14:00:00'; exactPunchOut = '15:00:00'; needsClockOutReview = ' YES ' }
        [PSCustomObject]@{ date = '2026-11-04'; exactPunchIn = '14:00:00'; exactPunchOut = '14:08:00'; gc179SourceFile = 'synthetic' }
        [PSCustomObject]@{ date = '2026-11-04'; punchIn = ' 9:20 '; punchOut = ' 9:30 ' }
        [PSCustomObject]@{ date = '2026-11-04'; punchIn = '14:00:00' }
        $null
    )
    $dates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $flags = Get-ReviewAttentionFlags -Entries $timings -ValidatedDates $dates
    $expectedFlags = @(foreach ($timing in $timings) { @(Get-EntryReviewIssues -Entry $timing).Count -gt 0 })
    Assert-Review ($flags -is [bool[]] -and ($flags -join ',') -ceq ($expectedFlags -join ',')) 'Fast attention flags disagree with the full warnings.'
    Assert-Review ($dates.Count -eq 1 -and $dates.Contains('2026-11-04')) 'Dates were not validated once or an invalid date entered the fast path.'
    Assert-Review ((Get-ReviewAttentionFlags -Entries @() -ValidatedDates $dates).Length -eq 0) 'An empty employee produced a review flag.'

    $today = Get-Date -Format 'yyyy-MM-dd'
    $old = (Get-Date).AddMonths(-8).ToString('yyyy-MM-dd')
    foreach ($n in 1..40) {
        $code = '{0:000000000}' -f (710000 + $n)
        $path = Join-Path $owned ($code + '_data.json')
        $base = @(Read-JsonArrayFile $path)[0]
        $items = @(foreach ($i in 1..8) {
            $item = $base.PSObject.Copy(); $item.entryId = "$code-$i"
            $item.status = if ($i -le 3) { 'pending' } elseif ($i -le 6) { 'approved' } else { 'rejected' }
            $item.date = if ($i -in @(1, 6, 8)) { $old } else { $today }
            if ($i -eq 3) { $item.exactPunchOut = '17:04:00'; $item.punchOut = '17:04:00'; $item.overtime = '00:00:00' }
            if ($n -eq 1 -and $i -eq 1) {
                $item | Add-Member entryType 'legacy-unknown' -Force
                $item | Add-Member paymentOption ' ' -Force
                $item | Add-Member workSchedule ' STANDARD ' -Force
            }
            $item
        })
        Write-CoherenceFixtureJson $path $items
    }
    Clear-AllEmployeeEntryCaches
    $super = Get-UserByUsername -Username 'audit-super'
    $limited = Get-UserByUsername -Username 'audit-limited'
    function Get-CompensationGrid { throw 'Review attempted a salary lookup.' }
    $moneyProjection = ${function:New-EntryMonetaryReadModel}
    $script:moneyCalls = 0
    function New-EntryMonetaryReadModel { param($Entry) $script:moneyCalls++; & $moneyProjection -Entry $Entry }
    $normalize = (Get-Command Convert-ToNormalizedEntryObject).ScriptBlock
    $script:reviewNormalizations = 0
    function Convert-ToNormalizedEntryObject { param($Entry) $script:reviewNormalizations++; & $normalize -Entry $Entry }
    $entryTime = (Get-Command Get-EntryDateTimeOrMin).ScriptBlock
    $script:reviewSortDates = 0
    function Get-EntryDateTimeOrMin { param($Entry) $script:reviewSortDates++; & $entryTime -Entry $Entry }
    $page = Get-ReviewPage -CurrentUser $super
    Assert-Review ($script:moneyCalls -eq 0) 'Pending Review computed unnecessary monetary projections.'
    Assert-Review ($script:reviewNormalizations -eq 25) 'Review normalized entries outside the requested page.'
    Assert-Review ($script:reviewSortDates -eq 120) 'Review sorted dates outside the requested tab.'
    Assert-Review ($page.approvals.Count -eq 25 -and $page.total -eq 120 -and $page.totalPages -eq 5 -and $page.pageSize -eq 25) 'Review did not page pending entries.'
    Assert-Review ($page.counts.approved -eq 80 -and $page.counts.rejected -eq 40 -and $page.counts.attention -eq 40) 'Default counts must retain old unresolved work but limit historical states to this month.'
    Assert-Review ($page.employees.Count -eq 40) 'Employee filters were limited to the first page.'
    $next = Get-ReviewPage -CurrentUser $super -Page 2
    Assert-Review (@($next.approvals | Where-Object { $page.approvals.entryId -contains $_.entryId }).Count -eq 0) 'Pages overlap.'
    $last = Get-ReviewPage -CurrentUser $super -Page 999
    Assert-Review ($last.page -eq 5 -and $last.approvals.Count -eq 20) 'Last page was not clamped.'
    $history = Get-ReviewPage -CurrentUser $super -Tab approved
    Assert-Review ($script:moneyCalls -eq 25 -and $history.approvals[0].PSObject.Properties.Name -contains 'monetary') 'Approved cards lost their saved amounts or projected amounts outside the requested page.'
    Assert-Review ($history.total -eq 80 -and $history.startDate -eq (Get-Date -Day 1).ToString('yyyy-MM-dd')) 'Approved entries did not default to the current month.'
    Assert-Review ((Get-ReviewPage -CurrentUser $super -Tab approved -Range all).total -eq 120) 'All dates did not include old approvals.'
    Assert-Review ((Get-ReviewPage -CurrentUser $super -Range custom -StartDate $old -EndDate $old).total -eq 40) 'Explicit date filtering changed.'
    $employee = Get-ReviewPage -CurrentUser $super -EmployeeCode '000710002'
    Assert-Review ($employee.total -eq 3 -and $employee.approvals.Count -eq 3) 'Employee filter failed.'
    Assert-Review ((Get-ReviewPage -CurrentUser $super -ProjectCode P2).total -eq 3) 'Project filter failed.'
    $selection = Get-ReviewPage -CurrentUser $super -SelectionOnly
    Assert-Review ($selection.selection.Count -eq 120 -and $selection.selection[0].PSObject.Properties.Name -notcontains 'workComment') 'Bulk selection did not cover all pages with minimal keys.'
    $scoped = Get-ReviewPage -CurrentUser $limited
    Assert-Review ($scoped.total -eq 120) 'Existing manager read visibility changed.'
    $mine = Get-ReviewPage -CurrentUser $limited -ActionableOnly -Page 5
    Assert-Review ($mine.total -eq 117 -and $mine.approvals.Count -eq 17 -and $mine.counts.pending -eq 120) 'Eligibility was applied after pagination or replaced the full pending count.'
    Assert-Review (@($mine.approvals | Where-Object { -not $_.canApprove -or $_.projectCode -eq 'P2' }).Count -eq 0) 'Eligible pages contain entries the manager cannot approve.'
    Assert-Review ((Get-ReviewPage -CurrentUser $limited -ActionableOnly -ProjectCode P2).total -eq 0) 'Eligible mode ignored the project filter.'
    Assert-Review ((Get-ReviewPage -CurrentUser $limited -ActionableOnly -Range custom -StartDate $old -EndDate $old).total -eq 39) 'Eligible mode ignored the date filter.'
    $readOnly = Get-ReviewPage -CurrentUser $limited -ProjectCode P2
    Assert-Review (@($readOnly.approvals | Where-Object { $_.canApprove -or $_.canModify }).Count -eq 0) 'A read-only project became editable.'
    Assert-Review ((Get-ReviewPage -CurrentUser $limited -SelectionOnly).selection.Count -eq 117) 'Batch selection included a read-only project.'
    $empty = Get-ReviewPage -CurrentUser $super -Search 'no-such-entry'
    Assert-Review ($empty.total -eq 0 -and $empty.page -eq 1 -and $empty.approvals.Count -eq 0) 'Empty results are not stable.'
    $legacy = Get-ReviewPage -CurrentUser $super -EmployeeCode '000710001' -Search 'cash overtime' -Range custom -StartDate $old -EndDate $old
    Assert-Review ($legacy.total -eq 1 -and $legacy.approvals[0].entryType -eq 'overtime' -and $legacy.approvals[0].paymentOption -eq 'cash' -and $legacy.approvals[0].workSchedule -eq 'regular') 'Raw reads changed legacy search defaults or card normalization.'
    foreach ($params in @(@{Page=0}, @{Tab='all'}, @{StartDate='2026-02-31'}, @{Range='bad'}, @{Tab='approved';ActionableOnly=$true}, @{StartDate='2026-10-10';EndDate='2026-01-01'})) {
        $failed = $false
        try { Get-ReviewPage -CurrentUser $super @params | Out-Null } catch [ArgumentException] { $failed = $true }
        Assert-Review $failed 'Invalid review query did not fail validation.'
    }
    $user = Get-UserByUsername -Username '000710001'; $denied = $false
    try { Get-ReviewPage -CurrentUser $user | Out-Null } catch [UnauthorizedAccessException] { $denied = $true }
    Assert-Review $denied 'Non-managers can query Review.'
    # Cached references are invalidated by the existing employee dependency.
    Invoke-CoherenceFixtureMutation -Code '000710001' -Operation approve
    Assert-Review ((Get-ReviewPage -CurrentUser $super).total -eq 119) 'Published entry changes left stale Review pages.'

    # Open and forgotten rows should not become approvals. The same manager
    # must get the same closed count/actionable count from both read models.
    $fixtureCode = '000710001'
    $path = Join-Path $owned ($fixtureCode + '_data.json')
    $entries = @(Read-JsonArrayFile $path)
    $open = $entries[1].PSObject.Copy()
    $open.entryId = 'open-review'; $open.punchOut = $null; $open.exactPunchOut = $null; $open.overtime = $null
    $forgotten = $open.PSObject.Copy(); $forgotten.entryId = 'forgotten-review'
    $forgotten | Add-Member -NotePropertyName needsClockOutReview -NotePropertyValue $true
    Write-CoherenceFixtureJson $path @($entries + @($open, $forgotten))
    Publish-DataChange -Category employee -Resource $fixtureCode | Out-Null
    $selfSuper = $super.PSObject.Copy()
    $selfSuper | Add-Member -NotePropertyName employeeCode -NotePropertyValue $fixtureCode -Force
    foreach ($manager in @($limited, $selfSuper)) {
        $dashboard = Get-DashboardBootstrapModel -CurrentUser $manager
        $review = Get-ReviewPage -CurrentUser $manager
        $eligible = Get-ReviewPage -CurrentUser $manager -ActionableOnly -SelectionOnly
        Assert-Review ($dashboard.pendingApprovals -eq 119 -and $dashboard.pendingApprovals -eq $review.total -and $dashboard.activeEmployees -eq 1) 'Dashboard and Review disagree on closed pending entries.'
        Assert-Review ($dashboard.actionableCount -eq $review.actionableCount -and $dashboard.actionableCount -eq $eligible.selection.Count) 'Dashboard, Review and batch selection disagree on eligibility.'
        Assert-Review ($dashboard.pendingQueue.Count -eq 6 -and $dashboard.pendingQueue.entryId -notcontains 'forgotten-review') 'Dashboard fetched more than the six-item approval preview or showed a missing end as pending.'
        $attention = Get-ReviewPage -CurrentUser $manager -Tab attention -EmployeeCode $fixtureCode
        Assert-Review ($attention.approvals.entryId -contains 'forgotten-review' -and $attention.approvals.entryId -notcontains 'open-review') 'A forgotten end became invisible or an active session was flagged.'
    }
    $own = Get-ReviewPage -CurrentUser $selfSuper -EmployeeCode $fixtureCode
    Assert-Review ($own.total -eq 2 -and $own.actionableCount -eq 0 -and @($own.approvals | Where-Object { $_.canApprove -or $_.permissionReason -ne 'ownEntry' }).Count -eq 0) 'Even a super admin may not approve their own entries.'
    $other = Get-ReviewPage -CurrentUser $selfSuper -ActionableOnly -SelectionOnly
    Assert-Review ($other.selection.employeeCode -notcontains $fixtureCode) 'Batch selection included the signed-in employee.'

    # Reassign a project after its empty actionable page is already cached.
    $projects = @(Read-JsonArrayFile $projectsFile)
    ($projects | Where-Object projectCode -eq 'P2').admins = @($limited.employeeCode)
    Write-CoherenceFixtureJson $projectsFile $projects
    Publish-DataChange -Category project -Resource 'P2' | Out-Null
    Assert-Review ((Get-ReviewPage -CurrentUser $limited -ActionableOnly -ProjectCode P2).total -eq 3) 'Project permission change left a stale actionable page.'
    Write-Host 'Review pagination passed: 40 employees, roles, dates, shared counts, before-page eligibility, no self-approval, batch selection, and cache invalidation.'
} finally {
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
