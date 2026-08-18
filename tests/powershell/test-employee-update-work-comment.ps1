$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Contains {
    param([string]$Value, [string]$ExpectedText, [string]$Message)
    if ([string]$Value -notlike "*$ExpectedText*") {
        throw "$Message Expected '$Value' to contain '$ExpectedText'."
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-update-work-comment-{0}" -f ([Guid]::NewGuid().ToString("N")))
$sharedFolder = $tempFolder
$lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"

$script:RequestPayload = $null
$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:PublishCount = 0
$script:HistoryMessage = ""
$currentUser = [PSCustomObject]@{
    username = "manager"
    displayName = "Test Manager"
    role = "super-admin"
}

function Read-JsonRequestBody {
    param($Request)
    return $script:RequestPayload
}

function Test-CurrentUserMatchesEmployeeCode {
    param($CurrentUser, [string]$EmployeeCode)
    return $false
}

function Test-CurrentUserCanManageEntry {
    param($CurrentUser, $Entry)
    return $true
}

function Test-CurrentUserCanModifyProjectCode {
    param($CurrentUser, [string]$ProjectCode)
    return $true
}

function Test-CurrentUserCanModifyActiveProjectCodeFromDisk {
    param($CurrentUser, [string]$ProjectCode)
    return $true
}

function Test-CurrentUserCanApproveEmployeeRole {
    param($CurrentUser, [string]$EmployeeRole)
    return $true
}

function Get-EmployeeRoleByCode {
    param([string]$EmployeeCode)
    return "employee"
}

function Get-ActiveProjects { return @([PSCustomObject]@{ projectCode = "P001" }) }
function Get-OvertimeCodes { return @() }
function Get-PaymentOptions { return @([PSCustomObject]@{ code = "cash" }) }
function Get-ReasonCodes { return @() }

function Test-OptionCode {
    param($Options, [string]$Code, [bool]$AllowBlank)
    return $true
}

function Acquire-ProjectReferenceLock {
    return (Acquire-ResourceLock -ResourcePath (Join-Path -Path $sharedFolder -ChildPath ".project-references"))
}

function Test-ActiveProjectCodeFromDisk {
    param([string]$ProjectCode)
    return $true
}

function Get-EmployeeName {
    param([string]$EmployeeCode)
    return "Test Employee"
}

function Format-TimeForHistory {
    param([string]$TimeText)
    return $TimeText
}

function logHistory {
    param(
        [string]$Action,
        [string]$Message,
        [string]$EmployeeName,
        [bool]$PublishChange = $true
    )
    $script:HistoryMessage = $Message
}

function Invoke-PostCommitActionSafely {
    param([string]$Description, [scriptblock]$Action)
    try { & $Action | Out-Null; return "" } catch { return "$Description`: $($_.Exception.Message)" }
}

function Publish-DataChange {
    param(
        [string]$Category = "data",
        [string]$Resource = "shared",
        [string[]]$AffectedEmployeeCodes = @()
    )
    $script:PublishCount++
}

function respondWithSuccess {
    param($Response, [string]$Message)
    $script:CapturedStatusCode = 200
    $script:CapturedMessage = $Message
}

function respondWithError {
    param($Response, [int]$StatusCode, [string]$Message)
    $script:CapturedStatusCode = $StatusCode
    $script:CapturedMessage = $Message
}

function New-CompletedOvertimeEntry {
    param(
        [Parameter(Mandatory = $true)][string]$EntryId,
        [switch]$IncludeWorkComment,
        [string]$WorkComment = ""
    )

    $entry = [PSCustomObject]@{
        entryId       = $EntryId
        entryType     = "overtime"
        name          = "Test Employee"
        date          = "2026-08-01"
        punchIn       = "08:00:00"
        exactPunchIn  = "08:02:00"
        punchOut      = "09:00:00"
        exactPunchOut = "09:03:00"
        overtime      = "01:00:00"
        status        = "pending"
        message       = ""
        projectCode   = "P001"
        overtimeCode  = ""
        paymentOption = "cash"
        reasonCode    = ""
    }
    if ($IncludeWorkComment) {
        $entry | Add-Member -NotePropertyName "workComment" -NotePropertyValue $WorkComment -Force
    }
    return $entry
}

function New-CompletedDiverseEntry {
    param([Parameter(Mandatory = $true)][string]$EntryId)

    return [PSCustomObject]@{
        entryId        = $EntryId
        entryType      = "diverse"
        name           = "Test Employee"
        date           = "2026-08-01"
        punchIn        = "08:00:00"
        exactPunchIn   = "08:02:00"
        punchOut       = "09:00:00"
        exactPunchOut  = "09:03:00"
        overtime       = "01:00:00"
        status         = "pending"
        message        = ""
        projectCode    = ""
        overtimeCode   = ""
        paymentOption  = ""
        reasonCode     = ""
        diverseReason  = "Support"
        diverseSummary = "Existing summary."
    }
}

function Invoke-EmployeeUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EntryId,
        [ValidateSet("overtime", "diverse")][string]$EntryType = "overtime",
        [switch]$IncludeWorkComment,
        [string]$WorkComment = "",
        [switch]$IncludeDiverseSummary,
        [string]$DiverseSummary = ""
    )

    $payloadProperties = [ordered]@{
        entryId        = $EntryId
        entryType      = $EntryType
        date           = "2026-08-01"
        originalPunchIn = "08:00:00"
        newPunchIn     = "08:02:00"
        punchOut       = "09:03:00"
        message        = "Reviewed by the manager."
    }
    if ($IncludeWorkComment) {
        $payloadProperties.workComment = $WorkComment
    }
    if ($IncludeDiverseSummary) {
        $payloadProperties.diverseSummary = $DiverseSummary
    }

    $script:RequestPayload = [PSCustomObject]$payloadProperties
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    $script:PublishCount = 0
    $script:HistoryMessage = ""

    $request = [PSCustomObject]@{
        HttpMethod = "PUT"
        Url = [PSCustomObject]@{ AbsolutePath = "/employee/$EmployeeCode" }
    }
    $response = [PSCustomObject]@{}

    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/update.routes.ps1")
    }
}

