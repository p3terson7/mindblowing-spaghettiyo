$ErrorActionPreference = "Stop"

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -cne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-TextField {
    param([string]$Content, [string]$Name, [AllowEmptyString()][string]$Expected)
    $pattern = "/T \(" + [regex]::Escape($Name) + "\)\s*/V \(" + [regex]::Escape($Expected) + "\)"
    Assert-Equal $true ([regex]::IsMatch($Content, $pattern)) "Incorrect GC179 text field $Name."
}

function Assert-NameField {
    param([string]$Content, [string]$Name, [string]$Expected)
    $pattern = "/T \(" + [regex]::Escape($Name) + "\)\s*/V /" + [regex]::Escape($Expected) + "\s"
    Assert-Equal $true ([regex]::IsMatch($Content, $pattern)) "Incorrect GC179 name field $Name."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Import-Module (Join-Path $repoRoot "app/backend/modules/Saphir.Gc179Profile.psd1") -Force
. (Join-Path $repoRoot "app/backend/services/Gc179ExportService.ps1")

# Exercise the production selection/grouping/rendering pipeline, using only
# in-memory employee records. No shared DATA or local launch files are touched.
function Ensure-EmployeeDataFile {
    param([string]$EmployeeCode)
    Assert-Equal "123456789" $EmployeeCode "Unexpected employee."
    return "memory-fixture"
}
function Get-CachedEmployeeEntriesForFile {
    param([string]$DataFile)
    Assert-Equal "memory-fixture" $DataFile "Export tried to read a real employee file."
    return $script:FixtureEntries
}
function Get-EmployeeUserByCode {
    param([string]$EmployeeCode)
    return [PSCustomObject]@{
        displayName = "Test Employee"
        gc179Profile = [PSCustomObject]@{
            surname = "EMPLOYEE"; givenName = "TEST"; group = "STS"
            subGroup = "00"; level = "01"; compressedWorkWeek = $false
        }
    }
}
function Convert-ToNormalizedTimeText {
    param([string]$TimeText)
    if ($TimeText -match "^\d{2}:\d{2}:\d{2}$") { return $TimeText }
    if ($TimeText -match "^\d{2}:\d{2}$") { return ($TimeText + ":00") }
    return ""
}
function New-TestEntry {
    param([string]$Type = "diverse", [string]$Schedule = "regular", [string]$Date = "2026-11-05")
    return [PSCustomObject]@{
        entryId = [Guid]::NewGuid().ToString("N"); entryType = $Type
        date = $Date; punchIn = "17:00:00"; punchOut = "19:00:00"
        overtime = "02:00:00"; status = "approved"; workSchedule = $Schedule
        overtimeCode = ""; reasonCode = ""; paymentOption = ""
        diverseReason = "Travail divers"; diverseSummary = "Description conservée"
    }
}
function Export-Fixture {
    return (New-Gc179FdfExportSet -EmployeeCode "123456789" -MonthKey "2026-11")
}
function Assert-DiverseRow {
    param($Export, [int]$Index, [string]$Day = "05", [string]$Start = "17:00", [string]$End = "19:00")
    Assert-TextField $Export.Content "DayofWeek.$Index" $Day
    Assert-TextField $Export.Content "StartTime.$Index" $Start
    Assert-TextField $Export.Content "EndTime.$Index" $End
    Assert-TextField $Export.Content "OvertimeCode.$Index" "260"
    Assert-TextField $Export.Content "OTCODE.$Index" "D"
    Assert-NameField $Export.Content (Get-Gc179PaymentFieldName -RowIndex $Index) "1"
    foreach ($definition in @(Get-Gc179DurationFieldDefinitions)) {
        foreach ($field in @($definition.Field1, $definition.Field15, $definition.Field175, $definition.Field2)) {
            Assert-TextField $Export.Content "$field.$Index" ""
        }
    }
}

# Both confirmed schedules and old diverse entries with no schedule can be
# exported without inventing an entitlement or requiring a profile change.
foreach ($schedule in @("regular", "compressed", "unconfirmed", "")) {
    $entry = New-TestEntry -Schedule $schedule
    if ($schedule -eq "") { $entry.PSObject.Properties.Remove("workSchedule") }
    $script:FixtureEntries = @($entry)
    $before = ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress
    $exportSet = Export-Fixture
    Assert-Equal 1 @($exportSet.Entries).Count "Diverse entry was excluded."
    Assert-Equal 1 @($exportSet.Exports).Count "Unexpected diverse form count."
    Assert-DiverseRow $exportSet.Exports[0] 0
    Assert-TextField $exportSet.Exports[0].Content "Month" "11"
    Assert-TextField $exportSet.Exports[0].Content "Year" "2026"
    Assert-Equal $false ($exportSet.Exports[0].FileName -like "*_TEMPS.fdf") "Default cash must not add TEMPS suffix."
    Assert-Equal $before (ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress) "Export mutated the source entry."
}

# Even stale source metadata cannot populate rate columns or change the
# requested export defaults, and must never affect other entries' rates.
$diverse = New-TestEntry
$diverse.overtimeCode = "262"
$diverse.reasonCode = "B"
$diverse.paymentOption = "leave"
$diverse.overtime = "08:00:00"
$diverse | Add-Member -NotePropertyName gc179RateComponents -NotePropertyValue @(
    [PSCustomObject]@{ field = "RegTimeDouble"; hours = "8" }
)
Assert-Equal 0 (Get-Gc179ExportDurationFields -Entry $diverse).Count "Diverse rate components must be ignored."
Assert-Equal $false (Test-Gc179WorkedDateEntry -Entry $diverse) "Diverse entry must not establish a paid second rest day."
$project = New-TestEntry -Type "overtime"
$project.overtimeCode = "260"; $project.reasonCode = "B"; $project.paymentOption = "leave"
$project.punchIn = "20:00:00"; $project.punchOut = "22:00:00"
$script:FixtureEntries = @($project, $diverse)
$before = ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress
$mixed = Export-Fixture
Assert-Equal 2 @($mixed.Entries).Count "Mixed month lost an entry."
Assert-DiverseRow $mixed.Exports[0] 0
Assert-TextField $mixed.Exports[0].Content "RegTimeHalf.1" "2"
Assert-TextField $mixed.Exports[0].Content "RegTimeDouble.1" ""
Assert-TextField $mixed.Exports[0].Content "OTCODE.1" "B"
Assert-NameField $mixed.Exports[0].Content "Payment1" "2"
Assert-Equal $true ($mixed.Exports[0].FileName -like "*_TEMPS.fdf") "Actual project leave payment must retain TEMPS suffix."
Assert-Equal $before (ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress) "Mixed export rewrote source metadata."
$script:FixtureEntries = @($diverse)
$cashOnly = Export-Fixture
Assert-Equal $false ($cashOnly.Exports[0].FileName -like "*_TEMPS.fdf") "Stale diverse leave value changed the cash export filename."

# Existing month/status/completion/zero-credit filters remain in force.
$rejected = New-TestEntry; $rejected.status = "rejected"
$open = New-TestEntry; $open.punchOut = $null
$zero = New-TestEntry; $zero.overtime = "00:00:00"
$previousMonth = New-TestEntry -Date "2026-10-31"
$pending = New-TestEntry; $pending.status = "pending"
$script:FixtureEntries = @($rejected, $open, $zero, $previousMonth, $pending)
$filtered = Export-Fixture
Assert-Equal 1 @($filtered.Entries).Count "Diverse export bypassed existing entry filters."
Assert-DiverseRow $filtered.Exports[0] 0

# More than 16 diverse entries use the same pagination and defaults on every
# page, while known regular/compressed schedules remain on separate forms.
$script:FixtureEntries = @(1..17 | ForEach-Object { New-TestEntry -Date ("2026-11-{0:00}" -f $_) })
$multiPage = Export-Fixture
Assert-Equal 2 @($multiPage.Exports).Count "17 diverse rows must create two forms."
Assert-Equal 16 $multiPage.Exports[0].RowCount "First form capacity changed."
Assert-Equal 1 $multiPage.Exports[1].RowCount "Last diverse row disappeared."
Assert-DiverseRow $multiPage.Exports[1] 0 "17"
$script:FixtureEntries = @((New-TestEntry), (New-TestEntry -Schedule "compressed"), (New-TestEntry -Schedule "unconfirmed"))
$scheduleForms = Export-Fixture
Assert-Equal 3 @($scheduleForms.Exports).Count "Different stored schedules must not be mixed."
Assert-NameField $scheduleForms.Exports[0].Content "WorkWeek" "1"
Assert-NameField $scheduleForms.Exports[1].Content "WorkWeek" "2"
Assert-NameField $scheduleForms.Exports[2].Content "WorkWeek" "Off"

# Split only diverse clock intervals longer than 7.5 hours. Both rows keep
# blank entitlement columns, source data stays intact, and exactly 7.5 stays
# one row. No schedule or monetary settings are needed for this layout rule.
foreach ($case in @(
    @{ Schedule = "regular"; End = "20:00:00"; Rows = 2 },
    @{ Schedule = "compressed"; End = "20:00:00"; Rows = 2 },
    @{ Schedule = "unconfirmed"; End = "20:00:00"; Rows = 2 },
    @{ Schedule = "regular"; End = "17:30:00"; Rows = 1 },
    @{ Schedule = "regular"; End = "17:45:00"; Rows = 2 }
)) {
    $longEntry = New-TestEntry -Schedule $case.Schedule
    $longEntry.punchIn = "10:00:00"; $longEntry.punchOut = $case.End
    $longEntry.PSObject.Properties.Remove("overtime")
    $script:FixtureEntries = @($longEntry)
    $before = ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress
    $split = Export-Fixture
    Assert-Equal 1 @($split.Entries).Count "Export must retain the original entry count."
    Assert-Equal $case.Rows $split.Exports[0].RowCount "Incorrect split at 7.5 hours."
    Assert-DiverseRow $split.Exports[0] 0 "05" "10:00" "17:30"
    if ($case.Rows -eq 2) { Assert-DiverseRow $split.Exports[0] 1 "05" "17:30" $case.End.Substring(0, 5) }
    Assert-Equal $before (ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress) "Splitting mutated the original entry."
}

# Expansion must happen BEFORE the 16-row form limit, otherwise the tail of
# the final entry would be silently truncated.
$script:FixtureEntries = @(1..15 | ForEach-Object { New-TestEntry -Date ("2026-11-{0:00}" -f $_) })
$lastLongEntry = New-TestEntry -Date "2026-11-16"
$lastLongEntry.punchIn = "10:00:00"; $lastLongEntry.punchOut = "20:00:00"; $lastLongEntry.overtime = "10:00:00"
$script:FixtureEntries += $lastLongEntry
$splitPages = Export-Fixture
Assert-Equal 16 @($splitPages.Entries).Count "Source count must not become the expanded row count."
Assert-Equal 2 @($splitPages.Exports).Count "Split remainder was lost at the form boundary."
Assert-Equal 16 $splitPages.Exports[0].RowCount "Incorrect first form size after splitting."
Assert-Equal 1 $splitPages.Exports[1].RowCount "Incorrect remainder form size."
Assert-DiverseRow $splitPages.Exports[0] 15 "16" "10:00" "17:30"
Assert-DiverseRow $splitPages.Exports[1] 0 "16" "17:30" "20:00"

$longProject = New-TestEntry -Type "overtime"
$longProject.punchIn = "10:00:00"; $longProject.punchOut = "20:00:00"; $longProject.overtime = "10:00:00"
$longProject.overtimeCode = "260"; $longProject.reasonCode = "B"; $longProject.paymentOption = "cash"
$script:FixtureEntries = @($longProject)
$unchangedProject = Export-Fixture
Assert-Equal 1 $unchangedProject.Exports[0].RowCount "Diverse splitting changed project row layout."
Assert-TextField $unchangedProject.Exports[0].Content "RegTimeHalf.0" "7.5"
Assert-TextField $unchangedProject.Exports[0].Content "RegTimeDouble.0" "2.5"

# Legacy storage can hold exact times in the display fields. The GC179
# must still write quarters without reinterpreting the saved credit.
$legacyProject = $longProject.PSObject.Copy()
$legacyProject.punchIn = "14:04:00"; $legacyProject.punchOut = "14:24:00"; $legacyProject.overtime = "00:15:00"
$script:FixtureEntries = @($legacyProject)
$before = ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress
$legacyExport = Export-Fixture
Assert-TextField $legacyExport.Exports[0].Content "StartTime.0" "14:00"
Assert-TextField $legacyExport.Exports[0].Content "EndTime.0" "14:30"
Assert-TextField $legacyExport.Exports[0].Content "RegTimeHalf.0" "0.25"
Assert-Equal $before (ConvertTo-Json -InputObject $script:FixtureEntries -Depth 10 -Compress) "Export changed the legacy entry."

$legacyDiverse = New-TestEntry
$legacyDiverse.punchIn = "10:02:00"; $legacyDiverse.punchOut = "17:35:00"; $legacyDiverse.overtime = "07:30:00"
$script:FixtureEntries = @($legacyDiverse)
$legacySplit = Export-Fixture
Assert-Equal 1 $legacySplit.Exports[0].RowCount "A zero-length rounded tail must not produce a second row."
Assert-DiverseRow $legacySplit.Exports[0] 0 "05" "10:00" "17:30"
$legacyDiverse.punchOut = "20:04:00"; $legacyDiverse.overtime = "10:00:00"
$legacySplit = Export-Fixture
Assert-Equal 2 $legacySplit.Exports[0].RowCount "The legacy diverse session must still split at 7.5 hours."
Assert-DiverseRow $legacySplit.Exports[0] 0 "05" "10:00" "17:30"
Assert-DiverseRow $legacySplit.Exports[0] 1 "05" "17:30" "20:00"

# Stub the local file and process boundary; keep the actual export selection,
# split, grouping, and receipt assembly in use.
function New-Gc179LocalExportFolder {
    param([string]$EmployeeCode, [string]$MonthKey)
    return "gc179-fixture-${EmployeeCode}-${MonthKey}"
}
function Write-Gc179LocalExportWorkspace {
    param([string]$FolderPath, $ExportSet)
    if ($script:failWrite) { throw "Simulated write failure." }
    $script:writtenExport = $ExportSet
}
function Start-Gc179LocalExportWorkspace {
    param([string]$FolderPath)
    $script:launchCalls++
    if ($null -eq $script:writtenExport) { throw "Opening was attempted before the files were saved." }
    if ($script:failLaunch) { throw "Simulated opening failure." }
    return [PSCustomObject]@{ ProcessId = 42; LogPath = "fixture.out"; ErrorLogPath = "fixture.err" }
}
function Invoke-FixtureExport {
    return Start-Gc179LocalExport -EmployeeCode "123456789" -MonthKey "2026-11"
}
$script:failWrite = $false
$script:failLaunch = $false
$script:writtenExport = $null
$script:launchCalls = 0
$lastLongEntry.status = "pending"
$legacyPending = New-TestEntry; $legacyPending.PSObject.Properties.Remove("status")
$script:FixtureEntries = @($lastLongEntry, $legacyPending, $project, $rejected, $open, $zero, $previousMonth)
$receipt = Invoke-FixtureExport
Assert-Equal $true $receipt.prepared "The completed export was not marked prepared."
Assert-Equal $true $receipt.launched "The opening request was not acknowledged."
Assert-Equal "2026-11" $receipt.monthKey "The receipt lost the requested month."
Assert-Equal "gc179-fixture-123456789-2026-11" $receipt.folderPath "The receipt lost the local folder."
Assert-Equal 3 $receipt.entryCount "The receipt must count the source entries, not the expanded rows."
Assert-Equal 2 $receipt.pendingCount "The receipt must count pending entries that actually appear in the export."
Assert-Equal 4 $receipt.rowCount "The receipt lost the extra row created by splitting a long entry."
Assert-Equal 1 $receipt.partCount "The receipt lost the form count."

$script:failLaunch = $true
$saved = Invoke-FixtureExport
Assert-Equal $true $saved.prepared "A launch failure must not hide the already-saved files."
Assert-Equal $false $saved.launched "A launch failure must not claim Acrobat was started."
Assert-Equal $receipt.folderPath $saved.folderPath "The saved files must remain findable."
Assert-Equal 2 $script:launchCalls "Failed export must not launch a second process from the receipt service."

$script:failLaunch = $false
$script:FixtureEntries = @($rejected, $open, $zero, $previousMonth)
$blankReceipt = Invoke-FixtureExport
Assert-Equal 0 $blankReceipt.entryCount "The blank-form count must be zero."
Assert-Equal 0 $blankReceipt.rowCount "The blank-form row count must be zero."
Assert-Equal 1 $blankReceipt.partCount "The existing blank form must still be created."

$script:failWrite = $true
try {
    $null = Invoke-FixtureExport
    throw "Expected the write error to reach the caller."
}
catch {
    Assert-Equal "Simulated write failure." $_.Exception.Message "A write failure must not return a prepared receipt."
}
Assert-Equal 3 $script:launchCalls "A failed write must not attempt to open the export."

Write-Host "GC179 export passed: existing filters, diverse splits, project rates and receipts for success, blank forms, launch failures and write failures."
