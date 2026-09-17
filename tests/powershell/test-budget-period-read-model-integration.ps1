$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
. (Join-Path $repoRoot "app/backend/lib/CommonHelpers.ps1")
# This test replaces every persistence read below. Prevent AuthService's
# dot-sourced startup hook from initializing repository DATA.
$script:AuthStorageEnsured = $true
. (Join-Path $repoRoot "app/backend/services/AuthService.ps1")
. (Join-Path $repoRoot "app/backend/services/ReadModelService.ps1")
. (Join-Path $repoRoot "app/backend/services/ProjectStatsService.ps1")

# Only storage and entry decoration are replaced. Dates, aggregation, project
# visibility, modification access, and the budget comparison use production code.
$script:BudgetTestCache = @{}
$script:BudgetTestProjects = @(
    [PSCustomObject]@{ projectCode = "A"; projectName = "Alpha"; sector = "Test"; admins = @("900"); backupAdmins = @(); archived = $false },
    [PSCustomObject]@{ projectCode = "B"; projectName = "Beta"; sector = "Test"; admins = @("901"); backupAdmins = @(); archived = $true },
    [PSCustomObject]@{ projectCode = "EMPTY"; projectName = "No approved time"; sector = "Test"; admins = @(); backupAdmins = @(); archived = $false }
)
$script:BudgetTestUsers = @(
    [PSCustomObject]@{ username = "employee"; employeeCode = "100"; role = "employee"; displayName = "Test employee"; disabled = $false },
    [PSCustomObject]@{ username = "archived"; employeeCode = "101"; role = "employee"; displayName = "Archived employee"; disabled = $true }
)

function New-BudgetTestEntry {
    param([string]$Id, [string]$Project, [string]$Date, [string]$Duration, [string]$Status = "approved", [string]$PunchOut = "19:00:00", [string]$EntryType = "overtime", [bool]$Forgotten = $false)
    return [PSCustomObject]@{
        entryId = $Id; projectCode = $Project; date = $Date; overtime = $Duration
        status = $Status; punchIn = "17:00:00"; punchOut = $PunchOut
        entryType = $EntryType; forgottenClockOut = $Forgotten
    }
}

$script:BudgetTestEntries = @{
    "100" = @(
        (New-BudgetTestEntry "before-cycle" "A" "2026-03-31" "10:00:00"),
        (New-BudgetTestEntry "p1-start" "A" "2026-04-01" "00:15:00"),
        (New-BudgetTestEntry "p1-end" "A" "2026-06-30" "00:30:00"),
        (New-BudgetTestEntry "p2-start" "A" "2026-07-01" "01:00:00"),
        (New-BudgetTestEntry "p2-end" "A" "2026-09-30" "02:00:00"),
        (New-BudgetTestEntry "p3-start" "A" "2026-10-01" "03:00:00"),
        (New-BudgetTestEntry "p3-end" "A" "2026-12-31" "04:00:00"),
        (New-BudgetTestEntry "p4-start" "A" "2027-01-01" "05:00:00"),
        (New-BudgetTestEntry "p4-end" "A" "2027-03-31" "06:00:00"),
        (New-BudgetTestEntry "after-cycle" "A" "2027-04-01" "10:00:00"),
        (New-BudgetTestEntry "invalid-date" "A" "not-a-date" "10:00:00"),
        (New-BudgetTestEntry "pending" "A" "2026-05-01" "10:00:00" "pending"),
        (New-BudgetTestEntry "rejected" "A" "2026-05-01" "10:00:00" "rejected"),
        (New-BudgetTestEntry "open-approved" "A" "2026-05-01" "10:00:00" "approved" ""),
        (New-BudgetTestEntry "forgotten-approved" "A" "2026-05-01" "10:00:00" "approved" "19:00:00" "overtime" $true),
        (New-BudgetTestEntry "diverse-approved" "A" "2026-05-01" "10:00:00" "approved" "19:00:00" "diverse"),
        (New-BudgetTestEntry "read-only-project" "B" "2026-04-01" "01:15:00"),
        (New-BudgetTestEntry "unknown-project" "UNKNOWN" "2026-05-01" "10:00:00"),
        (New-BudgetTestEntry "uncoded" "" "2026-05-01" "10:00:00"),
        (New-BudgetTestEntry "zero-approved" "EMPTY" "2026-05-01" "00:00:00")
    )
    "101" = @((New-BudgetTestEntry "archived-contribution" "A" "2026-09-30" "00:15:00"))
}

