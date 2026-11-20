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
    $page = Get-ReviewPage -CurrentUser $super
    Assert-Review ($script:moneyCalls -eq 0) 'Pending Review computed unnecessary monetary projections.'
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
    $readOnly = Get-ReviewPage -CurrentUser $limited -ProjectCode P2
    Assert-Review (@($readOnly.approvals | Where-Object { $_.canApprove -or $_.canModify }).Count -eq 0) 'A read-only project became editable.'
    Assert-Review ((Get-ReviewPage -CurrentUser $limited -SelectionOnly).selection.Count -eq 117) 'Batch selection included a read-only project.'
    $empty = Get-ReviewPage -CurrentUser $super -Search 'no-such-entry'
    Assert-Review ($empty.total -eq 0 -and $empty.page -eq 1 -and $empty.approvals.Count -eq 0) 'Empty results are not stable.'
    foreach ($params in @(@{Page=0}, @{Tab='all'}, @{StartDate='2026-02-31'}, @{Range='bad'}, @{StartDate='2026-10-10';EndDate='2026-01-01'})) {
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
    Write-Host 'Review pagination passed: 40 employees, 320 entries, dates, old pending/issues, facets, pages, all-page bulk selection, permissions, no salary projections and cache invalidation.'
} finally {
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
