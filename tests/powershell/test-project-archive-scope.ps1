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
$script:EmployeeNameMapCache = $null
$script:ProjectsCache = $null
$script:JsonOptionArrayCache = @{}
. (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/CommonHelpers.ps1")
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/ReadModelService.ps1")

$script:ProjectArchiveTestSummary = @(
    [PSCustomObject]@{
        projectCode = "LEGACY"; projectName = "Legacy active"; sector = "Operations"; totalOvertime = "01:00:00"; entryCount = 1
    },
    [PSCustomObject]@{
        projectCode = "ACTIVE"; projectName = "Active"; sector = "Operations"; archived = $false; totalOvertime = "02:00:00"; entryCount = 2
    },
    [PSCustomObject]@{
        projectCode = "ARCHIVED"; projectName = "Archived"; sector = "Closed"; archived = $true; totalOvertime = "03:00:00"; entryCount = 3
    }
)

function Get-ProjectSummaryList {
    param([string]$StartDate, [string]$EndDate, $CurrentUser)
    return @($script:ProjectArchiveTestSummary)
}

function Get-ProjectTrendModel {
    param([string]$StartDate, [string]$EndDate, $CurrentUser)
    return @{
        LEGACY = @([PSCustomObject]@{ month = "2026-01"; overtime = 1 })
        ACTIVE = @([PSCustomObject]@{ month = "2026-01"; overtime = 2 })
        ARCHIVED = @([PSCustomObject]@{ month = "2026-01"; overtime = 3 })
    }
}

function Get-ProjectDetailModel {
    param([string]$ProjectCode, [string]$StartDate, [string]$EndDate, $CurrentUser)
    $summary = $script:ProjectArchiveTestSummary | Where-Object { [string]$_.projectCode -eq $ProjectCode } | Select-Object -First 1
    if ($null -eq $summary) {
        return $null
    }

    return [PSCustomObject]@{
        projectCode = [string]$summary.projectCode
        archived = Test-ProjectArchived -Project $summary
        entryCount = [int]$summary.entryCount
        historyReadable = $true
    }
}

Assert-Equal -Expected "active" -Actual (ConvertTo-ProjectArchiveScope -Scope "") -Message "Blank project scope should default to active."
Assert-Equal -Expected "archived" -Actual (ConvertTo-ProjectArchiveScope -Scope " Archived ") -Message "Project scope normalization failed."
$invalidScopeRejected = $false
try {
    ConvertTo-ProjectArchiveScope -Scope "deleted" | Out-Null
}
catch [System.ArgumentException] {
    $invalidScopeRejected = $true
}
Assert-True -Condition $invalidScopeRejected -Message "An unsupported project scope should be rejected."

$legacyProject = [PSCustomObject]@{ projectCode = "LEGACY"; projectName = "Legacy active" }
Assert-Equal -Expected $false -Actual (Test-ProjectArchived -Project $legacyProject) -Message "A legacy project without archive metadata must remain active."
$normalizedLegacy = ConvertTo-NormalizedProjectObject -Project $legacyProject
Assert-Equal -Expected $false -Actual ([bool]$normalizedLegacy.archived) -Message "Legacy project normalization did not expose archived=false."
Assert-Equal -Expected (Get-DefaultProjectColorKey -ProjectCode "LEGACY") -Actual ([string]$normalizedLegacy.colorKey) -Message "Legacy project normalization did not expose a stable fallback color."
$normalizedColored = ConvertTo-NormalizedProjectObject -Project ([PSCustomObject]@{ projectCode = "COLOR"; projectName = "Colored"; colorKey = "violet" })
Assert-Equal -Expected "violet" -Actual ([string]$normalizedColored.colorKey) -Message "A persisted project color was not retained during normalization."

$activeModel = Get-ProjectsBootstrapModel -SelectedProjectCode "ARCHIVED" -Scope "active" -CurrentUser ([PSCustomObject]@{})
Assert-Equal -Expected "active" -Actual $activeModel.scope -Message "Bootstrap did not report its normalized active scope."
Assert-Equal -Expected 2 -Actual @($activeModel.summary).Count -Message "Default project bootstrap did not hide archived projects."
Assert-Equal -Expected "LEGACY" -Actual $activeModel.selectedProjectCode -Message "An archived selection should fall back to the first active project."
Assert-Equal -Expected 2 -Actual @($activeModel.trends.Keys).Count -Message "Active project trends were not scope-filtered."
Assert-True -Condition (-not $activeModel.trends.ContainsKey("ARCHIVED")) -Message "Archived trends leaked into the active bootstrap."

$archivedModel = Get-ProjectsBootstrapModel -SelectedProjectCode "ARCHIVED" -Scope "archived" -CurrentUser ([PSCustomObject]@{})
Assert-Equal -Expected 1 -Actual @($archivedModel.summary).Count -Message "Archived project bootstrap returned the wrong project count."
Assert-Equal -Expected "ARCHIVED" -Actual $archivedModel.selectedProjectCode -Message "Archived project selection was not retained."
Assert-Equal -Expected $true -Actual ([bool]$archivedModel.selectedProject.archived) -Message "Archived detail lost its archive marker."
Assert-Equal -Expected 3 -Actual ([int]$archivedModel.selectedProject.entryCount) -Message "Archived detail lost its historical entry count."
Assert-Equal -Expected $true -Actual ([bool]$archivedModel.selectedProject.historyReadable) -Message "Archived project detail is no longer readable."
Assert-Equal -Expected 1 -Actual @($archivedModel.trends.Keys).Count -Message "Archived trends were not scope-filtered."
Assert-True -Condition $archivedModel.trends.ContainsKey("ARCHIVED") -Message "Archived project trends were omitted."

$allModel = Get-ProjectsBootstrapModel -CurrentUser ([PSCustomObject]@{})
Assert-Equal -Expected 3 -Actual @($allModel.summary).Count -Message "All-project bootstrap did not include both active and archived projects."
Assert-Equal -Expected 3 -Actual @($allModel.trends.Keys).Count -Message "All-project bootstrap dropped trend history."
Assert-Equal -Expected "all" -Actual $allModel.scope -Message "Bootstrap should preserve its legacy all-project default."

$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:CapturedProjectScope = ""
$script:currentUser = [PSCustomObject]@{ role = "superAdmin" }

function Get-ProjectsForCurrentUser {
    param($CurrentUser, [string]$Scope = "all")
    $script:CapturedProjectScope = $Scope
    return @(Select-ProjectsByArchiveScope -Projects $script:ProjectArchiveTestSummary -Scope $Scope)
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

function Invoke-ProjectListRoute {
    param([Alias("Query")][string]$QueryText = "")

    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    $script:CapturedProjectScope = ""
    $request = [PSCustomObject]@{
        HttpMethod = "GET"
        Url = [Uri]("http://localhost/projects{0}" -f $QueryText)
    }
    $script:CapturedRequestQuery = [string]$request.Url.Query
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/projects/get.routes.ps1")
    }
}

Invoke-ProjectListRoute
Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Default project list failed."
Assert-Equal -Expected "active" -Actual $script:CapturedProjectScope -Message "GET /projects should default to active projects."
Assert-Equal -Expected 2 -Actual @(($script:CapturedMessage | ConvertFrom-Json)).Count -Message "Default project list exposed archived projects."

Invoke-ProjectListRoute -Query "?scope=archived"
Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Archived project list failed."
Assert-Equal -Expected "archived" -Actual $script:CapturedProjectScope -Message "Archived project scope was not passed to the read model (request query: $script:CapturedRequestQuery)."
Assert-Equal -Expected 1 -Actual @(($script:CapturedMessage | ConvertFrom-Json)).Count -Message "Archived project list returned the wrong records."

Invoke-ProjectListRoute -Query "?scope=all"
Assert-Equal -Expected 3 -Actual @(($script:CapturedMessage | ConvertFrom-Json)).Count -Message "All-project list did not include both scopes."

Invoke-ProjectListRoute -Query "?scope=deleted"
Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Invalid project scope should return HTTP 400."
Assert-True -Condition ($script:CapturedMessage -like "*active, archived, or all*") -Message "Invalid project scope returned an unclear error."

Write-Host "Project archive scope tests passed."
