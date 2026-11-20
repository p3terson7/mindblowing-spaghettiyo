param([switch]$Isolated)
$ErrorActionPreference = "Stop"
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw "Lazy view regression failed." }; return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$owned = Join-Path ([IO.Path]::GetTempPath()) ("saphir-lazy-view-test-" + [Guid]::NewGuid().ToString("N"))
function Assert-Lazy($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $owned -Create -EmployeeCount 40
    $manager = Get-UserByUsername "audit-super"
    $limited = Get-UserByUsername "audit-limited"
    $readEntries = (Get-Command Get-CachedEmployeeEntriesForFile).ScriptBlock
    function Get-CachedEmployeeEntriesForFile { throw "Initial directory/history must not touch entry files." }
    $rows = @(Get-EmployeeDirectoryList -CurrentUser $manager -MetadataOnly -Scope active)
    Assert-Lazy ($rows.Count -eq 41) "Initial directory lost employees."
    Assert-Lazy ($rows[0].statsLoaded -eq $false -and $rows[0].PSObject.Properties.Name -notcontains "monetary") "Initial directory computed monetary statistics."
    $limitedRows = @(Get-EmployeeDirectoryList -CurrentUser $limited -MetadataOnly -Scope active)
    Assert-Lazy ($limitedRows.Count -eq 41) "Manager directory visibility changed."
    $before = $rows[0]
    Publish-DataChange -Category employee -Resource "000710001" | Out-Null
    Assert-Lazy ([object]::ReferenceEquals($before, @(Get-EmployeeDirectoryList -CurrentUser $manager -MetadataOnly -Scope active)[0])) "An entry mutation invalidated metadata-only directory rows."

    Write-CoherenceFixtureJson $historyFile @(foreach ($index in 1..167) { [PSCustomObject]@{ action = if ($index % 2) { "Add" } else { "Update" }; employee = "000710001"; timestamp = "2026-10-01 12:00:00"; message = "Action $index"; id = $index } })
    $page1 = Get-HistoryPage; $page2 = Get-HistoryPage -Page 2; $last = Get-HistoryPage -Page 999
    Assert-Lazy ($page1.items.Count -eq 25 -and $page1.total -eq 167 -and $page1.pageSize -eq 25) "History is not server-paged in groups of 25."
    Assert-Lazy ($page2.items.Count -eq 25 -and @($page1.items | Where-Object { $page2.items.id -contains $_.id }).Count -eq 0) "History pages overlap."
    Assert-Lazy ($last.page -eq 7 -and $last.items.Count -eq 17) "Last history page is incorrect."
    Assert-Lazy ((Get-HistoryPage -Category add).total -eq 84) "Server-side action filter is incorrect."
    Assert-Lazy ((Get-HistoryPage -Search "Employee 1").total -eq 167) "History search lost resolved employee names."
    Assert-Lazy ((Get-HistoryPage -Search "Ajoutee").total -eq 84) "History search lost translated/accent-insensitive action labels."
    Assert-Lazy ((Get-HistoryPage -Search "octobre").total -eq 167) "History search lost translated dates."
    Assert-Lazy ((Get-HistoryPage -StartDate 2026-10-02).total -eq 0) "Server date filter is incorrect."
    foreach ($arguments in @(@{ Page = 0 }, @{ Page = -1 }, @{ Category = "invalid" }, @{ StartDate = "not-a-date" })) {
        $failed = $false; try { Get-HistoryPage @arguments | Out-Null } catch [ArgumentException] { $failed = $true }
        Assert-Lazy $failed "Invalid history pagination/filter was accepted."
    }
    Write-JsonArrayAtomic $historyFile @([PSCustomObject]@{ timestamp = "2026-10-02 00:00:00"; employee = "000710001"; action = "Delete"; message = "New action" })
    Publish-DataChange -Category history -Resource "000710001" | Out-Null
    Assert-Lazy ((Get-HistoryPage).total -eq 1) "History publication retained stale pages."
    Set-Item Function:Get-CachedEmployeeEntriesForFile $readEntries
    $users = @(Get-Users); ($users | Where-Object username -eq "000710040").disabled = $true
    Write-JsonArrayAtomic $usersFile $users; Publish-DataChange -Category auth -Resource "000710040" | Out-Null
    Assert-Lazy (@(Get-EmployeeDirectoryList -CurrentUser $manager -MetadataOnly -Scope active).Count -eq 40) "Archived employee leaked into active scope."
    $script:filesRead = @()
    function Get-CachedEmployeeEntriesForFile {
        param($DataFile, [switch]$IncludeMonetary)
        $script:filesRead += [IO.Path]::GetFileName($DataFile)
        & $readEntries -DataFile $DataFile -IncludeMonetary:$IncludeMonetary
    }
    $archived = @(Get-EmployeeDirectoryList -CurrentUser $manager -IncludeDisabled:$true -Scope archived)
    Assert-Lazy ($archived.Count -eq 1 -and $script:filesRead.Count -eq 1 -and $script:filesRead[0] -eq "000710040_data.json") "Archived statistics read unrelated active employee files."
    $metadataProbe = (Get-Command Get-FileItemWithRetry).ScriptBlock
    $script:entryMetadataProbes = 0
    function Get-FileItemWithRetry {
        param([string]$Path)
        if ($Path -match '_data\.json$') { $script:entryMetadataProbes++ }
        & $metadataProbe -Path $Path
    }
    Get-ProjectStatisticsOverview -CurrentUser $manager | Out-Null
    Assert-Lazy ($script:entryMetadataProbes -eq 0) "Projects repeated per-employee stat calls after its cold metadata batch."
    function Prime-EmployeeFileMetadata { throw "Directory listing unavailable; direct files still readable." }
    Remove-DependentReadModels -ChangedSources @("projects")
    $fallback = Get-ProjectStatisticsOverview -CurrentUser $manager
    Assert-Lazy ($null -ne $fallback) "Optional Projects metadata scan failure broke normal direct-file loading."
    Write-Host "Lazy views passed: metadata-only directory, scoped statistics, pagination/filtering and selective invalidation."
} finally { if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force } }
