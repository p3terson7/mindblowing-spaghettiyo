$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/ReadModelService.ps1")

$script:UnitReadModelCache = @{}
$script:EmployeeFileCalls = @{}
$script:CurrentUser = [PSCustomObject]@{ username = "workspace-admin"; employeeCode = "900"; role = "superAdmin" }
$script:Projects = @(
    [PSCustomObject]@{ projectCode = "P0"; projectName = "No activity"; sector = "Test"; archived = $false; colorKey = "blue" },
    [PSCustomObject]@{ projectCode = "P1"; projectName = "Large project"; sector = "Test"; archived = $false; colorKey = "teal" },
    [PSCustomObject]@{ projectCode = "P2"; projectName = "Single entry"; sector = "Test"; archived = $false; colorKey = "orange" }
)
$projectCodeSet = @{ P0 = $true; P1 = $true; P2 = $true }
$script:Users = @(
    [PSCustomObject]@{ username = "001"; employeeCode = "001"; displayName = "Alice"; role = "employee"; disabled = $false },
    [PSCustomObject]@{ username = "002"; employeeCode = "002"; displayName = "Bob"; role = "employee"; disabled = $false },
    [PSCustomObject]@{ username = "003"; employeeCode = "003"; displayName = "Chloe"; role = "employee"; disabled = $false },
    [PSCustomObject]@{ username = "004"; employeeCode = "004"; displayName = "Dan"; role = "employee"; disabled = $false },
    [PSCustomObject]@{ username = "005"; employeeCode = "005"; displayName = "Eve (archived)"; role = "employee"; disabled = $true }
)

function New-TestEntry {
    param(
        [string]$Id,
        [string]$ProjectCode,
        [string]$Date,
        [string]$Duration,
        [AllowNull()][string]$Status = "approved",
        [AllowNull()][string]$PunchOut = "18:00:00",
        [string]$EntryType = "overtime",
        [switch]$OmitStatus
    )

    $entry = [PSCustomObject]@{
        entryId       = $Id
        entryType     = $EntryType
        date          = $Date
        punchIn       = "08:00:00"
        exactPunchIn  = "08:01:00"
        punchOut      = $PunchOut
        exactPunchOut = $PunchOut
        overtime      = $Duration
        projectCode   = $ProjectCode
        paymentOption = "cash"
        overtimeCode  = "260"
        reasonCode    = "D"
        workComment   = "Work for $Id"
        diverseSummary = ""
        message       = "Supervisor note for $Id"
    }
    if (-not $OmitStatus) {
        $entry | Add-Member -NotePropertyName status -NotePropertyValue $Status
    }
    return $entry
}

$script:EntriesByEmployee = @{
    "001" = @(
        (New-TestEntry -Id "previous-a1" -ProjectCode "P1" -Date "2026-08-01" -Duration "15:00:00"),
        (New-TestEntry -Id "previous-a2" -ProjectCode "P1" -Date "2026-08-07" -Duration "10:00:00"),
        (New-TestEntry -Id "current-a1" -ProjectCode "P1" -Date "2026-08-08" -Duration "20:00:00"),
        (New-TestEntry -Id "current-a2" -ProjectCode "P1" -Date "2026-08-09" -Duration "10:00:00"),
        (New-TestEntry -Id "current-open" -ProjectCode "P1" -Date "2026-08-14" -Duration "00:00:00" -Status "pending" -PunchOut $null)
    )
    "002" = @(
        (New-TestEntry -Id "current-b-approved" -ProjectCode "P1" -Date "2026-08-10" -Duration "15:00:00"),
        (New-TestEntry -Id "current-b-pending" -ProjectCode "P1" -Date "2026-08-11" -Duration "03:00:00" -Status "pending"),
        (New-TestEntry -Id "current-p2" -ProjectCode "P2" -Date "2026-08-12" -Duration "10:00:00")
    )
    "003" = @(
        (New-TestEntry -Id "current-rejected" -ProjectCode "P1" -Date "2026-08-12" -Duration "04:00:00" -Status "rejected"),
        (New-TestEntry -Id "current-missing-status" -ProjectCode "P1" -Date "2026-08-13" -Duration "02:00:00" -OmitStatus),
        (New-TestEntry -Id "current-diverse" -ProjectCode "P1" -Date "2026-08-13" -Duration "08:00:00" -EntryType "diverse")
    )
    "004" = @(
        (New-TestEntry -Id "current-other" -ProjectCode "P1" -Date "2026-08-13" -Duration "01:00:00" -Status "migrated")
    )
    "005" = @(
        (New-TestEntry -Id "current-archived" -ProjectCode "P1" -Date "2026-08-14" -Duration "05:00:00")
    )
}

