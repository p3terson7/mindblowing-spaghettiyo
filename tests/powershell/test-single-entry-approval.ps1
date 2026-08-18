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

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-single-entry-approval-{0}" -f ([Guid]::NewGuid().ToString("N")))
$script:sharedFolder = $tempFolder
$script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
$script:currentUser = [PSCustomObject]@{
    username    = "manager"
    displayName = "Test Manager"
    role        = "super-admin"
}
$script:RequestPayload = $null
$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:PublishCount = 0

function Read-JsonRequestBody {
    param($Request)
    return $script:RequestPayload
}

function Test-CurrentUserCanManageEntry {
    param($CurrentUser, $Entry)
    return $true
}

function Test-CurrentUserCanApproveEmployeeRole {
    param($CurrentUser, [string]$EmployeeRole)
    return $true
}

function Get-AuthenticatedUserFromRequest {
    param($Request)
    return $script:currentUser
}

function Test-CurrentUserManager {
    param($CurrentUser)
    return $true
}

function Test-CurrentUserSuperAdmin {
    param($CurrentUser)
    return $true
}

function Test-CurrentUserMatchesEmployeeCode {
    param($CurrentUser, [string]$EmployeeCode)
    return $false
}

function Get-EmployeeRoleByCode {
    param([string]$EmployeeCode)
    return "employee"
}

function Get-EmployeeUserByCode {
    param([string]$EmployeeCode)
    return [PSCustomObject]@{
        username     = $EmployeeCode
        employeeCode = $EmployeeCode
        displayName  = "Single Entry Employee"
        role         = "employee"
    }
}

function Get-EffectiveUserRole {
    param($UserRecord)
    return "employee"
}

function Get-EmployeeName {
    param([string]$EmployeeCode)
    return "Single Entry Employee"
}

function Ensure-EmployeeDataFile {
    param([string]$EmployeeCode)
    return (Join-Path -Path $script:sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode))
}

function Get-EmployeeDataFilePath {
    param([string]$EmployeeCode)
    return (Join-Path -Path $script:sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode))
}

function Get-CachedEmployeeEntriesForFile {
    param([string]$DataFile)
    return [PSCustomObject]@{
        entryId     = "api-single"
        date        = "2026-07-17"
        punchIn     = "12:45:00"
        punchOut    = "15:15:00"
        status      = "pending"
        projectCode = "P001"
    }
}

function Get-ProjectModificationAccessModelForCurrentUser {
    param($CurrentUser)
    return [PSCustomObject]@{ ProjectCodeSet = @{} }
}

function New-EmployeeEntryProjectionForAccessModel {
    param(
        [string]$EmployeeCode,
        [string]$EmployeeName,
        $Entry,
        $ModifyProjectCodeSet,
        [string]$EmployeeRole,
        [bool]$IsSuperAdmin,
        [bool]$CanApproveEmployeeRole
    )
    return $Entry
}

