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

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
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
$script:HistoryPublishChange = $true

. (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/CommonHelpers.ps1")
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/ProjectMutationService.ps1")

function Test-CurrentUserSuperAdmin { param($CurrentUser) return [bool]$script:IsSuperAdmin }
function Test-SaphirFileExists { param([string]$Path) return (Test-Path -LiteralPath $Path -PathType Leaf) }
function Test-SaphirDirectoryExists { param([string]$Path) return (Test-Path -LiteralPath $Path -PathType Container) }
function Get-SaphirChildFilesWithRetry {
    param([string]$Path, [string]$Filter)
    return @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -ErrorAction Stop)
}
function Read-TextFileWithRetry { param([string]$Path) return [System.IO.File]::ReadAllText($Path) }
function Read-JsonRequestBody { param($Request) return $script:RequestPayload }
function ConvertTo-CodeArray { param($Value) return @($Value) }
function Test-EmployeeCodeHasAdminRole { param([string]$EmployeeCode) return $true }
function Test-ProjectArchived {
    param($Project)
    return ($null -ne $Project -and $Project.PSObject.Properties.Name -contains "archived" -and [bool]$Project.archived)
}
function Acquire-ResourceLock { param([string]$ResourcePath) return [PSCustomObject]@{} }
function Release-ResourceLock { param($LockHandle) }
function Acquire-ProjectReferenceLock { return [PSCustomObject]@{} }
function Get-Projects { return @($script:Projects) }
function Read-ProjectsFromDisk { return @($script:Projects) }
function Write-JsonAtomic {
    param([string]$Path, $Value, [int]$Depth = 6)
    $script:WriteCount++
    $script:Projects = @($Value)
}
function Write-JsonArrayAtomic {
    param([string]$Path, $Items = @(), [int]$Depth = 6)
    Write-JsonAtomic -Path $Path -Value @($Items) -Depth $Depth
}
function Invoke-PostCommitActionSafely {
    param([string]$Description, [scriptblock]$Action)
    try { & $Action | Out-Null; return "" } catch { return "$Description`: $($_.Exception.Message)" }
}
function logHistory {
    param(
        [string]$Action,
        [string]$Message,
        [string]$EmployeeName,
        [bool]$PublishChange = $true
    )
    $script:HistoryAction = $Action
    $script:HistoryMessage = $Message
    $script:HistoryPublishChange = $PublishChange
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
            projectCode = "P001"; projectName = "Original"; sector = ""; admins = @(); backupAdmins = @(); archived = $false; colorKey = "blue"; markerKey = "square"
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
    $script:HistoryPublishChange = $true
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
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/update.routes.ps1")
    }
}

function Invoke-ProjectAddRoute {
    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url = [PSCustomObject]@{ AbsolutePath = "/projects" }
    }
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/add.routes.ps1")
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
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/delete.routes.ps1")
    }
}