function Invoke-ReadModelCache {
    param([string]$Key, [scriptblock]$Factory)
    if ($script:UnitReadModelCache.ContainsKey($Key)) {
        return $script:UnitReadModelCache[$Key]
    }
    $value = & $Factory
    $script:UnitReadModelCache[$Key] = $value
    return $value
}

function Test-CurrentUserManager { param($CurrentUser) return $true }
function Test-CurrentUserSuperAdmin { param($CurrentUser) return $true }
function Get-ProjectAccessCacheUserKey { param($CurrentUser) return "superAdmin|900|workspace-admin" }
function Get-ProjectAccessModelForCurrentUser {
    param($CurrentUser)
    return [PSCustomObject]@{ Projects = $script:Projects; ProjectCodes = @("P0", "P1", "P2"); ProjectCodeSet = $projectCodeSet }
}
function Get-ProjectModificationAccessModelForCurrentUser {
    param($CurrentUser)
    return [PSCustomObject]@{ Projects = $script:Projects; ProjectCodes = @("P0", "P1", "P2"); ProjectCodeSet = $projectCodeSet }
}
function Get-Users { return $script:Users }
function Test-EmployeeUserRecord { param($UserRecord, [string]$EmployeeCode) return ($null -ne $UserRecord -and -not [string]::IsNullOrWhiteSpace([string]$UserRecord.employeeCode)) }
function Get-UserEmployeeCodeValue { param($UserRecord) return [string]$UserRecord.employeeCode }
function Get-EffectiveUserRole { param($UserRecord) return [string]$UserRecord.role }
function Get-EmployeeName { param([string]$EmployeeCode) return "Employee $EmployeeCode" }
function Test-CurrentUserCanApproveEmployeeRole { param($CurrentUser, [string]$EmployeeRole) return $true }
function Get-EmployeeDataFilePath { param([string]$EmployeeCode) return $EmployeeCode }
function Get-CachedEmployeeEntriesForFile {
    param([string]$DataFile)
    if (-not $script:EmployeeFileCalls.ContainsKey($DataFile)) { $script:EmployeeFileCalls[$DataFile] = 0 }
    $script:EmployeeFileCalls[$DataFile]++
    return @($script:EntriesByEmployee[$DataFile])
}
function New-EmployeeEntryProjectionForAccessModel {
    param([string]$EmployeeCode, [string]$EmployeeName, $Entry, $ModifyProjectCodeSet, [string]$EmployeeRole, [bool]$IsSuperAdmin, [bool]$CanApproveEmployeeRole)
    $projection = $Entry.PSObject.Copy()
    $projection | Add-Member -NotePropertyName employeeCode -NotePropertyValue $EmployeeCode -Force
    $projection | Add-Member -NotePropertyName employeeName -NotePropertyValue $EmployeeName -Force
    $projection | Add-Member -NotePropertyName canModify -NotePropertyValue $true -Force
    $projection | Add-Member -NotePropertyName canApprove -NotePropertyValue $true -Force
    $projection | Add-Member -NotePropertyName permissionReason -NotePropertyValue "editable" -Force
    return $projection
}
function Get-ProjectAdminCodes { param($Project) return @() }
function Get-ProjectBackupAdminCodes { param($Project) return @() }
function ConvertTo-CodeArray { param($Value) return @($Value) }
function Get-EmployeeNameMap { return [PSCustomObject]@{} }
function Test-ProjectArchived { param($Project) return ($Project.PSObject.Properties.Name -contains "archived" -and [bool]$Project.archived) }
function Resolve-ProjectColorKey { param([string]$ColorKey, [string]$ProjectCode) return $(if ([string]::IsNullOrWhiteSpace($ColorKey)) { "blue" } else { $ColorKey }) }
function ConvertTo-ProjectArchiveScope { param([string]$Scope) return $(if ([string]::IsNullOrWhiteSpace($Scope)) { "all" } else { $Scope }) }
function Select-ProjectsByArchiveScope { param($Projects, [string]$Scope) return @($Projects) }