function Get-ApprovalsEntriesModel {
    param($CurrentUser)
    return [PSCustomObject]@{
        entryId      = "approval-api-single"
        employeeCode = "000000203"
        status       = "pending"
    }
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

function Invoke-SingleEntryApproval {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][ValidateSet("approved", "rejected")][string]$Status,
        [bool]$IncludeEntryId = $true
    )

    $dataFile = Join-Path -Path $script:sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode)
    $entry = [PSCustomObject]@{
        entryId      = if ($IncludeEntryId) { "single-$Status" } else { "" }
        entryType    = "overtime"
        name         = "Single Entry Employee"
        date         = "2026-07-17"
        punchIn      = "12:45:00"
        exactPunchIn = "12:49:00"
        punchOut     = "15:15:00"
        exactPunchOut = "15:08:00"
        overtime     = "02:30:00"
        status       = "pending"
        message      = ""
        projectCode  = "P001"
    }

    # Reproduce files written by older releases: exactly one entry was stored
    # as a root JSON object rather than as a one-element JSON array.
    [System.IO.File]::WriteAllText(
        $dataFile,
        (ConvertTo-Json -InputObject $entry -Depth 8),
        (New-Object System.Text.UTF8Encoding($false))
    )

    $managerMessage = if ($Status -eq "rejected") { "Please correct this entry." } else { "" }
    $script:RequestPayload = [PSCustomObject]@{
        entryId = if ($IncludeEntryId) { [string]$entry.entryId } else { "" }
        date    = [string]$entry.date
        punchIn = [string]$entry.punchIn
        status  = $Status
        message = $managerMessage
    }
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    $script:PublishCount = 0

    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url        = [PSCustomObject]@{ AbsolutePath = "/employee/approval/$EmployeeCode" }
    }
    $response = [PSCustomObject]@{}

    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/approval.routes.ps1")
    }

    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A legacy one-entry file could not be $Status. Response: $($script:CapturedMessage)"
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "The $Status mutation did not publish exactly once."

    $savedRaw = [System.IO.File]::ReadAllText($dataFile).TrimStart()
    Assert-Equal -Expected "[" -Actual ([string]$savedRaw[0]) -Message "The $Status mutation did not migrate the root JSON value to an array."

    $savedEntries = @(Read-JsonArrayFile -Path $dataFile)
    Assert-Equal -Expected 1 -Actual $savedEntries.Count -Message "The $Status mutation changed the number of entries."
    Assert-Equal -Expected $Status -Actual $savedEntries[0].status -Message "The single entry received the wrong status."
    Assert-Equal -Expected $managerMessage -Actual ([string]$savedEntries[0].message) -Message "The single entry received the wrong manager message."
}

try {
    New-Item -ItemType Directory -Path $script:sharedFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $script:lockFolder -Force | Out-Null

    . (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/services/EntryService.ps1")

    $scalarEntry = [PSCustomObject]@{
        Count    = 0
        entryId  = "scalar-only"
        date     = "2026-07-17"
        punchIn  = "12:45:00"
    }
    Assert-Equal -Expected 0 -Actual (Find-EntryIndex -Entries $scalarEntry -EntryId "scalar-only" -Date "" -PunchIn "") -Message "Scalar entry lookup was not normalized."
    $scalarLookup = New-EntryIndexLookup -Entries $scalarEntry
    Assert-Equal -Expected 0 -Actual (Find-EntryIndexFromLookup -Lookup $scalarLookup -EntryId "scalar-only" -Date "" -PunchIn "") -Message "Scalar indexed lookup was not normalized."

    $oneItemArrayPath = Join-Path -Path $script:sharedFolder -ChildPath "one-item-array.json"
    Write-JsonAtomic -Path $oneItemArrayPath -Value @([PSCustomObject]@{ entryId = "only" }) -Depth 4
    $oneItemRaw = [System.IO.File]::ReadAllText($oneItemArrayPath).TrimStart()
    Assert-Equal -Expected "[" -Actual ([string]$oneItemRaw[0]) -Message "Write-JsonAtomic collapsed a one-item array."

    Invoke-SingleEntryApproval -EmployeeCode "000000201" -Status "approved" -IncludeEntryId $true
    Invoke-SingleEntryApproval -EmployeeCode "000000202" -Status "rejected" -IncludeEntryId $false

    $request = [PSCustomObject]@{
        HttpMethod = "GET"
        Url        = [PSCustomObject]@{
            AbsolutePath = "/employee/000000203"
            Query        = ""
        }
    }
    $response = [PSCustomObject]@{}
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/get.routes.ps1")
    }
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "The one-entry employee API request failed."
    Assert-Equal -Expected "[" -Actual ([string]$script:CapturedMessage.TrimStart()[0]) -Message "The employee API collapsed a one-entry response."

    $request = [PSCustomObject]@{
        HttpMethod = "GET"
        Url        = [PSCustomObject]@{
            AbsolutePath = "/approvals/entries"
            Query        = ""
        }
    }
    $response = [PSCustomObject]@{}
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/dashboard.routes.ps1")
    }
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "The one-entry approvals API request failed."
    Assert-Equal -Expected "[" -Actual ([string]$script:CapturedMessage.TrimStart()[0]) -Message "The approvals API collapsed a one-entry response."

    Write-Host "Single-entry approval regression tests passed."
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
