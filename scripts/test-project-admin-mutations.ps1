$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-project-mutations-{0}" -f ([Guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $tempFolder | Out-Null

$script:sharedFolder = $tempFolder
$script:projectsFile = Join-Path -Path $tempFolder -ChildPath "projects.json"
$script:currentUser = [PSCustomObject]@{ displayName = "Super Admin"; role = "superAdmin" }
$script:IsSuperAdmin = $true
$script:Projects = @()
$script:RequestPayload = $null
$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:WriteCount = 0
$script:PublishCount = 0
$script:PublishedResource = ""
$script:HistoryAction = ""
$script:HistoryMessage = ""

. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/ProjectMutationService.ps1")

function Test-CurrentUserSuperAdmin { param($CurrentUser) return [bool]$script:IsSuperAdmin }
function Read-JsonRequestBody { param($Request) return $script:RequestPayload }
function ConvertTo-CodeArray { param($Value) return @($Value) }
function Test-EmployeeCodeHasAdminRole { param([string]$EmployeeCode) return $true }
function Test-ProjectArchived {
    param($Project)
    return ($null -ne $Project -and $Project.PSObject.Properties.Name -contains "archived" -and [bool]$Project.archived)
}
function Acquire-ResourceLock { param([string]$ResourcePath) return [PSCustomObject]@{} }
function Release-ResourceLock { param($LockHandle) }
function Get-Projects { return @($script:Projects) }
function Write-JsonAtomic {
    param([string]$Path, $Value, [int]$Depth = 6)
    $script:WriteCount++
    $script:Projects = @($Value)
}
function logHistory {
    param([string]$Action, [string]$Message, [string]$EmployeeName)
    $script:HistoryAction = $Action
    $script:HistoryMessage = $Message
}
function Publish-DataChange {
    param([string]$Category, [string]$Resource, [string[]]$AffectedEmployeeCodes = @())
    $script:PublishCount++
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

function Reset-ProjectScenario {
    $script:IsSuperAdmin = $true
    $script:Projects = @(
        [PSCustomObject]@{
            projectCode = "P001"; projectName = "Original"; sector = ""; admins = @(); backupAdmins = @(); archived = $false
        }
    )
    $script:RequestPayload = $null
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    $script:WriteCount = 0
    $script:PublishCount = 0
    $script:PublishedResource = ""
    $script:HistoryAction = ""
    $script:HistoryMessage = ""
    Get-ChildItem -LiteralPath $tempFolder -Filter "*_data.json" -File -ErrorAction SilentlyContinue | Remove-Item -Force
}

function Set-TestEmployeeEntries {
    param(
        [string]$EmployeeCode,
        $Entries
    )

    $path = Join-Path -Path $tempFolder -ChildPath ("{0}_data.json" -f $EmployeeCode)
    [System.IO.File]::WriteAllText($path, ($Entries | ConvertTo-Json -Depth 8))
}

function Invoke-ProjectUpdateRoute {
    param([string]$OriginalCode = "P001")

    $request = [PSCustomObject]@{
        HttpMethod = "PUT"
        Url = [PSCustomObject]@{ AbsolutePath = "/projects/$OriginalCode" }
    }
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/projects/update.routes.ps1")
    }
}

function Invoke-ProjectAddRoute {
    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url = [PSCustomObject]@{ AbsolutePath = "/projects" }
    }
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/projects/add.routes.ps1")
    }
}

function Invoke-ProjectDeleteRoute {
    param(
        [string]$ProjectCode = "P001",
        [bool]$Permanent = $false
    )

    $queryString = New-Object System.Collections.Specialized.NameValueCollection
    if ($Permanent) {
        $queryString.Add("permanent", "true")
    }
    $request = [PSCustomObject]@{
        HttpMethod = "DELETE"
        Url = [PSCustomObject]@{ AbsolutePath = "/projects/$ProjectCode" }
        QueryString = $queryString
    }
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/projects/delete.routes.ps1")
    }
}

