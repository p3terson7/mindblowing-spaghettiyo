$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
. (Join-Path $repo "app/backend/services/OvertimeCostSnapshotService.ps1")
. (Join-Path $repo "app/backend/services/Gc179ExportService.ps1")
Import-Module (Join-Path $repo "app/backend/modules/Saphir.Gc179Profile.psd1") -Force

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -cne [string]$Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}
function Assert-Field($Export, [string]$Name, [string]$Value) {
    Assert-Equal $true ([regex]::IsMatch($Export.Content, "/T \(" + [regex]::Escape($Name) + "\)\s*/V \(" + [regex]::Escape($Value) + "\)")) "GC179 $Name."
}
function New-TestEntry([string]$Code = "260", [string]$Start = "10:00:00", [string]$End = "18:00:00", [string]$Duration = "08:00:00", [string]$Date = "2026-11-05") {
    return [PSCustomObject]@{
        entryId = [guid]::NewGuid().ToString("N"); entryType = "overtime"; date = $Date
        punchIn = $Start; punchOut = $End; overtime = $Duration; status = "approved"
        overtimeCode = $Code; paymentOption = "cash"; reasonCode = "D"; workSchedule = "compressed"
    }
}
function Set-EntryPropertyValue($Entry, [string]$Name, $Value) { $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
function Get-EmployeeUserByCode([string]$EmployeeCode) { return $script:user }
function Get-EmployeeClassificationFromUserRecord($UserRecord) { return $UserRecord.gc179Profile }
function Get-CompensationGrid { return $script:grid }
function Ensure-EmployeeDataFile([string]$EmployeeCode) { return "memory://IT" }
function Get-CachedEmployeeEntriesForFile([string]$DataFile) { return $script:entries }
function Convert-ToNormalizedTimeText([string]$TimeText) {
    if ($TimeText -match "^\d{2}:\d{2}:\d{2}$") { return $TimeText }
    if ($TimeText -match "^\d{2}:\d{2}$") { return ($TimeText + ":00") }
    return ""
}
$script:user = [PSCustomObject]@{ displayName = "Test IT"; gc179Profile = [PSCustomObject]@{ group = "IT"; subGroup = "02"; level = "01"; compressedWorkWeek = $true; surname = "TEST"; givenName = "IT" } }
$script:grid = [IO.File]::ReadAllText((Join-Path $repo "app/backend/defaults/compensation-grid.v1.json")) | ConvertFrom-Json
Assert-Equal 8 @($script:grid.bands | Where-Object group -eq "IT").Count "All eight IT steps are required."
foreach ($sub in @("01", "03")) {
    Assert-Equal $null (Saphir.CompensationGrid\Resolve-CompensationSalaryBand -SalaryGrid $script:grid -Group IT -SubGroup $sub -Level 01 -AsOfDate ([DateTime]"2026-11-05")) "Do not invent IT-$sub salaries."
}
Assert-Equal "IT-MONETARY-v1" (Get-SaphirOvertimeMonetaryContract -Group IT).calculationVersion "IT contract provenance."
foreach ($schedule in @("regular", "compressed")) {
    foreach ($code in @("260", "261", "263")) {
        $parts = @(Get-SaphirOvertimeRateSegments -Group IT -OvertimeCode $code -WorkSchedule $schedule -Hours 8)
        Assert-Equal 2 $parts.Count "IT $code/$schedule must split after 7.5 hours."
        Assert-Equal "1.5" $parts[0].multiplier "IT must not inherit PA compressed 1.75."
        Assert-Equal "7.5" $parts[0].hours "IT base threshold."
        Assert-Equal "2" $parts[1].multiplier "IT excess rate."
        Assert-Equal "0.5" $parts[1].hours "IT excess duration."
    }
    $parts = @(Get-SaphirOvertimeRateSegments -Group IT -OvertimeCode 262 -WorkSchedule $schedule -Hours 8)
    Assert-Equal 1 $parts.Count "IT second rest day must be double throughout."
    Assert-Equal "2" $parts[0].multiplier "IT rest day rate."
}
Assert-Equal "1.75" (Get-SaphirOvertimeRatePlan -Group CR -OvertimeCode 260 -WorkSchedule compressed).baseMultiplier "PA behavior changed."
$unknown = Get-SaphirOvertimeCostEstimate -Group IT -AnnualSalaryCents 8585400 -OvertimeCode 263 -WorkSchedule compressed -CreditedMinutes 60 -HolidayAdjacentToWorkedRest $true
Assert-Equal "it-holiday-schedule-unconfirmed" $unknown.unavailableReason "Missing IT holiday context must remain N/A."
foreach ($notScheduled in @($false, $true)) {
    $value = Get-SaphirOvertimeCostEstimate -Group IT -AnnualSalaryCents 8585400 -OvertimeCode 263 -WorkSchedule compressed -CreditedMinutes 60 -HolidayAdjacentToWorkedRest $true -HolidayNotScheduledWorkday $notScheduled
    $rate = if ($notScheduled) { "2" } else { "1.5" }
    Assert-Equal $rate $value.segments[0].multiplier "IT holiday schedule condition."
}

# Same calculator supplies persisted money and GC179 entitlement columns.
$script:entries = @((New-TestEntry))
Set-ApprovedEntryCompensationSnapshots -EmployeeCode 0001 -Entries $script:entries | Out-Null
Assert-Equal "IT-MONETARY-v1" $script:entries[0].compensationSnapshot.calculationVersion "Snapshot used PA rules."
Assert-Equal "1.5" $script:entries[0].compensationSnapshot.segments[0].multiplier "Snapshot used compressed PA multiplier."
$form = (New-Gc179FdfExportSet -EmployeeCode 0001 -MonthKey 2026-11).Exports[0]
Assert-Field $form "RegTimeHalf.0" "7.5"
Assert-Field $form "RegTimeDouble.0" "0.5"
Assert-Field $form "RegTime3Quarter.0" ""
$captured = ConvertTo-Json $script:entries[0].compensationSnapshot -Depth 12 -Compress
$script:user.gc179Profile.group = "AS"
Set-ApprovedEntryCompensationSnapshots -EmployeeCode 0001 -Entries $script:entries -MissingSnapshotsOnly | Out-Null
Assert-Equal $captured (ConvertTo-Json $script:entries[0].compensationSnapshot -Depth 12 -Compress) "Reads or a promotion repriced final history."
$oldForm = (New-Gc179FdfExportSet -EmployeeCode 0001 -MonthKey 2026-11).Exports[0]
Assert-Field $oldForm "Group" "IT"
Assert-Field $oldForm "RegTimeHalf.0" "7.5"
Assert-Field $oldForm "RegTime3Quarter.0" ""
$script:user.gc179Profile.group = "IT"

# IT 9.01(e): once double time is reached, a continuous period stays double
# even when the category/project changes. A real break ends that carry.
$first = New-TestEntry -Code 262 -Start "16:00:00" -End "18:00:00" -Duration "02:00:00"
$next = New-TestEntry -Start "18:00:00" -End "19:00:00" -Duration "01:00:00"
Assert-Equal $true (Test-SaphirOvertimeEntriesContinuous $first $next) "Continuous work not detected."
$script:entries = @($first, $next)
Set-ApprovedEntryCompensationSnapshots -EmployeeCode 0001 -Entries $script:entries | Out-Null
Assert-Equal "2" $next.compensationSnapshot.segments[0].multiplier "Money lost continuous double time."
$form = (New-Gc179FdfExportSet -EmployeeCode 0001 -MonthKey 2026-11).Exports[0]
Assert-Field $form "RegTimeDouble.1" "1"
$next.punchIn = "18:01:00"
Assert-Equal $false (Test-SaphirOvertimeEntriesContinuous $first $next) "A break was ignored."
$first | Add-Member -NotePropertyName exactPunchOut -NotePropertyValue "17:59:00"
$next.punchIn = "18:00:00"
Assert-Equal $false (Test-SaphirOvertimeEntriesContinuous $first $next) "Rounded times hid a real break."

# A neighboring first rest day, not just code 262, triggers the IT holiday
# question. GC179 remains editable with blank rates until it is answered.
$rest = New-TestEntry -Code 261 -Date "2026-11-04"
$holiday = New-TestEntry -Code 263 -Start "10:00:00" -End "11:00:00" -Duration "01:00:00"
$script:entries = @($rest, $holiday)
Set-ApprovedEntryCompensationSnapshots -EmployeeCode 0001 -Entries $script:entries | Out-Null
Assert-Equal "it-holiday-schedule-unconfirmed" $holiday.compensationSnapshot.unavailableReason "Holiday without schedule must be N/A."
$form = (New-Gc179FdfExportSet -EmployeeCode 0001 -MonthKey 2026-11).Exports[0]
Assert-Field $form "HolidayTimeHalf.1" ""
Assert-Field $form "HolidayTimeDbl.1" ""
$holiday | Add-Member -NotePropertyName holidayNotScheduledWorkday -NotePropertyValue $true
Set-ApprovedEntryCompensationSnapshots -EmployeeCode 0001 -Entries $script:entries | Out-Null
Assert-Equal "2" $holiday.compensationSnapshot.segments[0].multiplier "Confirmed unscheduled holiday must recover N/A."
$form = (New-Gc179FdfExportSet -EmployeeCode 0001 -MonthKey 2026-11).Exports[0]
Assert-Field $form "HolidayTimeDbl.1" "1"
Assert-Equal 64 $holiday.compensationSnapshot.sourceFingerprint.Length "Fingerprint must remain a hash."

# Calculate before the 16-row pagination boundary, preserving daily totals.
$script:entries = @(0..14 | ForEach-Object {
    $start = ([DateTime]"2026-11-05T00:00:00").AddMinutes(15 * $_)
    New-TestEntry -Start $start.ToString("HH:mm:ss") -End $start.AddMinutes(15).ToString("HH:mm:ss") -Duration "00:15:00"
})
$script:entries += New-TestEntry -Start "10:00:00" -End "14:00:00" -Duration "04:00:00"
$script:entries += New-TestEntry -Start "15:00:00" -End "15:15:00" -Duration "00:15:00"
$before = ConvertTo-Json -InputObject $script:entries -Depth 12 -Compress
$forms = New-Gc179FdfExportSet -EmployeeCode 0001 -MonthKey 2026-11
Assert-Equal 2 @($forms.Exports).Count "Pagination did not create a second form."
Assert-Field $forms.Exports[1] "RegTimeDouble.0" "0.25"
Assert-Field $forms.Exports[1] "RegTimeHalf.0" ""
Assert-Equal $before (ConvertTo-Json -InputObject $script:entries -Depth 12 -Compress) "GC179 mutated source DATA."
Write-Host "IT rules passed: eight salaries, no invented IT-01/03, regular/compressed rates, saved money/GC179 parity, continuous double time, holiday uncertainty/recovery, pagination, and captured history preservation."
