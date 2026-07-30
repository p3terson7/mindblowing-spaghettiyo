$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "Assertion failed: $Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $caughtMessage = ""
    try {
        & $Action
    }
    catch {
        $caughtMessage = [string]$_.Exception.Message
    }

    if ([string]::IsNullOrWhiteSpace($caughtMessage) -or $caughtMessage -notlike "*$MessagePattern*") {
        throw "Assertion failed: $Message Expected an error containing '$MessagePattern', got '$caughtMessage'."
    }
}

function Assert-HasProperty {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($null -eq $Value -or $Value.PSObject.Properties.Name -notcontains $PropertyName) {
        throw "Assertion failed: $Message Missing property '$PropertyName'."
    }
}

function Assert-Contains {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$ExpectedText,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Value -notlike "*$ExpectedText*") {
        throw "Assertion failed: $Message Expected '$Value' to contain '$ExpectedText'."
    }
}

function Set-FdfFieldValue {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $escapedName = [regex]::Escape($FieldName)
    $pattern = "(/T\s*\($escapedName\)\s*/V\s*)\((\\.|[^\\)])*\)"
    $replacementValue = $Value.Replace("\", "\\").Replace("(", "\(").Replace(")", "\)")
    $replacement = '${1}(' + $replacementValue + ')'
    $updated = [regex]::Replace($Content, $pattern, $replacement, 1)
    if ($updated -eq $Content) {
        throw "Test setup failed: FDF field '$FieldName' was not found."
    }

    return $updated
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Get-Item -LiteralPath $scriptRoot).Parent.FullName
$servicePath = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/Gc179ImportService.ps1"
$exportServicePath = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/Gc179ExportService.ps1"
$routePath = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/gc179-import.routes.ps1"
$fixturePath = Join-Path -Path $repoRoot -ChildPath "scripts/gc179-000100001-2026-05.fdf"
$templatePath = Join-Path -Path $repoRoot -ChildPath "docs/GC179.pdf"
$generatedExamplePath = Join-Path -Path $repoRoot -ChildPath "tmp-gc179-generated.ps1"
$fixtureExpectedSha256 = "2D2DC449640389118B33506AB884EBB912BA7E1410AB451CC26E596D41E02EE0"
$templateExpectedSha256 = "B5E7FE0C63BB318C6FE3599D211DA233671D44E0A2D39E9FAA8371B84865FA58"
$generatedExampleExpectedSha256 = "A1192CB9A13B93F981B2B41FBBB5D76943824F747335D044AED52BA3B32FEC05"

Assert-True -Condition (Test-Path -LiteralPath $servicePath -PathType Leaf) -Message "The production GC179 import service is missing."
Assert-True -Condition (Test-Path -LiteralPath $exportServicePath -PathType Leaf) -Message "The production GC179 export service is missing."
Assert-True -Condition (Test-Path -LiteralPath $routePath -PathType Leaf) -Message "The production GC179 import route is missing."
Assert-True -Condition (Test-Path -LiteralPath $fixturePath -PathType Leaf) -Message "The repository's real GC179 FDF example is missing."
Assert-True -Condition (Test-Path -LiteralPath $templatePath -PathType Leaf) -Message "The repository's original GC179 PDF template is missing."
Assert-True -Condition (Test-Path -LiteralPath $generatedExamplePath -PathType Leaf) -Message "The root GC179 generation example is missing."
Assert-Equal -Expected $fixtureExpectedSha256 -Actual ((Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToUpperInvariant()) -Message "The real GC179 example changed; update the production parser deliberately instead of rewriting the fixture."
Assert-Equal -Expected $templateExpectedSha256 -Actual ((Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToUpperInvariant()) -Message "The original GC179 PDF changed; import work must not rewrite the source form."
Assert-Equal -Expected $generatedExampleExpectedSha256 -Actual ((Get-FileHash -LiteralPath $generatedExamplePath -Algorithm SHA256).Hash.ToUpperInvariant()) -Message "The root GC179 generation example changed; import work must preserve its exact structure."

$fixtureContent = [System.IO.File]::ReadAllText($fixturePath, [System.Text.Encoding]::UTF8)
Assert-True -Condition $fixtureContent.StartsWith("%FDF-1.2") -Message "The GC179 example must remain an FDF 1.2 document."
Assert-True -Condition ($fixtureContent.TrimEnd().EndsWith("%%EOF")) -Message "The GC179 example lost its FDF end marker."

. $servicePath

$legacySingleEntryPath = Join-Path -Path $repoRoot -ChildPath "v1_data/data/000321928_data.json"
Assert-True -Condition (Test-Path -LiteralPath $legacySingleEntryPath -PathType Leaf) -Message "The v1 single-entry compatibility fixture is missing."
$legacySingleEntries = @(Read-Gc179EmployeeDataStrict -Path $legacySingleEntryPath)
Assert-Equal -Expected 1 -Actual $legacySingleEntries.Count -Message "GC179 strict reads must accept a v1 one-entry JSON object root."

Assert-Gc179ImportPayload -FdfContent $fixtureContent -FileName "gc179-000100001-2026-05.fdf" -ManagerMessage "Valid note"
Assert-Throws -Action {
    Assert-Gc179ImportPayload -FdfContent $fixtureContent -FileName "completed-form.pdf" -ManagerMessage ""
} -MessagePattern ".fdf extension" -Message "The import service must reject a PDF passed in place of an Acrobat FDF."
Assert-Throws -Action {
    Assert-Gc179ImportPayload -FdfContent "not an fdf" -FileName "completed-form.fdf" -ManagerMessage ""
} -MessagePattern "not an Acrobat FDF" -Message "The import service must verify the FDF document marker."

$fixtureFields = Read-Gc179ImportFdfFields -FdfContent $fixtureContent
Assert-Equal -Expected 114 -Actual $fixtureFields.Count -Message "The real GC179 example no longer maps to the expected field structure."
Assert-Equal -Expected "5" -Actual $fixtureFields["Month"] -Message "The real fixture month was parsed incorrectly."
Assert-Equal -Expected "2026" -Actual $fixtureFields["Year"] -Message "The real fixture year was parsed incorrectly."
Assert-Equal -Expected "04" -Actual $fixtureFields["DayofWeek.0"] -Message "The first GC179 row day was parsed incorrectly."
Assert-Equal -Expected "1" -Actual $fixtureFields["Payment"] -Message "The first GC179 payment radio value was parsed incorrectly."
Assert-Equal -Expected "2" -Actual $fixtureFields["Payment1"] -Message "The second GC179 payment radio value was parsed incorrectly."

$fixturePreview = New-Gc179ImportPreview `
    -FdfContent $fixtureContent `
    -EmployeeCode "000100001" `
    -ProjectCode "TEST" `
    -FileName "gc179-000100001-2026-05.fdf" `
    -Status "pending" `
    -ManagerMessage "Regression fixture"

Assert-Equal -Expected "2026-05" -Actual $fixturePreview.monthKey -Message "The real GC179 fixture month key was parsed incorrectly."
Assert-Equal -Expected 2 -Actual $fixturePreview.entryCount -Message "The real GC179 fixture must produce exactly two overtime rows."
Assert-Equal -Expected 0 -Actual @($fixturePreview.warnings).Count -Message "The valid real GC179 fixture must not produce parser warnings."

$firstEntry = @($fixturePreview.entries)[0]
$secondEntry = @($fixturePreview.entries)[1]
Assert-Equal -Expected "2026-05-04" -Actual $firstEntry.date -Message "The first fixture row date was mapped incorrectly."
Assert-Equal -Expected "15:45:00" -Actual $firstEntry.punchIn -Message "The first fixture row start time was mapped incorrectly."
Assert-Equal -Expected "17:30:00" -Actual $firstEntry.punchOut -Message "The first fixture row end time was mapped incorrectly."
Assert-Equal -Expected "01:45:00" -Actual $firstEntry.overtime -Message "The first fixture row duration was mapped incorrectly."
Assert-Equal -Expected "262" -Actual $firstEntry.overtimeCode -Message "The first fixture row overtime code was mapped incorrectly."
Assert-Equal -Expected "cash" -Actual $firstEntry.paymentOption -Message "The first fixture row payment option was mapped incorrectly."
Assert-Equal -Expected "C" -Actual $firstEntry.reasonCode -Message "The first fixture row reason was mapped incorrectly."
Assert-Equal -Expected 0 -Actual $firstEntry.sourceRow -Message "The first fixture row provenance was mapped incorrectly."

Assert-Equal -Expected "2026-05-21" -Actual $secondEntry.date -Message "The second fixture row date was mapped incorrectly."
Assert-Equal -Expected "07:30:00" -Actual $secondEntry.punchIn -Message "The second fixture row start time was mapped incorrectly."
Assert-Equal -Expected "08:30:00" -Actual $secondEntry.punchOut -Message "The second fixture row end time was mapped incorrectly."
Assert-Equal -Expected "01:00:00" -Actual $secondEntry.overtime -Message "The second fixture row duration was mapped incorrectly."
Assert-Equal -Expected "261" -Actual $secondEntry.overtimeCode -Message "The second fixture row overtime code was mapped incorrectly."
Assert-Equal -Expected "leave" -Actual $secondEntry.paymentOption -Message "The second fixture row payment option was mapped incorrectly."
Assert-Equal -Expected "B" -Actual $secondEntry.reasonCode -Message "The second fixture row reason was mapped incorrectly."
Assert-Equal -Expected 1 -Actual $secondEntry.sourceRow -Message "The second fixture row provenance was mapped incorrectly."

$defaultStatusPreview = New-Gc179ImportPreview `
    -FdfContent $fixtureContent `
    -EmployeeCode "000100001" `
    -ProjectCode "TEST" `
    -FileName "gc179-000100001-2026-05.fdf" `
    -Status "" `
    -ManagerMessage ""
Assert-Equal -Expected "pending" -Actual @($defaultStatusPreview.entries)[0].status -Message "GC179 imports must default to pending."
Assert-Throws -Action {
    New-Gc179ImportPreview -FdfContent $fixtureContent -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "fixture.fdf" -Status "finished" -ManagerMessage "" | Out-Null
} -MessagePattern "Status must be" -Message "An invalid import status must not silently become approved."

$invalidMonthFdf = Set-FdfFieldValue -Content $fixtureContent -FieldName "Month" -Value "13"
Assert-Throws -Action {
    New-Gc179ImportPreview -FdfContent $invalidMonthFdf -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "fixture.fdf" -Status "pending" -ManagerMessage "" | Out-Null
} -MessagePattern "month" -Message "An invalid GC179 month must be rejected."

$invalidDayFdf = Set-FdfFieldValue -Content $fixtureContent -FieldName "DayofWeek.0" -Value "32"
$invalidDayPreview = New-Gc179ImportPreview -FdfContent $invalidDayFdf -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "fixture.fdf" -Status "pending" -ManagerMessage ""
Assert-Equal -Expected 1 -Actual $invalidDayPreview.entryCount -Message "A bad calendar row must be skipped without losing valid rows."
Assert-Equal -Expected 1 -Actual $invalidDayPreview.skippedRowCount -Message "The invalid calendar row must be counted as skipped."
Assert-Contains -Value (@($invalidDayPreview.warnings) -join " ") -ExpectedText "invalid calendar date" -Message "A bad calendar row must produce a clear warning."

# Real Acrobat exports repeated fields as /Kids groups rather than the flat
# `FieldName.row` structure used by SAPHIR's generated FDF. Keep both formats
# covered because the import UI is specifically intended for Acrobat exports.
$acrobatKidsFdf = @"
%FDF-1.2
1 0 obj
<< /FDF << /Fields [
<< /T(Month) /V(6) >>
<< /T(Year) /V(2026) >>
<< /T(PRI) /V(000100001) >>
<< /Kids [ << /T(0) /V(12) >> ] /T(DayofWeek) >>
<< /Kids [ << /T(0) /V(1800) >> ] /T(StartTime) >>
<< /Kids [ << /T(0) /V(2030) >> ] /T(EndTime) >>
<< /Kids [ << /T(0) /V(260) >> ] /T(OvertimeCode) >>
<< /Kids [ << /T(0) /V(D) >> ] /T(OTCODE) >>
<< /Kids [ << /T(0) /V(/1) >> ] /T(Payment) >>
<< /Kids [ << /T(0) /V(2.5) >> ] /T(FirstDayTimeHalf) >>
] >> >>
endobj
trailer << /Root 1 0 R >>
%%EOF
"@

$acrobatKidsPreview = New-Gc179ImportPreview `
    -FdfContent $acrobatKidsFdf `
    -EmployeeCode "000100001" `
    -ProjectCode "TEST" `
    -FileName "gc179-000100001-2026-06.fdf" `
    -Status "pending" `
    -ManagerMessage ""

Assert-Equal -Expected 1 -Actual $acrobatKidsPreview.entryCount -Message "Acrobat /Kids row groups must produce one row."
$acrobatEntry = @($acrobatKidsPreview.entries)[0]
Assert-Equal -Expected "2026-06-12" -Actual $acrobatEntry.date -Message "The Acrobat /Kids date was mapped incorrectly."
Assert-Equal -Expected "18:00:00" -Actual $acrobatEntry.punchIn -Message "The Acrobat /Kids compact start time was mapped incorrectly."
Assert-Equal -Expected "20:30:00" -Actual $acrobatEntry.punchOut -Message "The Acrobat /Kids compact end time was mapped incorrectly."
Assert-Equal -Expected "FirstDayTimeHalf" -Actual $acrobatEntry.gc179RateField -Message "A first-day-of-rest GC179 duration field was not preserved."
Assert-Equal -Expected "1.5" -Actual $acrobatEntry.gc179Rate -Message "The time-and-a-half GC179 rate was mapped incorrectly."
Assert-Equal -Expected "02:30:00" -Actual $acrobatEntry.overtime -Message "The time-and-a-half duration value was mapped incorrectly."

$mixedRateFdf = $acrobatKidsFdf.Replace(
    "<< /Kids [ << /T(0) /V(2.5) >> ] /T(FirstDayTimeHalf) >>",
    "<< /Kids [ << /T(0) /V(1.5) >> ] /T(FirstDayTimeHalf) >>`n<< /Kids [ << /T(0) /V(1) >> ] /T(FirstDayTimeDbl) >>"
)
$mixedRatePreview = New-Gc179ImportPreview -FdfContent $mixedRateFdf -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "gc179-000100001-2026-06.fdf" -Status "pending" -ManagerMessage ""
$mixedRateEntry = @($mixedRatePreview.entries)[0]
Assert-Equal -Expected "mixed" -Actual $mixedRateEntry.gc179RateField -Message "Split GC179 entitlement fields must be identified as mixed."
Assert-Equal -Expected "mixed" -Actual $mixedRateEntry.gc179Rate -Message "Split GC179 entitlement rates must be identified as mixed."
Assert-Equal -Expected "02:30:00" -Actual $mixedRateEntry.overtime -Message "Split GC179 duration columns must be summed."
Assert-Equal -Expected 2 -Actual @($mixedRateEntry.gc179RateComponents).Count -Message "Every split entitlement component must be retained."
Assert-Equal -Expected "FirstDayTimeHalf" -Actual @($mixedRateEntry.gc179RateComponents)[0].field -Message "The first split entitlement field was lost."
Assert-Equal -Expected "1.5" -Actual @($mixedRateEntry.gc179RateComponents)[0].hours -Message "The first split entitlement duration changed."
Assert-Equal -Expected "FirstDayTimeDbl" -Actual @($mixedRateEntry.gc179RateComponents)[1].field -Message "The second split entitlement field was lost."
Assert-Equal -Expected "1" -Actual @($mixedRateEntry.gc179RateComponents)[1].hours -Message "The second split entitlement duration changed."

$invalidDurationFdf = $acrobatKidsFdf.Replace("/V(2.5)", "/V(not-a-number)")
$invalidDurationPreview = New-Gc179ImportPreview -FdfContent $invalidDurationFdf -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "gc179-000100001-2026-06.fdf" -Status "pending" -ManagerMessage ""
$invalidDurationEntry = @($invalidDurationPreview.entries)[0]
Assert-Contains -Value (@($invalidDurationEntry.validationErrors) -join " ") -ExpectedText "invalid duration" -Message "A populated nonnumeric duration field must block that row."

# Generate an FDF with the current export service, then feed that exact output
# into the import service. This catches field-name or filename drift between
# the two sides without writing a temporary fixture or touching the real form.
$script:RoundTripEmployee = [PSCustomObject]@{
    displayName = "Jane Smith"
    gc179Profile = [PSCustomObject]@{
        surname            = "SMITH"
        givenName          = "JANE"
        initials           = "JS"
        pri                = "000123456"
        level              = "2"
        compressedWorkWeek = $false
    }
}

function Get-EmployeeUserByCode {
    param([string]$EmployeeCode)
    return $script:RoundTripEmployee
}

function Get-EmployeeName {
    param([string]$EmployeeCode)
    return [string]$script:RoundTripEmployee.displayName
}

function Get-Gc179ProfileFromUserRecord {
    param($UserRecord)
    return $UserRecord.gc179Profile
}

function ConvertTo-Gc179ProfileObject {
    param($Value, [string]$DisplayName)
    return $script:RoundTripEmployee.gc179Profile
}

function ConvertTo-Gc179PriText {
    param([string]$Value)
    $digits = ([string]$Value) -replace "\D", ""
    if ($digits.Length -eq 9) {
        return ("{0} {1} {2}" -f $digits.Substring(0, 3), $digits.Substring(3, 3), $digits.Substring(6, 3))
    }
    return $digits
}

function Convert-ToNormalizedTimeText {
    param([string]$TimeText)
    $candidate = ([string]$TimeText).Trim()
    if ($candidate -match "^\d{2}:\d{2}:\d{2}$") {
        return $candidate
    }
    if ($candidate -match "^\d{2}:\d{2}$") {
        return "$candidate`:00"
    }
    return $null
}

. $exportServicePath

$roundTripMonth = ConvertTo-Gc179MonthParts -MonthKey "2026-07"
$roundTripEntry = [PSCustomObject]@{
    entryType     = "overtime"
    date          = "2026-07-05"
    punchIn       = "09:15:00"
    punchOut      = "10:45:00"
    overtime      = "01:30:00"
    status        = "approved"
    overtimeCode  = "262"
    paymentOption = "leave"
    reasonCode    = "B"
}
$roundTripWorkedDates = @{ "2026-07-04" = $true; "2026-07-05" = $true }
$roundTripExport = New-Gc179FdfExportPart `
    -EmployeeCode "000123456" `
    -MonthParts $roundTripMonth `
    -Entries @($roundTripEntry) `
    -WorkedDateSet $roundTripWorkedDates

Assert-Equal -Expected "000123456_SMITH_JANE_GC179_2026_07.fdf" -Actual $roundTripExport.FileName -Message "The current GC179 export filename contract changed."
Assert-True -Condition ([string]$roundTripExport.Content).StartsWith("%FDF-1.2") -Message "The export service must still produce FDF 1.2 content."

$roundTripPreview = New-Gc179ImportPreview `
    -FdfContent ([string]$roundTripExport.Content) `
    -EmployeeCode "000123456" `
    -ProjectCode "ROUNDTRIP" `
    -FileName ([string]$roundTripExport.FileName) `
    -Status "pending" `
    -ManagerMessage "Round trip"

Assert-Equal -Expected 1 -Actual $roundTripPreview.entryCount -Message "The import service could not read current export output."
Assert-Equal -Expected "000 123 456" -Actual $roundTripPreview.header.pri -Message "The GC179 PRI header did not survive export/import."
$roundTripImportedEntry = @($roundTripPreview.entries)[0]
Assert-Equal -Expected "2026-07-05" -Actual $roundTripImportedEntry.date -Message "The round-trip entry date changed."
Assert-Equal -Expected "09:15:00" -Actual $roundTripImportedEntry.punchIn -Message "The round-trip start time changed."
Assert-Equal -Expected "10:45:00" -Actual $roundTripImportedEntry.punchOut -Message "The round-trip end time changed."
Assert-Equal -Expected "01:30:00" -Actual $roundTripImportedEntry.overtime -Message "The round-trip duration changed."
Assert-Equal -Expected "RegTimeDouble" -Actual $roundTripImportedEntry.gc179RateField -Message "The round-trip Sunday double-time field changed."
Assert-Equal -Expected "2.0" -Actual $roundTripImportedEntry.gc179Rate -Message "The round-trip Sunday rate changed."
Assert-Equal -Expected "262" -Actual $roundTripImportedEntry.overtimeCode -Message "The round-trip overtime code changed."
Assert-Equal -Expected "leave" -Actual $roundTripImportedEntry.paymentOption -Message "The round-trip payment choice changed."
Assert-Equal -Expected "B" -Actual $roundTripImportedEntry.reasonCode -Message "The round-trip reason code changed."

# Exercise the validated preview, duplicate detection, durable batch metadata,
# and undo logic against a disposable employee file. These stubs reproduce the
# file-store contract while guaranteeing that repository data is never touched.
$importTestFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("gc179-import-test-{0}" -f ([Guid]::NewGuid().ToString("N")))
$script:ImportDataFile = Join-Path -Path $importTestFolder -ChildPath "000100001_data.json"
$script:ImportWriteCount = 0
$script:ImportPublishCount = 0
$script:ImportEntrySequence = 0
$script:ImportHistoryCount = 0
$script:ImportHistoryPublishFlags = New-Object System.Collections.ArrayList
$script:ImportHistoryCountAtPublication = New-Object System.Collections.ArrayList

function Ensure-EmployeeDataFile {
    param([string]$EmployeeCode)
    if (-not (Test-Path -LiteralPath $script:ImportDataFile -PathType Leaf)) {
        [System.IO.File]::WriteAllText($script:ImportDataFile, "[]", [System.Text.Encoding]::UTF8)
    }
    return $script:ImportDataFile
}

function Acquire-ResourceLock {
    param([string]$ResourcePath)
    return [PSCustomObject]@{ ResourcePath = $ResourcePath }
}

function Release-ResourceLock {
    param($LockHandle)
}

function Read-JsonArrayFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }
    return @($raw | ConvertFrom-Json)
}

function Write-JsonAtomic {
    param([string]$Path, $Value, [int]$Depth = 6)
    $script:ImportWriteCount++
    $json = ConvertTo-Json -InputObject @($Value) -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Write-JsonArrayAtomic {
    param([string]$Path, $Items = @(), [int]$Depth = 6)
    Write-JsonAtomic -Path $Path -Value @($Items) -Depth $Depth
}

function Publish-DataChange {
    param([string]$Category = "data", [string]$Resource = "shared", [string[]]$AffectedEmployeeCodes = @())
    $script:ImportPublishCount++
    [void]$script:ImportHistoryCountAtPublication.Add($script:ImportHistoryCount)
}

function New-EntryIdentifier {
    $script:ImportEntrySequence++
    return ("gc179-test-entry-{0}" -f $script:ImportEntrySequence)
}

function Test-OptionCode {
    param($Options, [string]$Code, [bool]$AllowBlank = $false)
    $normalizedCode = ([string]$Code).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedCode)) {
        return $AllowBlank
    }
    return (@($Options | Where-Object { ([string]$_.code).Trim() -eq $normalizedCode }).Count -gt 0)
}

