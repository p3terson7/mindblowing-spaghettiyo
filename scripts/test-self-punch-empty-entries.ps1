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
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-self-punch-empty-{0}" -f ([Guid]::NewGuid().ToString("N")))
$sharedFolder = $tempFolder
$lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"

New-Item -ItemType Directory -Path $sharedFolder -Force | Out-Null
New-Item -ItemType Directory -Path $lockFolder -Force | Out-Null

. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")
. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/EntryService.ps1")

$script:CurrentUser = $null
$script:RequestPayload = $null
$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:PublishCount = 0
$script:PublishedCategory = ""
$script:PublishedResource = ""

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
    $script:PublishedCategory = $Category
    $script:PublishedResource = $Resource
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
    $script:PublishedCategory = ""
    $script:PublishedResource = ""
}

function Invoke-SelfPunchRoute {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][ValidateSet("in", "out")][string]$PunchType
    )

    Reset-ScenarioState
    $script:CurrentUser = [PSCustomObject]@{
        username = $EmployeeCode
        displayName = "Employee $EmployeeCode"
        role = "employee"
        employeeCode = $EmployeeCode
    }
    $script:RequestPayload = [PSCustomObject]@{
        type = $PunchType
        entryType = "overtime"
        projectCode = "P001"
        overtimeCode = ""
        paymentOption = "cash"
        reasonCode = ""
    }

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
    $emptyFileEmployeeCode = "000000101"
    $emptyFilePath = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $emptyFileEmployeeCode)
    Write-JsonAtomic -Path $emptyFilePath -Value @()

    Invoke-SelfPunchRoute -EmployeeCode $emptyFileEmployeeCode -PunchType "in"
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Punch-in against an empty employee file failed."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Successful first punch-in did not publish exactly one data change."
    Assert-Equal -Expected "employee" -Actual $script:PublishedCategory -Message "First punch-in published the wrong category."
    Assert-Equal -Expected $emptyFileEmployeeCode -Actual $script:PublishedResource -Message "First punch-in published the wrong employee resource."

    $storedEntries = @(Read-JsonArrayFile -Path $emptyFilePath)
    Assert-Equal -Expected 1 -Actual $storedEntries.Count -Message "First punch-in did not persist exactly one entry."
    Assert-Equal -Expected "P001" -Actual $storedEntries[0].projectCode -Message "First punch-in lost the selected project."
    Assert-Equal -Expected "pending" -Actual $storedEntries[0].status -Message "First punch-in stored the wrong status."
    Assert-Equal -Expected "" -Actual ([string]$storedEntries[0].punchOut) -Message "First punch-in unexpectedly stored a punch-out time."

    $missingFileEmployeeCode = "000000102"
    $missingFilePath = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $missingFileEmployeeCode)
    Invoke-SelfPunchRoute -EmployeeCode $missingFileEmployeeCode -PunchType "in"
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "First punch-in did not initialize a missing employee file."
    Assert-Equal -Expected 1 -Actual @(Read-JsonArrayFile -Path $missingFilePath).Count -Message "Initialized employee file did not contain the new punch."

    $emptyPunchOutEmployeeCode = "000000103"
    $emptyPunchOutPath = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $emptyPunchOutEmployeeCode)
    Write-JsonAtomic -Path $emptyPunchOutPath -Value @()
    Invoke-SelfPunchRoute -EmployeeCode $emptyPunchOutEmployeeCode -PunchType "out"
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Punch-out against an empty employee file should return a client error."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "No active punch-in record found" -Message "Empty punch-out returned the wrong explanation."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Rejected empty punch-out unexpectedly published a data change."

    Write-Host "Self punch empty-entry regression tests passed."
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
