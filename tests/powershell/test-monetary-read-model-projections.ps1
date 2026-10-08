$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/CommonHelpers.ps1")
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/EntryService.ps1")
function Get-NormalizedRoleName {
    param([string]$Role)
    if (([string]$Role).Trim().ToLowerInvariant() -eq "admin") { return "admin" }
    return "employee"
}
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/ReadModelService.ps1")

$approvedEntry = [PSCustomObject]@{
    entryId = "approved-cost"
    entryType = "overtime"
    status = "approved"
    date = "2026-09-15"
    punchIn = "17:00:00"
    punchOut = "18:00:00"
    overtime = "01:00:00"
    projectCode = "P001"
    workSchedule = "regular"
    paymentOption = "leave"
    compensationSnapshot = [PSCustomObject]@{
        snapshotStatus = "final"
        currency = "CAD"
        estimateOnly = $true
        costBasis = "salary-only"
        includesEmployerCosts = $false
        paymentOption = "leave"
        totalAmountCents = 12345
        cashAmountCents = 0
        compensatoryLeaveValueCents = 12345
        calculationVersion = "PA-MONETARY-v1"
        annualSalaryCents = 8700000
        hourlyRateCents = 4446.47
        classification = [PSCustomObject]@{ group = "AS"; subGroup = "04"; level = "03" }
        salaryBandId = "private-band"
        compensationAssignmentId = "private-assignment"
        sourceFingerprint = "private-fingerprint"
    }
}

$managerEntryProjection = New-EmployeeEntryProjectionForAccessModel `
    -EmployeeCode "000100001" `
    -EmployeeName "Demo Employee" `
    -Entry $approvedEntry `
    -ModifyProjectCodeSet @{ P001 = $true } `
    -EmployeeRole "employee" `
    -IsSuperAdmin:$true
Assert-True ($managerEntryProjection.PSObject.Properties.Name -contains "monetary") "Manager entry projections must include the limited monetary result."
Assert-True ($managerEntryProjection.PSObject.Properties.Name -notcontains "compensationSnapshot") "The private compensation snapshot leaked into a manager entry projection."
Assert-True ($managerEntryProjection.monetary.PSObject.Properties.Name -notcontains "annualSalaryCents") "A manager entry projection exposed annual salary."

$employeeEntryProjection = New-EmployeeEntryProjection -EmployeeCode "000100001" -EmployeeName "Demo Employee" -Entry $approvedEntry
Assert-True ($employeeEntryProjection.PSObject.Properties.Name -notcontains "monetary") "The normal employee projection must remain monetary-free."
Assert-True ($employeeEntryProjection.PSObject.Properties.Name -notcontains "compensationSnapshot") "The employee projection leaked the private compensation snapshot."

$projection = New-EntryMonetaryReadModel -Entry $approvedEntry
Assert-Equal "final" $projection.status "The final monetary state was not projected."
Assert-Equal 12345 $projection.totalAmountCents "The projected total is wrong."
Assert-Equal 0 $projection.cashAmountCents "Leave was incorrectly exposed as cash."
Assert-Equal 12345 $projection.compensatoryLeaveValueCents "The leave value is wrong."
foreach ($privateName in @("annualSalaryCents", "hourlyRateCents", "classification", "salaryBandId", "compensationAssignmentId", "sourceFingerprint")) {
    Assert-True ($projection.PSObject.Properties.Name -notcontains $privateName) "Private snapshot field '$privateName' leaked into the read model."
}

$legacyEntry = [PSCustomObject]@{ entryId = "legacy"; entryType = "overtime"; status = "approved"; paymentOption = "cash" }
$legacyProjection = New-EntryMonetaryReadModel -Entry $legacyEntry
Assert-Equal "unavailable" $legacyProjection.status "An approved legacy entry must have an explicit unavailable state."
Assert-Equal "snapshot-missing" $legacyProjection.unavailableReason "The legacy reason is not actionable."
Assert-True ($null -eq $legacyProjection.totalAmountCents) "A missing snapshot must not invent a zero-dollar estimate."

$pendingEntry = [PSCustomObject]@{ entryId = "pending"; entryType = "overtime"; status = "pending" }
Assert-True ($null -eq (New-EntryMonetaryReadModel -Entry $pendingEntry)) "Pending entries must not expose a monetary estimate."

$accumulator = New-MonetaryAccumulator
Add-EntryMonetaryToAccumulator -Accumulator $accumulator -Monetary $projection
Add-EntryMonetaryToAccumulator -Accumulator $accumulator -Monetary $legacyProjection
$aggregate = ConvertTo-MonetaryAggregateReadModel -Accumulator $accumulator
Assert-Equal 2 $aggregate.approvedEntryCount "Aggregate approval coverage is wrong."
Assert-Equal 1 $aggregate.calculatedEntryCount "Aggregate calculated coverage is wrong."
Assert-Equal 1 $aggregate.unavailableEntryCount "Aggregate missing coverage is wrong."
Assert-Equal 50 $aggregate.coveragePercent "Aggregate coverage percentage is wrong."
Assert-Equal 12345 $aggregate.totalAmountCents "Aggregate value is wrong."
Assert-Equal 1 $aggregate.unavailableReasons.'snapshot-missing' "Aggregates must expose missing-data reasons without salary inputs."

. (Join-Path $repoRoot "app/backend/services/EmployeeDirectoryService.ps1")
$directoryStats = Get-EmployeeDirectoryStats -Entries @($approvedEntry, $legacyEntry, $pendingEntry)
Assert-Equal 12345 $directoryStats.monetary.totalAmountCents "Personnel directory totals lost the approved-entry value."
Assert-Equal 1 $directoryStats.monetary.unavailableEntryCount "Personnel must not treat an unpriced approval as zero dollars."
Assert-Equal 12345 @($directoryStats.projectStats | Where-Object projectCode -eq "P001")[0].monetary.totalAmountCents "Personnel project filters need scoped monetary totals."
Assert-True (($directoryStats | ConvertTo-Json -Depth 12 -Compress) -notmatch 'annualSalaryCents|hourlyRateCents|compensationSnapshot') "Personnel statistics leaked private salary inputs."

$script:estimateReadCalls = 0
function Get-EmployeeCompensationReadEstimates {
    param([string]$EmployeeCode, $Entries)
    $script:estimateReadCalls++
    return $Entries
}
$script:ReadModelFactoryDepth = 1
$metadata = [PSCustomObject]@{ LastWriteTicks = 100; Length = 200 }
Get-CachedEmployeeMonetaryEntries -DataFile "000100001_data.json" -Metadata $metadata -Entries @($approvedEntry) | Out-Null
Get-CachedEmployeeMonetaryEntries -DataFile "000100001_data.json" -Metadata $metadata -Entries @($approvedEntry) | Out-Null
Assert-Equal 1 $script:estimateReadCalls "Warm monetary requests must not repeat salary calculations."
$script:ReadModelCache = @{}
Get-CachedEmployeeMonetaryEntries -DataFile "000100001_data.json" -Metadata $metadata -Entries @($approvedEntry) | Out-Null
Assert-Equal 1 $script:estimateReadCalls "An unrelated view refresh must preserve monetary estimates."
$script:EmployeeMonetaryEntryCache = @{}
Get-CachedEmployeeMonetaryEntries -DataFile "000100001_data.json" -Metadata $metadata -Entries @($approvedEntry) | Out-Null
Assert-Equal 2 $script:estimateReadCalls "A monetary source invalidation must refresh derived estimates."
$script:ReadModelFactoryDepth = 0

Write-Host "Monetary read-model projection tests passed."
