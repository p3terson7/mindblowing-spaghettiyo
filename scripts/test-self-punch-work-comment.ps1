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
    param(
        [string]$Value,
        [string]$ExpectedText,
        [string]$Message
    )

    if ([string]$Value -notlike "*$ExpectedText*") {
        throw "$Message Expected '$Value' to contain '$ExpectedText'."
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Get-Item -Path $scriptRoot).Parent.FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-self-punch-comment-{0}" -f ([Guid]::NewGuid().ToString("N")))
$sharedFolder = $tempFolder
$lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"

New-Item -ItemType Directory -Path $sharedFolder -Force | Out-Null
New-Item -ItemType Directory -Path $lockFolder -Force | Out-Null

. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")
. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/EntryService.ps1")
. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/ReadModelService.ps1")

$script:CurrentUser = $null
$script:RequestPayload = $null
$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:PublishCount = 0

function Get-AuthenticatedUserFromRequest {
    param($Request)
    return $script:CurrentUser
}

function Read-JsonRequestBody {
    param($Request)
    return $script:RequestPayload
}

function Test-EmployeeCanPunchEntryType {
    param([string]$EmployeeCode, [string]$EntryType)
    return $true
}

function Get-ActiveProjects {
    return @([PSCustomObject]@{ projectCode = "P001" })
}

function Acquire-ProjectReferenceLock {
    return (Acquire-ResourceLock -ResourcePath (Join-Path -Path $sharedFolder -ChildPath ".project-references"))
}

function Test-ActiveProjectCodeFromDisk {
    param([string]$ProjectCode)
    return $ProjectCode -eq "P001"
}

function Get-OvertimeCodes { return @() }
function Get-PaymentOptions { return @([PSCustomObject]@{ code = "cash" }) }
function Get-ReasonCodes { return @() }

function Test-OptionCode {
    param($Options, [string]$Code, [bool]$AllowBlank)
    return $true
}

function Get-EmployeeName {
    param([string]$EmployeeCode)
    return "Employee $EmployeeCode"
}

function Get-NormalizedRoleName {
    param([string]$Role)
    return $Role
}

function Invoke-PostCommitActionSafely {
    param([string]$Description, [scriptblock]$Action)
    try { & $Action | Out-Null; return "" } catch { return "$Description`: $($_.Exception.Message)" }
}

function Ensure-EmployeeDataFile {
    param([string]$EmployeeCode)
    $path = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode)
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        Write-JsonArrayAtomic -Path $path -Items @()
    }
    return $path
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

function Reset-ScenarioState {
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    $script:PublishCount = 0
}

function Get-EmployeeDataPath {
    param([Parameter(Mandatory = $true)][string]$EmployeeCode)
    return (Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode))
}

function New-ActiveEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Date,
        [ValidateSet("overtime", "diverse")][string]$EntryType = "overtime"
    )

    return [PSCustomObject]@{
        entryId       = New-EntryIdentifier
        entryType     = $EntryType
        name          = "Test Employee"
        date          = $Date
        punchIn       = "00:00:00"
        exactPunchIn  = "00:00:00"
        punchOut      = $null
        overtime      = $null
        status        = "pending"
        message       = ""
        projectCode   = if ($EntryType -eq "overtime") { "P001" } else { "" }
        overtimeCode  = ""
        paymentOption = if ($EntryType -eq "overtime") { "cash" } else { "" }
        reasonCode    = ""
        diverseReason = if ($EntryType -eq "diverse") { "Support" } else { "" }
        diverseSummary = ""
    }
}

function Invoke-SelfPunchOutRoute {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [string]$WorkComment,
        [string]$DiverseSummary,
        [switch]$IncludeWorkComment,
        [switch]$IncludeDiverseSummary
    )

    Reset-ScenarioState
    $script:CurrentUser = [PSCustomObject]@{
        username = $EmployeeCode
        displayName = "Employee $EmployeeCode"
        role = "employee"
        employeeCode = $EmployeeCode
    }

    $payloadProperties = [ordered]@{ type = "out" }
    if ($IncludeWorkComment) {
        $payloadProperties.workComment = $WorkComment
    }
    if ($IncludeDiverseSummary) {
        $payloadProperties.diverseSummary = $DiverseSummary
    }
    $script:RequestPayload = [PSCustomObject]$payloadProperties

    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url = [PSCustomObject]@{ AbsolutePath = "/self/punch" }
    }
    $response = [PSCustomObject]@{}

    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/self.routes.ps1")
    }
}

