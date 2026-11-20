param([switch]$Isolated)
$ErrorActionPreference = "Stop"
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw "Projects lazy loading regression failed." }; return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$owned = Join-Path ([IO.Path]::GetTempPath()) ("saphir-project-loading-" + [Guid]::NewGuid().ToString("N"))
function Assert-ProjectLoading($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $owned -Create -EmployeeCount 4
    $users = @(Read-JsonArrayFile $usersFile)
    ($users | Where-Object employeeCode -eq "000710004").disabled = $true
    # An administrator's entries require super-admin approval, even when an
    # ordinary admin can modify the project.
    ($users | Where-Object employeeCode -eq "000710003").role = "admin"
    Write-CoherenceFixtureJson $usersFile $users
    foreach ($code in @("000710001", "000710002", "000710003", "000710004")) {
        $path = Join-Path $owned "$($code)_data.json"
        $seed = @(Read-JsonArrayFile $path)[0]
        $entries = @(foreach ($month in 1..10) {
            $entry = $seed.PSObject.Copy()
            $entry.entryId = "$code-$month"
            $entry.date = "2026-{0:00}-05" -f $month
            $entry.status = "approved"
            $entry | Add-Member compensationSnapshot ([PSCustomObject]@{
                snapshotStatus = "final"; currency = "CAD"; paymentOption = "cash"
                totalAmountCents = 12345; cashAmountCents = 12345; compensatoryLeaveValueCents = 0
                annualSalaryCents = 9999999; classification = @{ private = "do not expose" }
            })
            $entry
        })
        Write-CoherenceFixtureJson $path $entries
    }
    $manager = Get-UserByUsername "audit-super"
    $limited = Get-UserByUsername "audit-limited"
    $ordinaryEmployee = Get-UserByUsername "000710001"
    $start = "2026-10-01"; $end = "2026-10-14"
    $projection = (Get-Command New-EmployeeEntryProjectionForAccessModel).ScriptBlock
    $reviewIssues = (Get-Command Get-EntryReviewIssues).ScriptBlock
    $script:projectProjectionIds = @()
    function New-EmployeeEntryProjectionForAccessModel { throw "The portfolio must not project entry details." }
    function Get-EntryReviewIssues { throw "The portfolio must not compute review issues." }
    $initial = Get-ProjectsBootstrapModel -Scope all -IncludeDetail:$false -StartDate $start -EndDate $end -CurrentUser $manager
    $p1 = @($initial.summary | Where-Object projectCode -eq P1)[0]
    $p2 = @($initial.summary | Where-Object projectCode -eq P2)[0]
    Assert-ProjectLoading ($p1.totalSeconds -eq 10800 -and $p2.totalSeconds -eq 3600) "Period filtering/archived employee totals changed."
    Assert-ProjectLoading ($p1.monetary.totalAmountCents -eq 37035 -and $p1.departmentShare.percent -eq 75) "Money or department-share denominator changed."
    Assert-ProjectLoading ($initial.trends.P1[0].seconds -eq 10800) "Trends do not match approved totals."
    Assert-ProjectLoading ($null -eq $initial.selectedProject) "Initial portfolio eagerly loaded a detail."
    Assert-ProjectLoading (@(Get-ProjectStatisticsEntriesSnapshot -CurrentUser $ordinaryEmployee).Count -eq 0) "An employee reused a manager's internal snapshot."

    function Get-EntryReviewIssues { param($Entry) & $reviewIssues -Entry $Entry }
    function New-EmployeeEntryProjectionForAccessModel {
        param($EmployeeCode, $EmployeeName, $Entry, $ModifyProjectCodeSet, $EmployeeRole, [bool]$IsSuperAdmin, [bool]$CanApproveEmployeeRole)
        $script:projectProjectionIds += [string]$Entry.entryId
        & $projection -EmployeeCode $EmployeeCode -EmployeeName $EmployeeName -Entry $Entry -ModifyProjectCodeSet $ModifyProjectCodeSet -EmployeeRole $EmployeeRole -IsSuperAdmin:$IsSuperAdmin -CanApproveEmployeeRole:$CanApproveEmployeeRole
    }
    $detail = Get-ProjectDetailModel -ProjectCode P1 -StartDate $start -EndDate $end -CurrentUser $manager
    Assert-ProjectLoading ($script:projectProjectionIds.Count -eq 3 -and @($script:projectProjectionIds | Where-Object { $_ -notmatch '-10$' -or $_ -match '^000710002-' }).Count -eq 0) "Selected project projected unrelated projects or old dates."
    Assert-ProjectLoading ($detail.contributors.Count -eq 3 -and $detail.recentEntries.Count -eq 3) "Compact detail lost contributors or recent entries."
    Assert-ProjectLoading (@($detail.contributors | Where-Object { $_.PSObject.Properties.Name -contains "entries" }).Count -eq 0) "Detail repeats every entry inside contributor summaries."
    $json = $detail | ConvertTo-Json -Depth 12 -Compress
    foreach ($privateField in @("rawEntry", "compensationSnapshot", "annualSalaryCents", "classification")) {
        Assert-ProjectLoading (-not $json.Contains('"' + $privateField + '"')) "Private $privateField leaked into project JSON."
    }
    Assert-ProjectLoading ([object]::ReferenceEquals($detail, (Get-ProjectDetailModel -ProjectCode P1 -StartDate $start -EndDate $end -CurrentUser $manager))) "Warm detail was not cached."
    Assert-ProjectLoading ($script:projectProjectionIds.Count -eq 3) "Warm detail repeated entry projections."
    Publish-DataChange -Category bug-reports -Resource issue | Out-Null
    Assert-ProjectLoading ([object]::ReferenceEquals($detail, (Get-ProjectDetailModel -ProjectCode P1 -StartDate $start -EndDate $end -CurrentUser $manager))) "Unrelated ticket edit invalidated a project detail."

    $limitedP1 = Get-ProjectDetailModel -ProjectCode P1 -StartDate $start -EndDate $end -CurrentUser $limited
    $limitedP2 = Get-ProjectDetailModel -ProjectCode P2 -StartDate $start -EndDate $end -CurrentUser $limited
    Assert-ProjectLoading ($limitedP1.recentEntries[0].canModify -and -not $limitedP2.recentEntries[0].canModify) "Project modification permissions were widened by the lean read path."
    $adminEntry = @($limitedP1.recentEntries | Where-Object employeeCode -eq "000710003")[0]
    Assert-ProjectLoading ($adminEntry.canModify -and -not $adminEntry.canApprove -and $adminEntry.permissionReason -eq "superAdminApproval") "Supervisor approval permissions changed."

    $unchangedFact = @(Get-ProjectStatisticsEntriesSnapshot -CurrentUser $manager | Where-Object entryId -eq "000710002-10")[0]
    $path = Join-Path $owned "000710001_data.json"
    $entries = @(Read-JsonArrayFile $path)
    $entries[-1].overtime = "02:00:00"
    Write-JsonArrayAtomic -Path $path -Items $entries -Depth 14
    Publish-DataChange -Category employee -Resource "000710001" | Out-Null
    $updated = Get-ProjectDetailModel -ProjectCode P1 -StartDate $start -EndDate $end -CurrentUser $manager
    Assert-ProjectLoading ($updated.totalSeconds -eq 14400 -and -not [object]::ReferenceEquals($detail, $updated)) "An employee change did not invalidate cached project totals/details."
    $sameFact = @(Get-ProjectStatisticsEntriesSnapshot -CurrentUser $manager | Where-Object entryId -eq "000710002-10")[0]
    Assert-ProjectLoading ([object]::ReferenceEquals($unchangedFact, $sameFact)) "Changing one employee rebuilt another employee's facts."

    # Forgotten clock-out flags must remain open/excluded from approved totals,
    # even if a legacy entry has a punchOut and approved status.
    $entries[-1] | Add-Member forgottenClockOut $true -Force
    Write-JsonArrayAtomic -Path $path -Items $entries -Depth 14
    Publish-DataChange -Category employee -Resource "000710001" | Out-Null
    $flagged = @(Get-ProjectSummaryList -StartDate $start -EndDate $end -CurrentUser $manager | Where-Object projectCode -eq P1)[0]
    Assert-ProjectLoading ($flagged.totalSeconds -eq 7200 -and $flagged.statusBuckets.open.count -eq 1 -and $flagged.monetary.totalAmountCents -eq 24690) "Lean facts lost forgotten-clock-out exclusion."

    $extra = @(foreach ($index in 1..30) {
        $entry = $entries[-1].PSObject.Copy()
        $entry.entryId = "extra-$index"; $entry.date = "2026-10-06"
        $entry.forgottenClockOut = $false
        if ($index -eq 30) { $entry.PSObject.Properties.Remove("compensationSnapshot") }
        $entry
    })
    Write-JsonArrayAtomic -Path $path -Items @($entries + $extra) -Depth 14
    Publish-DataChange -Category employee -Resource "000710001" | Out-Null
    $script:projectProjectionIds = @()
    $bounded = Get-ProjectDetailModel -ProjectCode P1 -StartDate $start -EndDate $end -CurrentUser $manager
    Assert-ProjectLoading ($bounded.recentEntries.Count -eq 20 -and $script:projectProjectionIds.Count -eq 20) "Project detail projected entries that are not displayed."
    Assert-ProjectLoading ($bounded.approvedEntryCount -eq 32 -and $bounded.monetary.unavailableEntryCount -eq 1 -and $bounded.monetary.totalAmountCents -eq 382695) "Limiting detail projections truncated full-period totals or lost N/A amounts."

    $projects = @(Read-JsonArrayFile $projectsFile)
    ($projects | Where-Object projectCode -eq P2).admins = @("000799999")
    Write-JsonArrayAtomic -Path $projectsFile -Items $projects -Depth 14
    Publish-DataChange -Category project -Resource P2 | Out-Null
    $reassigned = Get-ProjectDetailModel -ProjectCode P2 -StartDate $start -EndDate $end -CurrentUser $limited
    Assert-ProjectLoading ($reassigned.recentEntries[0].canModify) "Project-assignment changes did not invalidate cached permissions."

    # A complete metadata-only request must not open any employee entry file.
    function Get-CachedEmployeeEntriesForFile { throw "Administrator choices must not read overtime files." }
    $request = [PSCustomObject]@{ HttpMethod = "GET"; Url = [uri]"http://localhost/employees?scope=all&includeStats=false" }
    $response = [PSCustomObject]@{}; $currentUser = $manager
    $script:lookupJson = ""
    function respondWithSuccess { param($Response, $Message) $script:lookupJson = $Message }
    for ($run = 0; $run -lt 1; $run++) { . (Join-Path $repo "app/backend/routes/employee/list.routes.ps1") }
    $lookup = @($script:lookupJson | ConvertFrom-Json)
    Assert-ProjectLoading ($lookup.Count -eq 5 -and @($lookup | Where-Object { $_.statsLoaded -ne $false -or $_.PSObject.Properties.Name -contains "monetary" }).Count -eq 0) "Project editor lookup computed statistics or lost archived references."
    Write-Host "Projects lazy loading passed: lean portfolio, period/project scope, compact detail, cache freshness, permissions and metadata-only editor."
} finally {
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