function Invoke-ProjectRestoreRoute {
    param([string]$ProjectCode = "P001")

    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url = [PSCustomObject]@{ AbsolutePath = "/projects/$ProjectCode/restore" }
    }
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/restore.routes.ps1")
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
    Assert-Equal -Expected (Get-DefaultProjectColorKey -ProjectCode "P002") -Actual $script:Projects[1].colorKey -Message "A project without an explicit color did not receive its stable fallback."
    Assert-Equal -Expected (Get-DefaultProjectMarkerKey -ProjectCode "P002") -Actual $script:Projects[1].markerKey -Message "A project without an explicit marker did not receive its stable fallback."
    Assert-Equal -Expected "Created a project with code <strong>P002</strong>." -Actual $script:HistoryMessage -Message "A nameless project used an unclear history message."
    Assert-Equal -Expected $false -Actual $script:HistoryPublishChange -Message "Project creation duplicated sync publication through history logging."

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
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P005"; projectName = "Colored"; colorKey = "violet"; sector = ""; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A supported project color should be accepted."
    Assert-Equal -Expected "violet" -Actual $script:Projects[1].colorKey -Message "The chosen project color was not persisted."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P005-M"; projectName = "Marked"; markerKey = "triangle"; sector = ""; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A supported project marker should be accepted."
    Assert-Equal -Expected "triangle" -Actual $script:Projects[1].markerKey -Message "The chosen project marker was not persisted."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P006"; projectName = "Invalid color"; colorKey = "neon-chartreuse"; sector = ""; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "An arbitrary project color should be rejected."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Invalid project color validation wrote project data."

    Reset-ProjectScenario
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P006-M"; projectName = "Invalid marker"; markerKey = "hexagon"; sector = ""; admins = @(); backupAdmins = @() }
    Invoke-ProjectAddRoute
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "An arbitrary project marker should be rejected."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Invalid project marker validation wrote project data."

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
    Assert-Equal -Expected "square" -Actual $script:Projects[0].markerKey -Message "An update without markerKey changed the persisted marker."

    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P001"; projectName = "New name"; colorKey = "mint"; sector = "Sector"; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A project color update should succeed."
    Assert-Equal -Expected "mint" -Actual $script:Projects[0].colorKey -Message "The project color update was not persisted."

    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P001"; projectName = "New name"; markerKey = "diamond"; sector = "Sector"; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A project marker update should succeed."
    Assert-Equal -Expected "diamond" -Actual $script:Projects[0].markerKey -Message "The project marker update was not persisted."

    $writeCountBeforeInvalidMarker = $script:WriteCount
    $script:RequestPayload = [PSCustomObject]@{ projectCode = "P001"; projectName = "New name"; markerKey = "star"; sector = "Sector"; admins = @(); backupAdmins = @(); archived = $false }
    Invoke-ProjectUpdateRoute
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "An unsupported project marker update should be rejected."
    Assert-Equal -Expected $writeCountBeforeInvalidMarker -Actual $script:WriteCount -Message "Invalid project marker update wrote project data."

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
    Assert-Equal -Expected $false -Actual $script:HistoryPublishChange -Message "Project update duplicated sync publication through history logging."

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
    Assert-Equal -Expected $false -Actual $script:HistoryPublishChange -Message "Project deletion duplicated sync publication through history logging."

    Reset-ProjectScenario
    Invoke-ProjectDeleteRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "The archive compatibility path should still succeed."
    Assert-True -Condition ([bool]$script:Projects[0].archived) -Message "The archive compatibility path did not archive the project."
    Assert-Equal -Expected "Archive" -Actual $script:HistoryAction -Message "Archive used the wrong history action."
    Assert-Equal -Expected $false -Actual $script:HistoryPublishChange -Message "Project archive duplicated sync publication through history logging."
    $archivePayload = $script:CapturedMessage | ConvertFrom-Json
    Assert-Equal -Expected $false -Actual ([bool]$archivePayload.alreadyArchived) -Message "A newly archived project was reported as already archived."

    $script:HistoryAction = ""
    $writeCountBeforeArchiveRetry = $script:WriteCount
    $publishCountBeforeArchiveRetry = $script:PublishCount
    Invoke-ProjectDeleteRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Retrying project archive should be idempotent."
    Assert-Equal -Expected $writeCountBeforeArchiveRetry -Actual $script:WriteCount -Message "Idempotent project archive rewrote the catalog."
    Assert-Equal -Expected "" -Actual $script:HistoryAction -Message "Idempotent project archive duplicated history."
    Assert-Equal -Expected ($publishCountBeforeArchiveRetry + 1) -Actual $script:PublishCount -Message "Idempotent project archive did not republish refresh state."
    $archiveRetryPayload = $script:CapturedMessage | ConvertFrom-Json
    Assert-Equal -Expected $true -Actual ([bool]$archiveRetryPayload.alreadyArchived) -Message "An archived project retry was not identified."

    $script:HistoryAction = ""
    $script:HistoryMessage = ""
    $script:WriteCount = 0
    $script:PublishCount = 0
    Invoke-ProjectRestoreRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "An archived project should be restorable."
    Assert-Equal -Expected $false -Actual ([bool]$script:Projects[0].archived) -Message "Project restore left the project archived."
    Assert-Equal -Expected 1 -Actual $script:WriteCount -Message "Project restore did not persist exactly one catalog change."
    Assert-Equal -Expected "Update" -Actual $script:HistoryAction -Message "Project restore used the wrong history action."
    Assert-Equal -Expected "Restored the project <strong>P001</strong>." -Actual $script:HistoryMessage -Message "Project restore history was unclear."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Project restore did not publish its catalog change."
    $restorePayload = $script:CapturedMessage | ConvertFrom-Json
    Assert-Equal -Expected $false -Actual ([bool]$restorePayload.alreadyActive) -Message "A restored archived project was reported as already active."

    $script:HistoryAction = ""
    $writeCountBeforeRetry = $script:WriteCount
    $publishCountBeforeRetry = $script:PublishCount
    Invoke-ProjectRestoreRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Retrying project restore should be idempotent."
    Assert-Equal -Expected $writeCountBeforeRetry -Actual $script:WriteCount -Message "Idempotent project restore rewrote the catalog."
    Assert-Equal -Expected "" -Actual $script:HistoryAction -Message "Idempotent project restore duplicated history."
    Assert-Equal -Expected ($publishCountBeforeRetry + 1) -Actual $script:PublishCount -Message "Idempotent project restore did not republish refresh state."
    $retryPayload = $script:CapturedMessage | ConvertFrom-Json
    Assert-Equal -Expected $true -Actual ([bool]$retryPayload.alreadyActive) -Message "An active project restore retry was not identified."

    Reset-ProjectScenario
    $script:Projects[0] = [PSCustomObject]@{
        projectCode = "P001"; projectName = "Legacy active"; sector = ""; admins = @(); backupAdmins = @()
    }
    Invoke-ProjectRestoreRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A legacy project without archive metadata should be treated as active."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Restoring a legacy active project rewrote its record."
    $legacyPayload = $script:CapturedMessage | ConvertFrom-Json
    Assert-Equal -Expected $true -Actual ([bool]$legacyPayload.alreadyActive) -Message "A legacy active project was reported as archived."

    Reset-ProjectScenario
    $script:Projects[0].archived = $true
    $script:IsSuperAdmin = $false
    Invoke-ProjectRestoreRoute
    Assert-Equal -Expected 403 -Actual $script:CapturedStatusCode -Message "A regular admin must not restore an archived project."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Unauthorized project restore wrote project data."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Unauthorized project restore published a catalog change."

    Reset-ProjectScenario
    Invoke-ProjectRestoreRoute -ProjectCode "MISSING"
    Assert-Equal -Expected 404 -Actual $script:CapturedStatusCode -Message "Restoring an unknown project should return not found."
    Assert-Equal -Expected 0 -Actual $script:WriteCount -Message "Unknown project restore wrote project data."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Unknown project restore published a catalog change."

    Write-Host "Project admin mutation tests passed."
}
finally {
    Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
}