try {
    Assert-True -Condition (Test-ProjectCodeFormat -ProjectCode "OPS-410") -Message "Expected a normal dossier number to be valid."
    Assert-True -Condition (-not (Test-ProjectCodeFormat -ProjectCode "OPS/410")) -Message "A slash must not be allowed in a dossier number."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P002"; sector = "Test"; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A project without a name should be created."
    Assert-Equal -Expected "" -Actual $script:Projects[1].projectName -Message "An omitted project name should be stored as an empty string."
    Assert-Equal -Expected "P002" -Actual $script:PublishedResource -Message "The nameless project code was not published."
    Assert-Equal -Expected "Created a project with code <strong>P002</strong>." -Actual $script:HistoryMessage -Message "A nameless project used an unclear history message."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P003"; projectName = "   "; sector = ""; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A whitespace-only optional name should be accepted."
    Assert-Equal -Expected "" -Actual $script:Projects[1].projectName -Message "A whitespace-only project name should be normalized."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "BAD/CODE"; projectName = ""; sector = ""; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "An invalid dossier number should still be rejected when the name is blank."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Invalid project creation wrote project data."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P004"; projectName = ("N" * 201); sector = ""; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "An overlong optional project name should be rejected."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Overlong project creation wrote project data."

    Reset-ProjectScenario
    Set-TestEmployeeEntries -EmployeeCode "000000001" -Entries @(
        [PSCustomObject]@{ entryId = "one"; projectCode = "P001" },
        [PSCustomObject]@{ entryId = "two"; projectCode = "P001" },
        [PSCustomObject]@{ entryId = "three"; projectCode = "OTHER" }
    )
    $referenceSummary = Get-ProjectEntryReferenceSummary -ProjectCode "P001"
    Assert-Equal -Expected 2 -Actual $referenceSummary.referenceCount -Message "Project reference scan returned the wrong count."
    Assert-Equal -Expected "000000001" -Actual $referenceSummary.employeeCodes[0] -Message "Project reference scan returned the wrong employee."

    [System.IO.File]::WriteAllText((Join-Path -Path $tempFolder -ChildPath "000000002_data.json"), "{ broken json")
    $corruptDataRejected = $false
    try {
        Get-ProjectEntryReferenceSummary -ProjectCode "P001" | Out-Null
    }
    catch {
        $corruptDataRejected = $_.Exception.Message -like "*not valid JSON*"
    }
    Assert-True -Condition $corruptDataRejected -Message "Project mutations must stop when an employee data file is corrupt."
    Remove-Item -LiteralPath (Join-Path -Path $tempFolder -ChildPath "000000002_data.json") -Force

    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P010"; projectName = "Renamed"; sector = ""; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 409 -Actual $script:CapturedStatusCode -Message "A referenced dossier number rename must be rejected."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Rejected dossier number rename wrote project data."

    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P001"; projectName = "New name"; sector = "Sector"; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A name-only project update should succeed even with entries."
    Assert-Equal -Expected "New name" -Actual $script:Projects[0].projectName -Message "Project name was not updated."

    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P001"; projectName = ""; sector = "Sector"; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "An existing project name should be clearable."
    Assert-Equal -Expected "" -Actual $script:Projects[0].projectName -Message "The project name was not cleared."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P010"; projectName = "Renamed"; sector = ""; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "An unused dossier number rename should succeed."
    Assert-Equal -Expected "P010" -Actual $script:Projects[0].projectCode -Message "The unused dossier number was not updated."
    Assert-Equal -Expected "P010" -Actual $script:PublishedResource -Message "The renamed dossier number was not published."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "p001"; projectName = "Case update"; sector = ""; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Changing only the dossier number casing should not be treated as a duplicate."
    Assert-Equal -Expected "p001" -Actual $script:Projects[0].projectCode -Message "The dossier number casing was not updated."

    Reset-ProjectScenario
    $script:Projects += [PSCustomObject]@{ projectCode = "P010"; projectName = "Duplicate"; sector = ""; admins = @(); backupAdmins = @(); archived = $false }
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P010"; projectName = "Renamed"; sector = ""; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "A duplicate dossier number should be rejected."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Duplicate dossier validation wrote project data."

    Reset-ProjectScenario
    $script:IsSuperAdmin = $false
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P001"; projectName = "Blocked"; sector = ""; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 403 -Actual $script:CapturedStatusCode -Message "A regular admin must not update project metadata."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Unauthorized project update wrote data."

    Reset-ProjectScenario
    Set-TestEmployeeEntries -EmployeeCode "000000001" -Entries @([PSCustomObject]@{ entryId = "one"; projectCode = "P001" })
    Invoke-ProjectDeleteRoute -Permanent $true
    Assert-Equal -Expected 409 -Actual $script:CapturedStatusCode -Message "A referenced project must not be permanently deleted."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Rejected project deletion wrote data."

    Reset-ProjectScenario
    Invoke-ProjectDeleteRoute -Permanent $true
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "An unused project should be permanently deletable."
    Assert-Equal -Expected 0 -Actual $script:Projects.Count -Message "The unused project was not removed."
    Assert-Equal -Expected "Delete" -Actual $script:HistoryAction -Message "Permanent deletion used the wrong history action."

    Reset-ProjectScenario
    Invoke-ProjectDeleteRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "The archive compatibility path should still succeed."
    Assert-True -Condition ([bool]$script:Projects[0].archived) -Message "The archive compatibility path did not archive the project."
    Assert-Equal -Expected "Archive" -Actual $script:HistoryAction -Message "Archive used the wrong history action."

    Write-Host "Project admin mutation tests passed."
}
finally {
    Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
}