function Get-OvertimeCodes {
    return @(
        [PSCustomObject]@{ code = "" },
        [PSCustomObject]@{ code = "260" },
        [PSCustomObject]@{ code = "261" },
        [PSCustomObject]@{ code = "262" }
    )
}

function Get-PaymentOptions {
    return @([PSCustomObject]@{ code = "cash" }, [PSCustomObject]@{ code = "leave" })
}

function Get-ReasonCodes {
    return @(
        [PSCustomObject]@{ code = "" },
        [PSCustomObject]@{ code = "B" },
        [PSCustomObject]@{ code = "C" },
        [PSCustomObject]@{ code = "D" }
    )
}

function Test-CurrentUserCanModifyProjectCode {
    param($CurrentUser, [string]$ProjectCode)
    return $true
}

function Acquire-ProjectReferenceLock {
    return [PSCustomObject]@{ ResourcePath = ".project-references" }
}

function Test-ActiveProjectCodeFromDisk {
    param([string]$ProjectCode)
    return $ProjectCode -eq "TEST"
}

function Test-CurrentUserCanModifyActiveProjectCodeFromDisk {
    param($CurrentUser, [string]$ProjectCode)
    return $ProjectCode -eq "TEST"
}

$script:RoutePayload = $null
$script:RouteEmployee = $null
$script:RouteStatusCode = 0
$script:RouteResponseText = ""