try {
    New-Item -ItemType Directory -Path $sharedFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $lockFolder -Force | Out-Null
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/services/EntryService.ps1")

    $legacyEmployeeCode = "000000301"
    $legacyEntryId = "legacy-commentless-entry"
    $legacyPath = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $legacyEmployeeCode)
    Write-JsonArrayAtomic -Path $legacyPath -Items @((New-CompletedOvertimeEntry -EntryId $legacyEntryId)) -Depth 8

    Invoke-EmployeeUpdate -EmployeeCode $legacyEmployeeCode -EntryId $legacyEntryId
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Editing a legacy completed entry without a work comment failed."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Legacy entry update did not publish exactly once."
    $legacySaved = @(Read-JsonArrayFile -Path $legacyPath)[0]
    Assert-Equal -Expected $false -Actual ($legacySaved.PSObject.Properties.Name -contains "workComment") -Message "Legacy update unexpectedly added a workComment field."

    Invoke-EmployeeUpdate -EmployeeCode $legacyEmployeeCode -EntryId $legacyEntryId -IncludeWorkComment -WorkComment "   "
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "An unchanged blank legacy comment should not block manager edits."
    $legacyBlankSaved = @(Read-JsonArrayFile -Path $legacyPath)[0]
    Assert-Equal -Expected $false -Actual ($legacyBlankSaved.PSObject.Properties.Name -contains "workComment") -Message "Unchanged blank legacy comment unexpectedly changed the data shape."

    Invoke-EmployeeUpdate -EmployeeCode $legacyEmployeeCode -EntryId $legacyEntryId -IncludeWorkComment -WorkComment ("x" * 1001)
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Manager edits should reject work comments over 1000 characters."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "1000 characters" -Message "Oversized manager-comment validation returned the wrong explanation."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "An oversized manager comment unexpectedly published a data change."

    Invoke-EmployeeUpdate -EmployeeCode $legacyEmployeeCode -EntryId $legacyEntryId -IncludeWorkComment -WorkComment ("b" * 1000)
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A manager work-comment edit at the 1000-character limit should be accepted."
    $boundarySaved = @(Read-JsonArrayFile -Path $legacyPath)[0]
    Assert-Equal -Expected 1000 -Actual ([string]$boundarySaved.workComment).Length -Message "The manager work-comment boundary value was not stored intact."

    Invoke-EmployeeUpdate -EmployeeCode $legacyEmployeeCode -EntryId $legacyEntryId -IncludeWorkComment -WorkComment "  Validated expense claim totals.  "
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Adding a work comment through manager edit failed."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "Work comment updated" -Message "Update response did not identify the work-comment change."
    Assert-Contains -Value $script:HistoryMessage -ExpectedText "Work comment updated" -Message "History did not identify the work-comment change."
    $commentedSaved = @(Read-JsonArrayFile -Path $legacyPath)[0]
    Assert-Equal -Expected "Validated expense claim totals." -Actual $commentedSaved.workComment -Message "Manager edit did not trim and persist workComment."

    Invoke-EmployeeUpdate -EmployeeCode $legacyEmployeeCode -EntryId $legacyEntryId -IncludeWorkComment -WorkComment "   "
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Clearing an existing comment from a completed entry should be rejected."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "cannot be cleared" -Message "Comment-clearing validation returned the wrong explanation."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Rejected comment clearing unexpectedly published a data change."
    $afterRejectedClear = @(Read-JsonArrayFile -Path $legacyPath)[0]
    Assert-Equal -Expected "Validated expense claim totals." -Actual $afterRejectedClear.workComment -Message "Rejected comment clearing modified the stored comment."

    $diverseEmployeeCode = "000000302"
    $diverseEntryId = "diverse-summary-entry"
    $diversePath = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $diverseEmployeeCode)
    Write-JsonArrayAtomic -Path $diversePath -Items @((New-CompletedDiverseEntry -EntryId $diverseEntryId)) -Depth 8

    Invoke-EmployeeUpdate -EmployeeCode $diverseEmployeeCode -EntryId $diverseEntryId -EntryType "diverse" -IncludeDiverseSummary -DiverseSummary ("d" * 1001)
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Manager edits should reject Diverse summaries over 1000 characters."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "1000 characters" -Message "Oversized Diverse-summary edits returned the wrong explanation."

    Invoke-EmployeeUpdate -EmployeeCode $diverseEmployeeCode -EntryId $diverseEntryId -EntryType "diverse" -IncludeDiverseSummary -DiverseSummary ("d" * 1000)
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A Diverse summary at the 1000-character limit should be accepted."
    $diverseBoundarySaved = @(Read-JsonArrayFile -Path $diversePath)[0]
    Assert-Equal -Expected 1000 -Actual ([string]$diverseBoundarySaved.diverseSummary).Length -Message "The Diverse-summary boundary value was not stored intact."

    Write-Host "Employee update work-comment regression tests passed."
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