try {
    $todayText = (Get-Date).ToString("yyyy-MM-dd")

    $missingCommentCode = "000000201"
    $missingCommentPath = Get-EmployeeDataPath -EmployeeCode $missingCommentCode
    Write-JsonArrayAtomic -Path $missingCommentPath -Items @((New-ActiveEntry -Date $todayText))

    Invoke-SelfPunchOutRoute -EmployeeCode $missingCommentCode
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Overtime punch-out without a work comment should be rejected."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "work comment is required" -Message "Missing-comment validation returned the wrong explanation."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Rejected overtime punch-out unexpectedly published a data change."
    $unchangedEntry = @(Read-JsonArrayFile -Path $missingCommentPath)[0]
    Assert-Equal -Expected "" -Actual ([string]$unchangedEntry.punchOut) -Message "Rejected overtime punch-out modified the entry."
    Assert-Equal -Expected $false -Actual ($unchangedEntry.PSObject.Properties.Name -contains "workComment") -Message "Rejected overtime punch-out added a workComment field."

    Invoke-SelfPunchOutRoute -EmployeeCode $missingCommentCode -IncludeWorkComment -WorkComment "   "
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Whitespace-only overtime work comment should be rejected."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Whitespace-only overtime comment unexpectedly published a data change."

    Invoke-SelfPunchOutRoute -EmployeeCode $missingCommentCode -IncludeWorkComment -WorkComment ("x" * 1001)
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "An overtime work comment over 1000 characters should be rejected."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "1000 characters" -Message "Oversized-comment validation returned the wrong explanation."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "An oversized overtime comment unexpectedly published a data change."

    Invoke-SelfPunchOutRoute -EmployeeCode $missingCommentCode -IncludeWorkComment -WorkComment "  Prepared the monthly reconciliation report.  "
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Overtime punch-out with a work comment failed."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Successful overtime punch-out did not publish exactly one data change."
    $completedEntry = @(Read-JsonArrayFile -Path $missingCommentPath)[0]
    Assert-Equal -Expected "Prepared the monthly reconciliation report." -Actual $completedEntry.workComment -Message "Overtime work comment was not trimmed and persisted."
    if ([string]::IsNullOrWhiteSpace([string]$completedEntry.punchOut)) {
        throw "Successful overtime punch-out did not store a punch-out time."
    }

    $normalizedLegacyEntry = Convert-ToNormalizedEntryObject -Entry ([PSCustomObject]@{
        entryType = "overtime"
        date = $todayText
        punchIn = "08:00:00"
    })
    Assert-Equal -Expected "" -Actual $normalizedLegacyEntry.workComment -Message "Legacy entry without workComment is not backward compatible."

    $projectedEntry = New-EmployeeEntryProjection -EmployeeCode $missingCommentCode -EmployeeName "Test Employee" -Entry $completedEntry
    Assert-Equal -Expected "Prepared the monthly reconciliation report." -Actual $projectedEntry.workComment -Message "Read-model projection omitted the overtime work comment."

    function Test-CurrentUserSuperAdmin {
        param($CurrentUser)
        return $false
    }

    function Get-ProjectAccessModelForCurrentUser {
        param($CurrentUser)
        return [PSCustomObject]@{
            ProjectCodes  = @("P001")
            ProjectCodeSet = @{ P001 = $true }
        }
    }

    function Get-FilteredEmployeeEntriesSnapshot {
        param([string]$StartDate, [string]$EndDate)
        return @([PSCustomObject]@{
            entryId       = "project-comment-entry"
            employeeCode  = $missingCommentCode
            employeeName  = "Test Employee"
            name          = "Test Employee"
            projectCode   = "P001"
            date          = $todayText
            punchIn       = "08:00:00"
            exactPunchIn  = "08:02:00"
            punchOut      = "09:00:00"
            exactPunchOut = "09:03:00"
            overtime      = "01:00:00"
            workComment   = "Prepared the monthly reconciliation report."
            diverseSummary = ""
        })
    }

    function Invoke-ReadModelCache {
        param([string]$Key, [scriptblock]$Factory)
        return (& $Factory)
    }

    $projectStats = Get-ProjectStatisticsOverview -CurrentUser ([PSCustomObject]@{ username = "manager" })
    $projectBreakdownEntry = @($projectStats["P001"].breakdown[$missingCommentCode].entries)[0]
    Assert-Equal -Expected "Prepared the monthly reconciliation report." -Actual $projectBreakdownEntry.workComment -Message "Project drill-down projection omitted the overtime work comment."
    Assert-Equal -Expected "" -Actual $projectBreakdownEntry.diverseSummary -Message "Project drill-down projection omitted the legacy Diverse summary field."

    $boundaryCode = "000000204"
    $boundaryPath = Get-EmployeeDataPath -EmployeeCode $boundaryCode
    Write-JsonArrayAtomic -Path $boundaryPath -Items @((New-ActiveEntry -Date $todayText))
    Invoke-SelfPunchOutRoute -EmployeeCode $boundaryCode -IncludeWorkComment -WorkComment ("b" * 1000)
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A work comment at the 1000-character limit should be accepted."
    $boundaryEntry = @(Read-JsonArrayFile -Path $boundaryPath)[0]
    Assert-Equal -Expected 1000 -Actual ([string]$boundaryEntry.workComment).Length -Message "The boundary-length work comment was not stored intact."

    $diverseCode = "000000202"
    $diversePath = Get-EmployeeDataPath -EmployeeCode $diverseCode
    Write-JsonArrayAtomic -Path $diversePath -Items @((New-ActiveEntry -Date $todayText -EntryType "diverse"))

    Invoke-SelfPunchOutRoute -EmployeeCode $diverseCode -IncludeWorkComment -WorkComment "This generic field must not replace Diverse compatibility."
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Diverse punch-out should continue requiring diverseSummary."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "work summary is required" -Message "Diverse validation contract changed unexpectedly."

    Invoke-SelfPunchOutRoute -EmployeeCode $diverseCode -IncludeDiverseSummary -DiverseSummary ("d" * 1001)
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "A Diverse work summary over 1000 characters should be rejected."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "1000 characters" -Message "Oversized Diverse-summary validation returned the wrong explanation."

    Invoke-SelfPunchOutRoute -EmployeeCode $diverseCode -IncludeDiverseSummary -DiverseSummary "  Helped with inventory.  "
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Diverse punch-out with its legacy summary failed."
    $completedDiverseEntry = @(Read-JsonArrayFile -Path $diversePath)[0]
    Assert-Equal -Expected "Helped with inventory." -Actual $completedDiverseEntry.diverseSummary -Message "Diverse summary was not preserved."
    Assert-Equal -Expected $false -Actual ($completedDiverseEntry.PSObject.Properties.Name -contains "workComment") -Message "Diverse punch-out unexpectedly replaced its legacy field."

    $previousDayCode = "000000203"
    $previousDayPath = Get-EmployeeDataPath -EmployeeCode $previousDayCode
    $previousDayText = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
    Write-JsonArrayAtomic -Path $previousDayPath -Items @((New-ActiveEntry -Date $previousDayText))

    Invoke-SelfPunchOutRoute -EmployeeCode $previousDayCode
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Previous-day overtime punch-out without a comment should be rejected."
    $rejectedPreviousDayEntry = @(Read-JsonArrayFile -Path $previousDayPath)[0]
    Assert-Equal -Expected $false -Actual (Test-EntryForgottenClockOut -Entry $rejectedPreviousDayEntry) -Message "Rejected previous-day punch-out was marked for review."

    Invoke-SelfPunchOutRoute -EmployeeCode $previousDayCode -IncludeWorkComment -WorkComment "  Completed the overnight deployment checks.  "
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Previous-day overtime punch-out with a comment failed."
    $reviewEntry = @(Read-JsonArrayFile -Path $previousDayPath)[0]
    Assert-Equal -Expected "Completed the overnight deployment checks." -Actual $reviewEntry.workComment -Message "Previous-day work comment was not persisted."
    Assert-Equal -Expected $true -Actual (Test-EntryForgottenClockOut -Entry $reviewEntry) -Message "Previous-day punch-out was not marked for supervisor review."
    Assert-Equal -Expected "" -Actual ([string]$reviewEntry.punchOut) -Message "Previous-day punch-out incorrectly completed the entry."

    Write-Host "Self punch work-comment regression tests passed."
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