function Read-JsonRequestBody {
    param($Request)
    return $script:RoutePayload
}

function respondWithSuccess {
    param($Response, [string]$Message)
    $script:RouteStatusCode = 200
    $script:RouteResponseText = $Message
}

function respondWithError {
    param($Response, [int]$StatusCode, [string]$Message)
    $script:RouteStatusCode = $StatusCode
    $script:RouteResponseText = $Message
}

function Convert-ToBooleanFlag {
    param($Value)
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    return (([string]$Value).Trim().ToLowerInvariant() -eq "true")
}

function Get-EmployeeUserByCode {
    param([string]$EmployeeCode)
    return $script:RouteEmployee
}

function Test-CurrentUserMatchesEmployeeCode {
    param($CurrentUser, [string]$EmployeeCode)
    return $false
}

function Get-ActiveProjects {
    return @([PSCustomObject]@{ projectCode = "TEST"; active = $true })
}

function Get-EffectiveUserRole {
    param($UserRecord)
    return "employee"
}

function Get-EmployeeRoleByCode {
    param([string]$EmployeeCode)
    return "employee"
}

function Test-CurrentUserCanApproveEmployeeRole {
    param($CurrentUser, [string]$EmployeeRole)
    return $true
}

function logHistory {
    param(
        [string]$Action,
        [string]$Message,
        [string]$EmployeeName,
        [bool]$PublishChange = $true
    )
    $script:ImportHistoryCount++
    [void]$script:ImportHistoryPublishFlags.Add($PublishChange)
}