$script:ProjectDetailProjectionCalls = 0
$script:OriginalProjectEntryDetailProjection = ${function:New-ProjectEntryDetailProjection}
function New-ProjectEntryDetailProjection {
    param($Entry, [string]$StatusBucket, [long]$DurationSeconds)
    $script:ProjectDetailProjectionCalls++
    return (& $script:OriginalProjectEntryDetailProjection -Entry $Entry -StatusBucket $StatusBucket -DurationSeconds $DurationSeconds)
}

Assert-Equal -Expected "50:00:00" -Actual (Convert-SecondsToTimeText -Seconds 180000) -Message "Cumulative duration formatting wrapped after 24 hours."

$snapshot = @(Get-ProjectStatisticsEntriesSnapshot -CurrentUser $script:CurrentUser)
Assert-Equal -Expected 13 -Actual $snapshot.Count -Message "The project snapshot did not include all historical overtime records."
$archivedFact = $snapshot | Where-Object { [string]$_.entryId -eq "current-archived" } | Select-Object -First 1
Assert-True -Condition ($null -ne $archivedFact -and [bool]$archivedFact.employeeArchived) -Message "Archived employee history was dropped from project analytics."
$snapshotAgain = @(Get-ProjectStatisticsEntriesSnapshot -CurrentUser $script:CurrentUser)
Assert-Equal -Expected 13 -Actual $snapshotAgain.Count -Message "The cached project snapshot changed between reads."
foreach ($employeeCode in @("001", "002", "003", "004", "005")) {
    Assert-Equal -Expected 1 -Actual $script:EmployeeFileCalls[$employeeCode] -Message "The cached project snapshot reread employee $employeeCode."
}

$summary = @(Get-ProjectSummaryList -StartDate "2026-08-08" -EndDate "2026-08-14" -CurrentUser $script:CurrentUser)
Assert-Equal -Expected 3 -Actual $summary.Count -Message "The 0/1/N project summary cardinality changed."
Assert-Equal -Expected 0 -Actual $script:ProjectDetailProjectionCalls -Message "Portfolio summary eagerly constructed project entry details."
$p0 = $summary | Where-Object projectCode -eq "P0" | Select-Object -First 1
$p1 = $summary | Where-Object projectCode -eq "P1" | Select-Object -First 1
$p2 = $summary | Where-Object projectCode -eq "P2" | Select-Object -First 1
Assert-Equal -Expected 0 -Actual $p0.entryCount -Message "A zero-entry project did not remain visible."
Assert-Equal -Expected 1 -Actual $p2.entryCount -Message "A one-entry project was not aggregated correctly."
Assert-Equal -Expected "50:00:00" -Actual $p1.totalOvertime -Message "The official approved project total is wrong or wrapped at 24 hours."
Assert-Equal -Expected 180000 -Actual $p1.totalSeconds -Message "The project summary omitted the raw approved seconds."
Assert-Equal -Expected 9 -Actual $p1.entryCount -Message "The compatibility entry count should include all overtime workflow records."
Assert-Equal -Expected 4 -Actual $p1.approvedEntryCount -Message "Approved closed entry count is wrong."
Assert-Equal -Expected "12:30:00" -Actual $p1.averageOvertime -Message "Approved average duration is wrong."
Assert-Equal -Expected "05:00:00" -Actual $p1.minOvertime -Message "Approved minimum duration is wrong."
Assert-Equal -Expected "20:00:00" -Actual $p1.maxOvertime -Message "Approved maximum duration is wrong."
Assert-Equal -Expected 4 -Actual $p1.statusBuckets.approved.count -Message "Approved status bucket is wrong."
Assert-Equal -Expected 2 -Actual $p1.statusBuckets.pending.count -Message "Missing status was not normalized to pending."
Assert-Equal -Expected 1 -Actual $p1.statusBuckets.rejected.count -Message "Rejected status bucket is wrong."
Assert-Equal -Expected 1 -Actual $p1.statusBuckets.open.count -Message "Open entry was not separated from pending."
Assert-Equal -Expected 1 -Actual $p1.statusBuckets.other.count -Message "Unknown status was not placed in other."
Assert-Equal -Expected "60:00:00" -Actual $p1.trackedOvertime -Message "The compatibility tracked total is wrong."
Assert-Equal -Expected 83.33 -Actual $p1.departmentShare.percent -Message "Department share is wrong."
Assert-Equal -Expected "approvedClosedOvertime" -Actual $p1.basis.id -Message "The summary does not document its approved-closed basis."