function Invoke-ReadModelCache {
    param([string]$Key, [scriptblock]$Factory)
    if (-not $script:BudgetTestCache.ContainsKey($Key)) { $script:BudgetTestCache[$Key] = & $Factory }
    return $script:BudgetTestCache[$Key]
}
function Get-ProjectAccessCacheVersionKey { return "budget-test" }
function Get-Projects { return $script:BudgetTestProjects }
function Get-Users { return $script:BudgetTestUsers }
function Get-EmployeeNameMap { return [PSCustomObject]@{} }
function Get-EmployeeDataFilePath { param([string]$EmployeeCode) return $EmployeeCode }
function Get-CachedEmployeeEntriesForFile { param([string]$DataFile) return $script:BudgetTestEntries[$DataFile] }
function New-EmployeeEntryProjectionForAccessModel {
    param([string]$EmployeeCode, [string]$EmployeeName, $Entry, $ModifyProjectCodeSet, [string]$EmployeeRole, [bool]$IsSuperAdmin, [bool]$CanApproveEmployeeRole)
    return $Entry.PSObject.Copy()
}
function Get-BudgetPeriodConfiguration {
    return [PSCustomObject]@{
        schemaVersion = 1; cycleLabel = "2026-2027"; periods = @(
            [PSCustomObject]@{ id = "P1"; configured = $true; startDate = "2026-04-01"; endDate = "2026-06-30" },
            [PSCustomObject]@{ id = "P2"; configured = $true; startDate = "2026-07-01"; endDate = "2026-09-30" },
            [PSCustomObject]@{ id = "P3"; configured = $true; startDate = "2026-10-01"; endDate = "2026-12-31" },
            [PSCustomObject]@{ id = "P4"; configured = $true; startDate = "2027-01-01"; endDate = "2027-03-31" }
        )
    }
}

$admin = [PSCustomObject]@{ username = "admin"; employeeCode = "900"; role = "admin" }
$superAdmin = [PSCustomObject]@{ username = "super"; employeeCode = "999"; role = "superAdmin" }
$employee = $script:BudgetTestUsers[0]

$result = Get-BudgetPeriodProjectComparison -CurrentUser $admin
Assert-Equal "7200,11700,25200,39600" (($result.periods | ForEach-Object { $_.approvedSeconds }) -join ",") "Each inclusive quarter must count its first and last day exactly once."
Assert-Equal "4,3,2,2" (($result.periods | ForEach-Object { $_.approvedEntryCount }) -join ",") "Only completed approved overtime entries, including zero-duration ones, count."
Assert-Equal "2,1,1,1" (($result.periods | ForEach-Object { $_.projectsWithOvertimeCount }) -join ",") "Zero-duration approved records must not create an active project."
Assert-Equal 83700 (($result.periods | Measure-Object -Property approvedSeconds -Sum).Sum) "Cycle totals must exclude outside, invalid-date, open, diverse, pending and rejected records."

$alpha = $result.periods[0].projects | Where-Object projectCode -eq "A"
$beta = $result.periods[0].projects | Where-Object projectCode -eq "B"
Assert-Equal 37.5 $alpha.departmentShare.percent "Project share must use the same approved period and visible portfolio."
Assert-Equal 62.5 $beta.departmentShare.percent "Archived projects must retain their historical share."
Assert-Equal "A,B,EMPTY" (($result.periods[0].projects | ForEach-Object { $_.projectCode }) -join ",") "Unknown and uncoded project time must not enter the visible portfolio."
Assert-Equal "A" ((Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $admin).ProjectCodes -join ",") "Fixture must restrict admin modification to Alpha."
Assert-Equal 4500 $beta.totalSeconds "A read-only project remains visible to managers under the application access policy."

$superResult = Get-BudgetPeriodProjectComparison -CurrentUser $superAdmin
Assert-Equal ($result | ConvertTo-Json -Depth 12 -Compress) ($superResult | ConvertTo-Json -Depth 12 -Compress) "Admin and super-admin totals must match when both can view the same portfolio."
$employeeResult = Get-BudgetPeriodProjectComparison -CurrentUser $employee
foreach ($period in $employeeResult.periods) {
    Assert-Equal 0 $period.approvedSeconds "A non-manager must not receive cached manager totals."
    Assert-Equal 0 @($period.projects).Count "A non-manager must not receive project details."
}
$anonymousResult = Get-BudgetPeriodProjectComparison -CurrentUser $null
Assert-Equal 0 (($anonymousResult.periods | Measure-Object -Property approvedSeconds -Sum).Sum) "Anonymous reads must not reuse a privileged comparison."

# Warm-cache repeat verifies that user-specific authorization and period keys
# survive interleaved privileged/unprivileged reads.
$again = Get-BudgetPeriodProjectComparison -CurrentUser $admin
Assert-Equal 7200 $again.periods[0].approvedSeconds "An unprivileged read must not poison a manager's cached period."

Write-Host "Budget-period read-model integration tests passed."