function Invoke-Gc179ImportRouteForTest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Method = "POST",
        [bool]$Enabled = $true
    )

    $request = [PSCustomObject]@{
        HttpMethod = $Method
        Url        = [PSCustomObject]@{ AbsolutePath = $Path }
    }
    $response = [PSCustomObject]@{}
    $currentUser = [PSCustomObject]@{ username = "manager"; displayName = "Manager"; role = "superAdmin" }
    $gc179ImportEnabled = $Enabled
    $script:RouteStatusCode = 0
    $script:RouteResponseText = ""

    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . $routePath
    }

    $body = $script:RouteResponseText
    if ($script:RouteStatusCode -eq 200 -and -not [string]::IsNullOrWhiteSpace($script:RouteResponseText)) {
        $body = $script:RouteResponseText | ConvertFrom-Json
    }
    return [PSCustomObject]@{
        StatusCode = $script:RouteStatusCode
        Body       = $body
    }
}

try {
    New-Item -ItemType Directory -Path $importTestFolder | Out-Null
    [System.IO.File]::WriteAllText($script:ImportDataFile, "[]", [System.Text.Encoding]::UTF8)

    $targetEmployee = [PSCustomObject]@{
        displayName = "Fixture Employee"
        disabled = $false
        role = "employee"
        gc179Profile = [PSCustomObject]@{
            pri = "000 100 001"
        }
    }

    # A normal SAPHIR row predating GC179 provenance has no rate-components
    # array. If its shift and total duration match current export output, it is
    # still an exact duplicate rather than a false conflict.
    $legacySaphirEntry = [PSCustomObject]@{
        entryId        = "legacy-entry"
        entryType      = "overtime"
        name           = "Jane Smith"
        date           = "2026-07-05"
        punchIn        = "09:15:00"
        exactPunchIn   = "09:15:00"
        punchOut       = "10:45:00"
        exactPunchOut  = "10:45:00"
        overtime       = "01:30:00"
        status         = "approved"
        message        = ""
        projectCode    = "ROUNDTRIP"
        overtimeCode   = "262"
        paymentOption  = "leave"
        reasonCode     = "B"
    }
    [System.IO.File]::WriteAllText($script:ImportDataFile, (ConvertTo-Json -InputObject @($legacySaphirEntry) -Depth 8), [System.Text.Encoding]::UTF8)
    $roundTripTarget = [PSCustomObject]@{
        displayName = "Jane Smith"
        gc179Profile = [PSCustomObject]@{ pri = "000 123 456" }
    }
    $legacyDuplicatePreview = New-Gc179ImportPreview -FdfContent ([string]$roundTripExport.Content) -EmployeeCode "000123456" -ProjectCode "ROUNDTRIP" -FileName ([string]$roundTripExport.FileName) -Status "pending" -ManagerMessage ""
    $legacyDuplicatePreview = Complete-Gc179ImportPreview -Preview $legacyDuplicatePreview -EmployeeUser $roundTripTarget -EmployeeCode "000123456" -EmployeeName "Jane Smith" -FileName ([string]$roundTripExport.FileName) -SkipDuplicates:$true
    $legacyDuplicateEntry = @($legacyDuplicatePreview.entries)[0]
    Assert-Equal -Expected "exact" -Actual $legacyDuplicateEntry.duplicateStatus -Message "A matching normal SAPHIR entry without GC179 rate components must be an exact duplicate."
    Assert-True -Condition (-not [bool]$legacyDuplicateEntry.canImport) -Message "A matching legacy SAPHIR entry must be skipped rather than imported again."
    [System.IO.File]::WriteAllText($script:ImportDataFile, "[]", [System.Text.Encoding]::UTF8)

    $script:RouteEmployee = $targetEmployee
    $script:RoutePayload = [PSCustomObject]@{
        employeeCode    = "000100001"
        projectCode     = "TEST"
        fdfContent      = $fixtureContent
        fileName        = "gc179-000100001-2026-05.fdf"
        status          = "pending"
        managerMessage  = "Route preview"
        confirmIdentity = $false
    }

    $disabledRoute = Invoke-Gc179ImportRouteForTest -Path "/employee/gc179-import/preview" -Enabled:$false
    Assert-Equal -Expected 404 -Actual $disabledRoute.StatusCode -Message "The backend feature flag must disable GC179 routes, not merely hide the UI."
    Assert-Contains -Value ([string]$disabledRoute.Body) -ExpectedText "not enabled" -Message "A disabled GC179 route must explain why it is unavailable."

    $previewRoute = Invoke-Gc179ImportRouteForTest -Path "/employee/gc179-import/preview" -Enabled:$true
    Assert-Equal -Expected 200 -Actual $previewRoute.StatusCode -Message "The enabled preview route rejected the valid real fixture."
    Assert-Equal -Expected "matched" -Actual $previewRoute.Body.identity.status -Message "The preview route did not return the validated identity."
    Assert-True -Condition ([bool]$previewRoute.Body.canCommit) -Message "The preview route did not mark the valid fixture as committable."

    $script:RoutePayload.status = "finished"
    $invalidStatusRoute = Invoke-Gc179ImportRouteForTest -Path "/employee/gc179-import/preview" -Enabled:$true
    Assert-Equal -Expected 400 -Actual $invalidStatusRoute.StatusCode -Message "The route must reject an unknown GC179 status."
    Assert-Contains -Value ([string]$invalidStatusRoute.Body) -ExpectedText "Status must be" -Message "The route must return a clear invalid-status error."
    $script:RoutePayload.status = "pending"

    $validatedPreview = New-Gc179ImportPreview -FdfContent $fixtureContent -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "gc179-000100001-2026-05.fdf" -Status "pending" -ManagerMessage "Validated fixture"
    $validatedPreview = Complete-Gc179ImportPreview -Preview $validatedPreview -EmployeeUser $targetEmployee -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -FileName "gc179-000100001-2026-05.fdf" -SkipDuplicates:$true
    Assert-Equal -Expected "matched" -Actual $validatedPreview.identity.status -Message "The real fixture must match its target using the employee code in its filename."
    Assert-Equal -Expected "000100001" -Actual $validatedPreview.identity.sourceEmployeeCode -Message "The filename employee code was not extracted."
    Assert-Equal -Expected 2 -Actual $validatedPreview.counts.parsed -Message "Validated preview returned the wrong parsed-row count."
    Assert-Equal -Expected 2 -Actual $validatedPreview.counts.valid -Message "Validated preview returned the wrong valid-row count."
    Assert-Equal -Expected 2 -Actual $validatedPreview.counts.importable -Message "Validated preview returned the wrong importable-row count."
    Assert-Equal -Expected 0 -Actual $validatedPreview.counts.errors -Message "The valid fixture must not contain validation errors."
    Assert-True -Condition ([bool]$validatedPreview.canCommit) -Message "A matching, valid fixture must be committable."

    $identityMismatch = New-Gc179ImportPreview -FdfContent $fixtureContent -EmployeeCode "000100002" -ProjectCode "TEST" -FileName "gc179-000100001-2026-05.fdf" -Status "pending" -ManagerMessage ""
    $identityMismatch = Complete-Gc179ImportPreview -Preview $identityMismatch -EmployeeUser $targetEmployee -EmployeeCode "000100002" -EmployeeName "Wrong Employee" -FileName "gc179-000100001-2026-05.fdf" -SkipDuplicates:$true
    Assert-Equal -Expected "mismatch" -Actual $identityMismatch.identity.status -Message "Selecting an employee different from the FDF filename must be detected."
    Assert-True -Condition (-not [bool]$identityMismatch.canCommit) -Message "An identity mismatch must block import and cannot be overridden."
    Assert-Contains -Value (@($identityMismatch.validationErrors) -join " ") -ExpectedText "does not match" -Message "An identity mismatch must explain the problem."

    $unverifiedIdentity = New-Gc179ImportPreview -FdfContent $fixtureContent -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "completed-form.fdf" -Status "pending" -ManagerMessage ""
    $unverifiedIdentity = Complete-Gc179ImportPreview -Preview $unverifiedIdentity -EmployeeUser $targetEmployee -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -FileName "completed-form.fdf" -ConfirmIdentity:$false -SkipDuplicates:$true
    Assert-Equal -Expected "unverified" -Actual $unverifiedIdentity.identity.status -Message "A form with no identity header or recognizable filename must be unverified."
    Assert-True -Condition ([bool]$unverifiedIdentity.identity.requiresConfirmation) -Message "An unverified form must require explicit confirmation."
    Assert-True -Condition (-not [bool]$unverifiedIdentity.canCommit) -Message "An unconfirmed, unverified form must not be committable."

    $confirmedIdentity = New-Gc179ImportPreview -FdfContent $fixtureContent -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "completed-form.fdf" -Status "pending" -ManagerMessage ""
    $confirmedIdentity = Complete-Gc179ImportPreview -Preview $confirmedIdentity -EmployeeUser $targetEmployee -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -FileName "completed-form.fdf" -ConfirmIdentity:$true -SkipDuplicates:$true
    Assert-True -Condition ([bool]$confirmedIdentity.identity.confirmed) -Message "Explicit confirmation must authorize an otherwise unverified form."
    Assert-True -Condition ([bool]$confirmedIdentity.canCommit) -Message "A confirmed, unverified form with valid rows must be committable."

    $invalidCodeFdf = Set-FdfFieldValue -Content $fixtureContent -FieldName "OvertimeCode.0" -Value "999"
    $invalidCodePreview = New-Gc179ImportPreview -FdfContent $invalidCodeFdf -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "gc179-000100001-2026-05.fdf" -Status "pending" -ManagerMessage ""
    $invalidCodePreview = Complete-Gc179ImportPreview -Preview $invalidCodePreview -EmployeeUser $targetEmployee -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -FileName "gc179-000100001-2026-05.fdf" -SkipDuplicates:$true
    $invalidCodeEntry = @($invalidCodePreview.entries | Where-Object { [int]$_.sourceRow -eq 0 })[0]
    Assert-True -Condition (-not [bool]$invalidCodeEntry.canImport) -Message "A row with an unknown overtime code must not be importable."
    Assert-Contains -Value (@($invalidCodeEntry.validationErrors) -join " ") -ExpectedText "invalid overtime code '999'" -Message "An invalid overtime code must be reported during preview."
    Assert-Equal -Expected 1 -Actual $invalidCodePreview.counts.errors -Message "The invalid-code row must be included in the error count."
    Assert-Throws -Action {
        Get-Gc179SelectedImportEntries -Preview $invalidCodePreview -SelectedSourceRows @(0) | Out-Null
    } -MessagePattern "cannot be imported" -Message "Commit selection must recheck invalid preview rows."

    $selectedFirstEntry = @(Get-Gc179SelectedImportEntries -Preview $validatedPreview -SelectedSourceRows @(0))
    Assert-Equal -Expected 1 -Actual $selectedFirstEntry.Count -Message "Selected-row filtering returned the wrong number of rows."
    $selectedPreview = [PSCustomObject]@{ entries = $selectedFirstEntry }
    $sourceHash = Get-Gc179ImportSha256 -Value $fixtureContent
    $script:RoutePayload = [PSCustomObject]@{
        employeeCode      = "000100001"
        projectCode       = "TEST"
        fdfContent        = $fixtureContent
        fileName          = "gc179-000100001-2026-05.fdf"
        status            = "pending"
        managerMessage    = "Validated fixture"
        confirmIdentity   = $false
        selectedSourceRows = @(0)
    }
    $commitRoute = Invoke-Gc179ImportRouteForTest -Path "/employee/gc179-import/commit" -Enabled:$true
    Assert-Equal -Expected 200 -Actual $commitRoute.StatusCode -Message "The commit route rejected a selected valid row."
    $importResult = $commitRoute.Body
    $batchId = [string]$importResult.batchId
    Assert-Equal -Expected 1 -Actual $importResult.importedCount -Message "The selected GC179 row was not imported."
    Assert-True -Condition ($batchId -match "^gc179-[0-9a-f]{32}$") -Message "The import route did not return a valid batch identifier."
    Assert-Equal -Expected 1 -Actual $script:ImportWriteCount -Message "The import must write the employee file once."
    Assert-Equal -Expected 1 -Actual $script:ImportPublishCount -Message "The import must publish one employee change."
    Assert-Equal -Expected 1 -Actual $script:ImportHistoryCountAtPublication[0] -Message "The import published before its history append completed."
    Assert-Equal -Expected $false -Actual $script:ImportHistoryPublishFlags[0] -Message "The import history append duplicated the employee publication."

    $storedEntries = @(Read-JsonArrayFile -Path $script:ImportDataFile)
    Assert-Equal -Expected 1 -Actual $storedEntries.Count -Message "The disposable employee file contains the wrong number of imported rows."
    $storedEntry = $storedEntries[0]
    Assert-Equal -Expected $batchId -Actual $storedEntry.gc179ImportBatchId -Message "Stored provenance lost the import batch identifier."
    Assert-Equal -Expected $sourceHash -Actual $storedEntry.gc179SourceHash -Message "Stored provenance lost the source-file hash."
    Assert-Equal -Expected "manager" -Actual $storedEntry.gc179ImportedBy -Message "Stored provenance lost the importing administrator."
    Assert-Equal -Expected "gc179-000100001-2026-05.fdf" -Actual $storedEntry.gc179SourceFile -Message "Stored provenance lost the safe source filename."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$storedEntry.gc179ImportFingerprint)) -Message "Stored GC179 entries need a fingerprint for safe undo."

    $duplicatePreview = New-Gc179ImportPreview -FdfContent $fixtureContent -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "gc179-000100001-2026-05.fdf" -Status "pending" -ManagerMessage "Validated fixture"
    $duplicatePreview = Complete-Gc179ImportPreview -Preview $duplicatePreview -EmployeeUser $targetEmployee -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -FileName "gc179-000100001-2026-05.fdf" -SkipDuplicates:$true
    $duplicateEntry = @($duplicatePreview.entries | Where-Object { [int]$_.sourceRow -eq 0 })[0]
    Assert-Equal -Expected "exact" -Actual $duplicateEntry.duplicateStatus -Message "An exact existing GC179 row must be recognized as an exact duplicate."
    Assert-True -Condition (-not [bool]$duplicateEntry.canImport) -Message "An exact duplicate must be skipped by default."
    Assert-Equal -Expected 1 -Actual $duplicatePreview.counts.duplicates -Message "Validated preview returned the wrong duplicate count."

    $writeCountBeforeDuplicate = $script:ImportWriteCount
    $publishCountBeforeDuplicate = $script:ImportPublishCount
    $duplicateCommitResult = Import-Gc179PreviewEntries -Preview ([PSCustomObject]@{ entries = @($duplicatePreview.entries | Where-Object { [int]$_.sourceRow -eq 0 }) }) -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -SourceFile "fixture.fdf" -SourceHash $sourceHash -ImportedBy "manager" -BatchId "gc179-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" -SkipDuplicates:$true
    Assert-Equal -Expected 0 -Actual $duplicateCommitResult.importedCount -Message "An exact duplicate must not be imported twice."
    Assert-Equal -Expected 1 -Actual $duplicateCommitResult.skippedDuplicateCount -Message "An exact duplicate must be reported as skipped."
    Assert-Equal -Expected $writeCountBeforeDuplicate -Actual $script:ImportWriteCount -Message "A duplicate-only commit must not rewrite the network employee file."
    Assert-Equal -Expected $publishCountBeforeDuplicate -Actual $script:ImportPublishCount -Message "A duplicate-only commit must not publish a false data change."

    $conflictPreview = New-Gc179ImportPreview -FdfContent $fixtureContent -EmployeeCode "000100001" -ProjectCode "TEST" -FileName "gc179-000100001-2026-05.fdf" -Status "pending" -ManagerMessage "Validated fixture"
    @($conflictPreview.entries | Where-Object { [int]$_.sourceRow -eq 0 })[0].overtime = "02:00:00"
    $conflictPreview = Complete-Gc179ImportPreview -Preview $conflictPreview -EmployeeUser $targetEmployee -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -FileName "gc179-000100001-2026-05.fdf" -SkipDuplicates:$true
    $conflictEntry = @($conflictPreview.entries | Where-Object { [int]$_.sourceRow -eq 0 })[0]
    Assert-Equal -Expected "conflict" -Actual $conflictEntry.duplicateStatus -Message "A same-shift row with a different duration must be a conflict, not an exact duplicate."
    Assert-True -Condition (-not [bool]$conflictEntry.canImport) -Message "A conflicting same-shift row must be blocked."
    Assert-Contains -Value (@($conflictEntry.validationErrors) -join " ") -ExpectedText "duration or GC179 rate components differ" -Message "A conflicting shift must explain the differing duration."

    $script:RoutePayload = [PSCustomObject]@{ employeeCode = "000100001"; batchId = $batchId }
    $undoRoute = Invoke-Gc179ImportRouteForTest -Path "/employee/gc179-import/undo" -Enabled:$true
    Assert-Equal -Expected 200 -Actual $undoRoute.StatusCode -Message "The undo route rejected a fresh, unchanged import batch."
    $undoResult = $undoRoute.Body
    Assert-Equal -Expected 1 -Actual $undoResult.undoneCount -Message "Undo did not remove the imported batch row."
    Assert-Equal -Expected $batchId -Actual $undoResult.batchId -Message "Undo returned the wrong batch identifier."
    Assert-Equal -Expected 0 -Actual @(Read-JsonArrayFile -Path $script:ImportDataFile).Count -Message "Undo left an imported row in the employee file."
    Assert-Equal -Expected 2 -Actual $script:ImportWriteCount -Message "Import and undo should each write once."
    Assert-Equal -Expected 2 -Actual $script:ImportPublishCount -Message "Import and undo should each publish once."
    Assert-Equal -Expected 2 -Actual $script:ImportHistoryCountAtPublication[1] -Message "The undo published before its history append completed."
    Assert-Equal -Expected $false -Actual $script:ImportHistoryPublishFlags[1] -Message "The undo history append duplicated the employee publication."

    $undoUser = [PSCustomObject]@{ username = "manager" }
    $changedBatchId = "gc179-cccccccccccccccccccccccccccccccc"
    $changedImportResult = Import-Gc179PreviewEntries -Preview $selectedPreview -EmployeeCode "000100001" -EmployeeName "Fixture Employee" -SourceFile "gc179-000100001-2026-05.fdf" -SourceHash $sourceHash -ImportedBy "manager" -BatchId $changedBatchId -SkipDuplicates:$true
    Assert-Equal -Expected 1 -Actual $changedImportResult.importedCount -Message "The undo safety scenario could not recreate its imported row."
    $changedEntries = @(Read-JsonArrayFile -Path $script:ImportDataFile)
    $changedEntries[0].message = "Edited after import"
    Write-JsonAtomic -Path $script:ImportDataFile -Value $changedEntries -Depth 10
    Assert-Throws -Action {
        Undo-Gc179ImportBatch -EmployeeCode "000100001" -BatchId $changedBatchId -CurrentUser $undoUser | Out-Null
    } -MessagePattern "changed after import" -Message "Undo must not delete a GC179 entry that someone edited after import."
    Assert-Equal -Expected 1 -Actual @(Read-JsonArrayFile -Path $script:ImportDataFile).Count -Message "A refused undo must preserve the changed employee entry."
}
finally {
    if (Test-Path -LiteralPath $importTestFolder) {
        Remove-Item -LiteralPath $importTestFolder -Recurse -Force
    }
}

Assert-Equal -Expected $fixtureExpectedSha256 -Actual ((Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToUpperInvariant()) -Message "The regression test must never modify the real GC179 example."
Assert-Equal -Expected $templateExpectedSha256 -Actual ((Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToUpperInvariant()) -Message "The regression test must never modify the original GC179 PDF."
Assert-Equal -Expected $generatedExampleExpectedSha256 -Actual ((Get-FileHash -LiteralPath $generatedExamplePath -Algorithm SHA256).Hash.ToUpperInvariant()) -Message "The regression test must never modify the root GC179 generation example."

Write-Host "GC179 import regression and integration tests passed."