$lightweightStats = Get-ProjectStatisticsOverview -StartDate "2026-08-08" -EndDate "2026-08-14" -IncludeBreakdown:$false -CurrentUser $script:CurrentUser
Assert-True -Condition ($null -eq $lightweightStats["P1"].breakdown) -Message "Lightweight summary aggregation retained an employee breakdown."
$detailedStats = Get-ProjectStatisticsOverview -StartDate "2026-08-08" -EndDate "2026-08-14" -IncludeBreakdown:$true -CurrentUser $script:CurrentUser
Assert-True -Condition ($null -ne $detailedStats["P1"].breakdown) -Message "Detailed aggregation omitted its employee breakdown."
Assert-True -Condition ($script:ProjectDetailProjectionCalls -gt 0) -Message "Detailed aggregation no longer constructs entry projections on demand."
foreach ($propertyName in @("totalSeconds", "trackedSeconds", "entryCount", "approvedEntryCount", "minSeconds", "maxSeconds")) {
    Assert-Equal -Expected $detailedStats["P1"].$propertyName -Actual $lightweightStats["P1"].$propertyName -Message "Lightweight aggregation changed $propertyName."
}
foreach ($bucketName in @("approved", "pending", "rejected", "open", "other")) {
    Assert-Equal -Expected $detailedStats["P1"].statusBuckets[$bucketName].count -Actual $lightweightStats["P1"].statusBuckets[$bucketName].count -Message "Lightweight aggregation changed the $bucketName count."
    Assert-Equal -Expected $detailedStats["P1"].statusBuckets[$bucketName].seconds -Actual $lightweightStats["P1"].statusBuckets[$bucketName].seconds -Message "Lightweight aggregation changed the $bucketName duration."
}

$detail = Get-ProjectDetailModel -ProjectCode "P1" -StartDate "2026-08-08" -EndDate "2026-08-14" -CurrentUser $script:CurrentUser
Assert-Equal -Expected 5 -Actual @($detail.contributors).Count -Message "Contributor summaries dropped zero-approved participants."
Assert-Equal -Expected "001" -Actual $detail.contributors[0].employeeCode -Message "Contributors are not sorted by approved hours."
Assert-Equal -Expected 108000 -Actual $detail.contributors[0].approvedSeconds -Message "Contributor raw seconds are wrong."
Assert-Equal -Expected 60 -Actual $detail.contributors[0].sharePercent -Message "Contributor project share is wrong."
Assert-Equal -Expected "15:00:00" -Actual $detail.contributors[0].averageOvertime -Message "Contributor approved average is wrong."
$bob = $detail.contributors | Where-Object employeeCode -eq "002" | Select-Object -First 1
Assert-Equal -Expected 1 -Actual $bob.pendingCount -Message "Contributor pending count is wrong."
Assert-Equal -Expected "03:00:00" -Actual $bob.pendingOvertime -Message "Contributor pending duration is wrong."
$eve = $detail.contributors | Where-Object employeeCode -eq "005" | Select-Object -First 1
Assert-Equal -Expected $true -Actual $eve.employeeArchived -Message "Archived contributor flag was lost."
Assert-Equal -Expected 9 -Actual @($detail.recentEntries).Count -Message "Recent entries should include every current-period workflow record."
Assert-Equal -Expected "current-archived" -Actual $detail.recentEntries[0].entryId -Message "Recent entries are not sorted by latest activity."
$entryFact = $detail.recentEntries | Where-Object entryId -eq "current-b-approved" | Select-Object -First 1
foreach ($propertyName in @("status", "statusBucket", "durationSeconds", "workComment", "message", "paymentOption", "overtimeCode", "reasonCode", "canModify", "canApprove", "permissionReason")) {
    Assert-True -Condition ($entryFact.PSObject.Properties.Name -contains $propertyName) -Message "Recent entry omitted $propertyName."
}
Assert-Equal -Expected $true -Actual $detail.comparison.available -Message "Equivalent-period comparison was not produced."
Assert-Equal -Expected "2026-08-01" -Actual $detail.comparison.previous.startDate -Message "Previous equivalent period start is wrong."
Assert-Equal -Expected "2026-08-07" -Actual $detail.comparison.previous.endDate -Message "Previous equivalent period end is wrong."
Assert-Equal -Expected "25:00:00" -Actual $detail.comparison.previous.overtime -Message "Previous approved total is wrong."
Assert-Equal -Expected 100 -Actual $detail.comparison.percentChange -Message "Equivalent-period percent change is wrong."
Assert-Equal -Expected "up" -Actual $detail.comparison.direction -Message "Equivalent-period direction is wrong."
Assert-Equal -Expected 1 -Actual @($detail.approvedTrend).Count -Message "Selected project approved trend is missing."
Assert-Equal -Expected 180000 -Actual $detail.approvedTrend[0].seconds -Message "Approved trend included non-approved entries."
Assert-Equal -Expected "50:00:00" -Actual $detail.approvedTrend[0].duration -Message "Approved trend duration wrapped after 24 hours."
Assert-Equal -Expected @($detail.contributors).Count -Actual @($detail.breakdownByEmployee).Count -Message "Compatibility employee breakdown was not preserved."
$serializedSummary = @($summary) | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$serializedDetail = $detail | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Assert-Equal -Expected 180000 -Actual $serializedSummary[1].statusBuckets.approved.seconds -Message "Summary route depth would truncate nested status buckets."
Assert-Equal -Expected "Supervisor note for current-b-approved" -Actual (($serializedDetail.recentEntries | Where-Object entryId -eq "current-b-approved").message) -Message "Detail route depth would truncate recent-entry notes."

