$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "Assertion failed: $Message Expected '$Expected', got '$Actual'." }
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

. (Join-Path $repoRoot "app/backend/services/OvertimeCostSnapshotService.ps1")

function Set-EntryPropertyValue($Entry, [string]$Name, $Value) {
    if ($Entry.PSObject.Properties.Name -contains $Name) { $Entry.PSObject.Properties[$Name].Value = $Value }
    else { $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}
function Get-EmployeeUserByCode([string]$EmployeeCode) { return $script:testEmployeeUser }
function Get-EmployeeClassificationFromUserRecord($UserRecord) {
    if (-not $UserRecord.gc179Profile.level) { return $null }
    return $UserRecord.gc179Profile
}
function Get-CompensationGrid { return $script:testSalaryGrid }

$script:testEmployeeUser = [PSCustomObject]@{
    gc179Profile = [PSCustomObject]@{ group = "CR"; subGroup = "04"; level = "01" }
}
$script:testSalaryGrid = [PSCustomObject]@{
    schemaVersion = 1
    currency = "CAD"
    bands = @([PSCustomObject]@{ id = "cr-04-01"; group = "CR"; subGroup = "04"; level = "01"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" })
}

$entries = @(
    [PSCustomObject]@{ entryId = "first"; entryType = "overtime"; date = "2026-09-01"; punchIn = "08:00:00"; punchOut = "15:00:00"; overtime = "07:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular" },
    [PSCustomObject]@{ entryId = "second"; entryType = "overtime"; date = "2026-09-01"; punchIn = "16:00:00"; punchOut = "17:00:00"; overtime = "01:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "leave"; workSchedule = "regular" },
    [PSCustomObject]@{ entryId = "pending"; entryType = "overtime"; date = "2026-09-02"; punchIn = "08:00:00"; punchOut = "09:00:00"; overtime = "01:00:00"; status = "pending"; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular"; compensationSnapshot = [PSCustomObject]@{ stale = $true } }
)

Set-ApprovedEntryCompensationSnapshots -EmployeeCode "0001" -Entries $entries -CalculationTimeUtc "2026-09-29T12:00:00.0000000Z" | Out-Null
Assert-Equal "final" $entries[0].compensationSnapshot.snapshotStatus "Approved rows should receive a final estimate snapshot."
Assert-Equal "cr-04-01" $entries[0].compensationSnapshot.salaryBandId "The effective salary band should be captured."
Assert-Equal 0 $entries[0].compensationSnapshot.previouslyCreditedMinutes "The first row should start the daily threshold."
Assert-Equal 420 $entries[1].compensationSnapshot.previouslyCreditedMinutes "The second row should continue the same daily/category threshold."
Assert-Equal 2 @($entries[1].compensationSnapshot.segments).Count "The threshold-crossing row should contain both 1.5x and 2x segments."
Assert-Equal 0 $entries[1].compensationSnapshot.cashAmountCents "Leave should not be counted as cash."
Assert-True ([long]$entries[1].compensationSnapshot.compensatoryLeaveValueCents -gt 0) "Leave should retain its economic value."
Assert-True ($entries[2].PSObject.Properties.Name -notcontains "compensationSnapshot") "A pending row must not retain a stale final snapshot."

$originalCalculatedAt = [string]$entries[0].compensationSnapshot.calculatedAtUtc
Set-ApprovedEntryCompensationSnapshots -EmployeeCode "0001" -Entries $entries -CalculationTimeUtc "2026-09-30T12:00:00.0000000Z" | Out-Null
Assert-Equal $originalCalculatedAt $entries[0].compensationSnapshot.calculatedAtUtc "An unchanged final snapshot must remain stable across unrelated recalculations."

$script:testEmployeeUser.gc179Profile.level = ""
$missingAssignmentEntry = [PSCustomObject]@{ entryId = "missing"; entryType = "overtime"; date = "2026-09-03"; punchIn = "08:00:00"; punchOut = "09:00:00"; overtime = "01:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular" }
Set-ApprovedEntryCompensationSnapshots -EmployeeCode "0001" -Entries @($missingAssignmentEntry) -CalculationTimeUtc "2026-09-29T12:00:00.0000000Z" | Out-Null
Assert-Equal "unavailable" $missingAssignmentEntry.compensationSnapshot.snapshotStatus "Missing HR classification must not block approval."
Assert-Equal "employee-classification-missing" $missingAssignmentEntry.compensationSnapshot.unavailableReason "The missing-data reason should be auditable."

$script:testEmployeeUser.gc179Profile.level = "01"
$script:persistedEntries = @([PSCustomObject]@{ entryId = "historical"; entryType = "overtime"; date = "2026-09-04"; punchIn = "08:00:00"; punchOut = "09:00:00"; overtime = "01:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular" })
$script:snapshotWriteCount = 0
$script:snapshotCacheClearCount = 0
function Get-EmployeeDataFilePath([string]$EmployeeCode) { return "memory://$EmployeeCode" }
function Test-SaphirFileExists([string]$Path) { return $true }
function Acquire-ResourceLock([string]$ResourcePath) { return [PSCustomObject]@{ Path = $ResourcePath } }
function Release-ResourceLock($LockHandle) {}
function Read-JsonArrayFile([string]$Path) { return @($script:persistedEntries) }
function Write-JsonArrayAtomic([string]$Path, $Items, [int]$Depth = 6) {
    $script:snapshotWriteCount++
    $script:persistedEntries = @($Items)
}
function Clear-EmployeeEntryCacheForCode([string]$EmployeeCode) { $script:snapshotCacheClearCount++; return $true }

$refresh = Update-EmployeeApprovedCompensationSnapshots -EmployeeCode "0001"
Assert-True $refresh.changed "Saving a new classification should backfill approved-entry estimates."
Assert-Equal 1 $script:snapshotWriteCount "The backfill should write the employee file once."
Assert-Equal 1 $script:snapshotCacheClearCount "The backfill should invalidate the employee cache."
Assert-Equal "final" $script:persistedEntries[0].compensationSnapshot.snapshotStatus "The historical approved entry did not receive a final snapshot."

$refreshAgain = Update-EmployeeApprovedCompensationSnapshots -EmployeeCode "0001"
Assert-True (-not $refreshAgain.changed) "An unchanged classification should not rewrite stable snapshots."
Assert-Equal 1 $script:snapshotWriteCount "A stable snapshot was rewritten unnecessarily."

$originalTotal = $entries[0].compensationSnapshot.totalAmountCents
$originalSalary = $entries[0].compensationSnapshot.annualSalaryCents
$script:testEmployeeUser.gc179Profile = [PSCustomObject]@{ group = "AS"; subGroup = "04"; level = "03" }
$script:testSalaryGrid.bands += [PSCustomObject]@{ id = "as-04-03"; group = "AS"; subGroup = "04"; level = "03"; annualSalaryCents = 8710800; effectiveFrom = "2026-01-01" }
$promotedEntry = [PSCustomObject]@{ entryId = "promoted"; entryType = "overtime"; date = "2026-09-10"; punchIn = "08:00:00"; punchOut = "09:00:00"; overtime = "01:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular" }
$entries += $promotedEntry
Set-ApprovedEntryCompensationSnapshots -EmployeeCode "0001" -Entries $entries | Out-Null
Assert-Equal $originalTotal $entries[0].compensationSnapshot.totalAmountCents "A promotion repriced previously approved overtime."
Assert-Equal $originalSalary $entries[0].compensationSnapshot.annualSalaryCents "A promotion overwrote an approved entry's captured salary."
Assert-Equal "CR" $entries[0].compensationSnapshot.classification.group "The historical snapshot lost its original classification."
Assert-Equal 8710800 $promotedEntry.compensationSnapshot.annualSalaryCents "New overtime did not use the current profile classification."
Assert-Equal "AS" $promotedEntry.compensationSnapshot.classification.group "New overtime used a separate classification source."

$legacyReadEntries = @(
    [PSCustomObject]@{ entryId = "legacy-first"; entryType = "overtime"; projectCode = "HIDDEN"; date = "2026-09-20"; punchIn = "08:00:00"; overtime = "07:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular" },
    [PSCustomObject]@{ entryId = "legacy-second"; entryType = "overtime"; projectCode = "VISIBLE"; date = "2026-09-20"; punchIn = "16:00:00"; overtime = "01:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "leave"; workSchedule = "regular" }
)
$beforeRead = ConvertTo-Json -InputObject $legacyReadEntries -Depth 12 -Compress
$readEstimates = @(Get-EmployeeCompensationReadEstimates -EmployeeCode "0001" -Entries $legacyReadEntries)
Assert-Equal "final" $readEstimates[0].compensationSnapshot.snapshotStatus "Legacy approvals should be priced on read when data is complete."
Assert-Equal 420 $readEstimates[1].compensationSnapshot.previouslyCreditedMinutes "A read estimate must include daily hours from other projects before scoping."
Assert-Equal 2 @($readEstimates[1].compensationSnapshot.segments).Count "Legacy read estimates lost the daily rate threshold."
Assert-Equal $beforeRead (ConvertTo-Json -InputObject $legacyReadEntries -Depth 12 -Compress) "Read estimates mutated the source employee document."
Assert-Equal 1 $script:snapshotWriteCount "Displaying estimates must not write to the shared drive."

$capturedBeforeRead = ConvertTo-Json -InputObject $entries[0].compensationSnapshot -Depth 12 -Compress
$mixedRead = @(Get-EmployeeCompensationReadEstimates -EmployeeCode "0001" -Entries @($entries[0], $legacyReadEntries[0]))
Assert-Equal $capturedBeforeRead (ConvertTo-Json -InputObject $mixedRead[0].compensationSnapshot -Depth 12 -Compress) "Displaying an estimate replaced a captured final snapshot."
$script:testEmployeeUser.gc179Profile.level = ""
$missingRead = @(Get-EmployeeCompensationReadEstimates -EmployeeCode "0001" -Entries $legacyReadEntries)
Assert-Equal "employee-classification-missing" $missingRead[0].compensationSnapshot.unavailableReason "Missing legacy data must stay unavailable instead of becoming zero."

Write-Host "Overtime cost snapshot tests passed."