$unboundedDetail = Get-ProjectDetailModel -ProjectCode "P1" -CurrentUser $script:CurrentUser
Assert-Equal -Expected $false -Actual $unboundedDetail.comparison.available -Message "An unbounded period should not claim an equivalent comparison."

$bootstrap = Get-ProjectsBootstrapModel -StartDate "2026-08-08" -EndDate "2026-08-14" -SelectedProjectCode "P1" -Scope "all" -IncludeDetail:$false -CurrentUser $script:CurrentUser
Assert-Equal -Expected $false -Actual $bootstrap.detailIncluded -Message "Bootstrap did not report includeDetail=false."
Assert-True -Condition ($null -eq $bootstrap.selectedProject) -Message "Lightweight bootstrap still serialized the full project detail."
Assert-Equal -Expected "P1" -Actual $bootstrap.selectedProjectCode -Message "Lightweight bootstrap lost project selection."

$script:CapturedStatusCode = 0
$script:CapturedPayload = $null
$script:CapturedIncludeDetail = $true
function Get-ProjectsBootstrapModel {
    param([string]$StartDate, [string]$EndDate, [string]$SelectedProjectCode, [string]$Scope, [bool]$IncludeDetail, $CurrentUser)
    $script:CapturedIncludeDetail = $IncludeDetail
    return [PSCustomObject]@{ detailIncluded = $IncludeDetail; selectedProject = $null }
}
function respondWithSuccess { param($Response, [string]$Message) $script:CapturedStatusCode = 200; $script:CapturedPayload = $Message }
function respondWithError { param($Response, [int]$StatusCode, [string]$Message) $script:CapturedStatusCode = $StatusCode; $script:CapturedPayload = $Message }
function Rethrow-HttpStatusException { param($Exception) }

$request = [PSCustomObject]@{ HttpMethod = "GET"; Url = [Uri]"http://localhost/projects/bootstrap?includeDetail=false" }
$response = [PSCustomObject]@{}
$currentUser = $script:CurrentUser
for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/bootstrap.routes.ps1")
}
Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "The lightweight bootstrap route failed."
Assert-Equal -Expected $false -Actual $script:CapturedIncludeDetail -Message "The route did not pass includeDetail=false to the model."

$request = [PSCustomObject]@{ HttpMethod = "GET"; Url = [Uri]"http://localhost/projects/bootstrap" }
$script:CapturedStatusCode = 0
$script:CapturedIncludeDetail = $false
for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/bootstrap.routes.ps1")
}
Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "The legacy bootstrap route failed."
Assert-Equal -Expected $true -Actual $script:CapturedIncludeDetail -Message "Bootstrap no longer defaults to including detail for legacy clients."

$request = [PSCustomObject]@{ HttpMethod = "GET"; Url = [Uri]"http://localhost/projects/bootstrap?includeDetail=maybe" }
$script:CapturedStatusCode = 0
for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/bootstrap.routes.ps1")
}
Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Invalid includeDetail should return HTTP 400."

Write-Host "Project workspace read-model tests passed."
