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
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-route-sync-test-{0}" -f ([Guid]::NewGuid().ToString("N")))
$script:sharedFolder = $tempFolder
$script:currentUser = [PSCustomObject]@{ username = "manager"; displayName = "Manager"; role = "super-admin" }

$script:RequestPayload = $null
$script:Entries = @()
$script:WriteCount = 0
$script:WriteFailure = ""
$script:HistoryFailure = ""
$script:PublishFailure = ""
$script:PublishCount = 0
$script:LastPublishCategory = ""
$script:LastPublishResource = ""
$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:DirectoryOperation = ""
$script:DirectoryServiceFailure = ""
$script:DirectoryServiceCalls = 0
$script:SeedServiceFailure = ""
$script:demoSeedEnabled = $true
$script:AuthUpdateResult = $true
$script:AuthUpdateCalls = 0
$script:SessionRevokeFailure = ""
$script:ProjectOperation = ""
$script:Projects = @()

function Read-JsonRequestBody { param($Request) return $script:RequestPayload }
function Acquire-ResourceLock { param([string]$ResourcePath) return [PSCustomObject]@{} }
function Release-ResourceLock { param($LockHandle) }
function Read-JsonArrayFile { param([string]$Path) return @($script:Entries) }
function Write-JsonAtomic {
    param([string]$Path, $Value, [int]$Depth = 6)
    $script:WriteCount++
    if (-not [string]::IsNullOrWhiteSpace($script:WriteFailure)) {
        throw $script:WriteFailure
    }
}
function Find-EntryIndex { param($Entries, [string]$EntryId, [string]$Date, [string]$PunchIn) return 0 }
function Test-CurrentUserCanManageEntry { param($CurrentUser, $Entry) return $true }
function Test-CurrentUserCanApproveEmployeeRole { param($CurrentUser, [string]$EmployeeRole) return $true }
function Get-EmployeeRoleByCode { param([string]$EmployeeCode) return "employee" }
function Get-EmployeeName { param([string]$EmployeeCode) return "Employee $EmployeeCode" }
function Get-EntryHistorySpanText { param([string]$StartTime, [string]$EndTime) return "from $StartTime to $EndTime" }
function Format-TimeForHistory { param([string]$TimeText) return $TimeText }
function logHistory {
    param([string]$Action, [string]$Message, [string]$EmployeeName)
    if (-not [string]::IsNullOrWhiteSpace($script:HistoryFailure)) {
        throw $script:HistoryFailure
    }
}
function Publish-DataChange {
    param(
        [string]$Category = "data",
        [string]$Resource = "shared",
        [string[]]$AffectedEmployeeCodes = @()
    )

    $script:PublishCount++
    $script:LastPublishCategory = $Category
    $script:LastPublishResource = $Resource
    if (-not [string]::IsNullOrWhiteSpace($script:PublishFailure)) {
        throw $script:PublishFailure
    }
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
    $script:WriteCount = 0
    $script:WriteFailure = ""
    $script:HistoryFailure = ""
    $script:PublishFailure = ""
    $script:PublishCount = 0
    $script:LastPublishCategory = ""
    $script:LastPublishResource = ""
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
    $script:DirectoryServiceFailure = ""
    $script:DirectoryServiceCalls = 0
    $script:SeedServiceFailure = ""
    $script:AuthUpdateResult = $true
    $script:AuthUpdateCalls = 0
    $script:SessionRevokeFailure = ""
    $script:ProjectOperation = ""
    $script:Projects = @()
}

function Invoke-ApprovalRoute {
    $employeeCode = "000000001"
    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url = [PSCustomObject]@{ AbsolutePath = "/employee/approval/$employeeCode" }
    }
    $response = [PSCustomObject]@{}
    $script:RequestPayload = [PSCustomObject]@{
        entryId = "entry-1"
        date = "2026-07-01"
        punchIn = "08:00:00"
        status = "approved"
        message = ""
    }
    $script:Entries = @([PSCustomObject]@{
        entryId = "entry-1"
        date = "2026-07-01"
        punchIn = "08:00:00"
        punchOut = "09:00:00"
        status = "pending"
        message = ""
        projectCode = "P001"
    })

    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/approval.routes.ps1")
    }
}

function Invoke-AddRouteExpectingFailure {
    $employeeCode = "000000001"
    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url = [PSCustomObject]@{ AbsolutePath = "/employee/add/$employeeCode" }
    }
    $response = [PSCustomObject]@{}
    $script:RequestPayload = [PSCustomObject]@{
        date = "2026-07-01"
        punchIn = "08:00:00"
        punchOut = "09:00:00"
        projectCode = "P001"
        overtimeCode = "260"
        paymentOption = "cash"
        reasonCode = "D"
    }
    $script:Entries = @()

    try {
        for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
            . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/add.routes.ps1")
        }
    }
    catch {
        return $_.Exception.Message
    }

    throw "The add route scenario was expected to fail."
}

function Test-CurrentUserMatchesEmployeeCode { param($CurrentUser, [string]$EmployeeCode) return $false }
function Get-ActiveProjects { return @([PSCustomObject]@{ projectCode = "P001" }) }
function Test-CurrentUserCanModifyProjectCode { param($CurrentUser, [string]$ProjectCode) return $true }
function Get-OvertimeCodes { return @() }
function Get-PaymentOptions { return @() }
function Get-ReasonCodes { return @() }
function Test-OptionCode { param($Options, [string]$Code, [bool]$AllowBlank) return $true }
function Convert-ToNormalizedTimeText { param([string]$TimeText) return $TimeText }
function Convert-ToNearestQuarterHourText { param([string]$Date, [string]$TimeText) return $TimeText }
function New-EntryIdentifier { return "entry-new" }

function Test-CurrentUserSuperAdmin { param($CurrentUser) return $true }
function Get-NormalizedRoleName { param([string]$Role) return $Role }
function ConvertTo-TimeEntryTypeArray { param($Value) return @($Value) }
function Get-EmployeeDirectoryRecordMetadata {
    param([string]$EmployeeCode, [switch]$IncludeDisabled)
    if ($script:DirectoryOperation -eq "create") {
        return $null
    }
    return [PSCustomObject]@{ code = $EmployeeCode; name = "Directory Employee"; archived = ($script:DirectoryOperation -eq "restore") }
}
function Invoke-DirectoryServiceResult {
    $script:DirectoryServiceCalls++
    if (-not [string]::IsNullOrWhiteSpace($script:DirectoryServiceFailure)) {
        throw $script:DirectoryServiceFailure
    }
    return [PSCustomObject]@{
        updated = $true
        error = $null
        temporaryPassword = "temporary"
        created = $true
        reactivated = $false
    }
}
function Add-EmployeeDirectoryRecord {
    param([string]$EmployeeCode, [string]$DisplayName, [string]$InitialPassword, [bool]$MustChangePassword, [string]$Role, $TimeEntryTypes, $Gc179Profile)
    return Invoke-DirectoryServiceResult
}
function Update-EmployeeDirectoryRecord {
    param([string]$EmployeeCode, [string]$DisplayName, [string]$Role, $TimeEntryTypes, $Gc179Profile)
    return Invoke-DirectoryServiceResult
}
function Remove-EmployeeDirectoryRecord { param([string]$EmployeeCode) return Invoke-DirectoryServiceResult }
function Restore-EmployeeDirectoryRecord { param([string]$EmployeeCode) return Invoke-DirectoryServiceResult }

function Invoke-DirectoryRoute {
    param([string]$Operation)

    $script:DirectoryOperation = $Operation
    $employeeCode = "000000001"
    $routePath = ""
    $httpMethod = ""
    $absolutePath = ""
    switch ($Operation) {
        "create" {
            $routePath = "apps/admin/backend/routes/employee/create-record.routes.ps1"
            $httpMethod = "POST"
            $absolutePath = "/employees"
        }
        "update" {
            $routePath = "apps/admin/backend/routes/employee/update-record.routes.ps1"
            $httpMethod = "PUT"
            $absolutePath = "/employees/$employeeCode"
        }
        "delete" {
            $routePath = "apps/admin/backend/routes/employee/delete-record.routes.ps1"
            $httpMethod = "DELETE"
            $absolutePath = "/employees/$employeeCode"
        }
        "restore" {
            $routePath = "apps/admin/backend/routes/employee/restore-record.routes.ps1"
            $httpMethod = "POST"
            $absolutePath = "/employees/$employeeCode/restore"
        }
        default { throw "Unknown directory operation '$Operation'." }
    }

    $request = [PSCustomObject]@{ HttpMethod = $httpMethod; Url = [PSCustomObject]@{ AbsolutePath = $absolutePath } }
    $response = [PSCustomObject]@{}
    $script:RequestPayload = [PSCustomObject]@{
        code = $employeeCode
        name = "Directory Employee"
        role = "employee"
        timeEntryTypes = @("overtime")
        mustChangePassword = $true
        initialPassword = "temporary-password"
    }

    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath $routePath)
    }
}

function Test-NewPasswordPolicy { param([string]$Password) return $null }
function Set-EmployeeUserPassword {
    param([string]$EmployeeCode, [string]$NewPassword, [bool]$MustChangePassword)
    $script:AuthUpdateCalls++
    return [PSCustomObject]@{
        updated = [bool]$script:AuthUpdateResult
        created = $false
        error = if ($script:AuthUpdateResult) { $null } else { "auth precommit failure" }
    }
}
function Revoke-SessionsForUsername {
    param([string]$Username)
    if (-not [string]::IsNullOrWhiteSpace($script:SessionRevokeFailure)) {
        throw $script:SessionRevokeFailure
    }
}
function Invoke-PasswordRoute {
    $employeeCode = "000000001"
    $request = [PSCustomObject]@{ HttpMethod = "POST"; Url = [PSCustomObject]@{ AbsolutePath = "/employee/password/$employeeCode" } }
    $response = [PSCustomObject]@{}
    $script:RequestPayload = [PSCustomObject]@{ newPassword = "Secure-password-123"; mustChangePassword = $true }
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/password.routes.ps1")
    }
}

function ConvertTo-CodeArray { param($Value) return @($Value) }
function Test-EmployeeCodeHasAdminRole { param([string]$EmployeeCode) return $true }
function Get-Projects { return ,@($script:Projects) }
function Test-ProjectArchived {
    param($Project)
    return ($Project.PSObject.Properties.Name -contains "archived" -and [bool]$Project.archived)
}
function Invoke-ProjectRouteExpectingFailure {
    param([string]$Operation)

    $script:ProjectOperation = $Operation
    $projectCode = if ($Operation -eq "add") { "P002" } else { "P001" }
    $routePath = ""
    $httpMethod = ""
    $absolutePath = ""
    switch ($Operation) {
        "add" {
            $routePath = "apps/admin/backend/routes/projects/add.routes.ps1"
            $httpMethod = "POST"
            $absolutePath = "/projects"
            $script:Projects = @([PSCustomObject]@{ projectCode = "P001"; projectName = "Existing"; archived = $false })
        }
        "update" {
            $routePath = "apps/admin/backend/routes/projects/update.routes.ps1"
            $httpMethod = "PUT"
            $absolutePath = "/projects/$projectCode"
            $script:Projects = @([PSCustomObject]@{ projectCode = $projectCode; projectName = "Existing"; sector = ""; admins = @(); backupAdmins = @(); archived = $false })
        }
        "delete" {
            $routePath = "apps/admin/backend/routes/projects/delete.routes.ps1"
            $httpMethod = "DELETE"
            $absolutePath = "/projects/$projectCode"
            $script:Projects = @([PSCustomObject]@{ projectCode = $projectCode; projectName = "Existing"; archived = $false })
        }
        default { throw "Unknown project operation '$Operation'." }
    }

    $script:projectsFile = Join-Path -Path $tempFolder -ChildPath "projects.json"
    $script:RequestPayload = [PSCustomObject]@{
        projectCode = $projectCode
        projectName = "Updated project"
        sector = "Sector"
        admins = @()
        backupAdmins = @()
    }
    $request = [PSCustomObject]@{ HttpMethod = $httpMethod; Url = [PSCustomObject]@{ AbsolutePath = $absolutePath } }
    $response = [PSCustomObject]@{}

    try {
        for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
            . (Join-Path -Path $repoRoot -ChildPath $routePath)
        }
    }
    catch {
        return $_.Exception.Message
    }

    throw "The project $Operation scenario was expected to fail."
}

function Get-AuthenticatedUserFromRequest { param($Request) return $script:currentUser }
function New-DemoOvertimeEntries {
    param($CurrentUser, [int]$MinimumEntriesPerEmployee, [int]$MaximumEntriesPerEmployee, [int]$MonthsBack)
    if (-not [string]::IsNullOrWhiteSpace($script:SeedServiceFailure)) {
        throw $script:SeedServiceFailure
    }
    return [PSCustomObject]@{ message = "seeded"; entryCount = 1 }
}
function Invoke-SeedRoute {
    $request = [PSCustomObject]@{ HttpMethod = "POST"; Url = [PSCustomObject]@{ AbsolutePath = "/seed/demo-entries" } }
    $response = [PSCustomObject]@{}
    $script:RequestPayload = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/seed.routes.ps1")
    }
}

try {
    New-Item -ItemType Directory -Path $tempFolder | Out-Null
    [System.IO.File]::WriteAllText((Join-Path -Path $tempFolder -ChildPath "000000001_data.json"), "[]")

    Reset-ScenarioState
    $script:HistoryFailure = "approval history failure"
    Invoke-ApprovalRoute
    Assert-Equal -Expected 1 -Actual $script:WriteCount -Message "Approval should commit once before history fails."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Approval should publish after a committed mutation even when history fails."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "approval history failure" -Message "Approval lost the history failure."

    Reset-ScenarioState
    $script:HistoryFailure = "approval primary failure"
    $script:PublishFailure = "approval publish failure"
    Invoke-ApprovalRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Approval should still attempt publication when history and publication both fail."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "approval primary failure" -Message "Approval publication failure masked the earlier history failure."

    Reset-ScenarioState
    $script:PublishFailure = "approval publish-only failure"
    Invoke-ApprovalRoute
    Assert-Equal -Expected 500 -Actual $script:CapturedStatusCode -Message "Approval publication-only failure should return an error."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "approval publish-only failure" -Message "Approval did not surface a publication-only failure."

    Reset-ScenarioState
    $script:WriteFailure = "approval write failure"
    Invoke-ApprovalRoute
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Approval must not publish when its primary write did not commit."

    Reset-ScenarioState
    $script:HistoryFailure = "add history failure"
    $addFailure = Invoke-AddRouteExpectingFailure
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Add should publish after a committed mutation even when history fails."
    Assert-Contains -Value $addFailure -ExpectedText "add history failure" -Message "Add lost the history failure."

    Reset-ScenarioState
    $script:HistoryFailure = "add primary failure"
    $script:PublishFailure = "add publish failure"
    $addFailure = Invoke-AddRouteExpectingFailure
    Assert-Contains -Value $addFailure -ExpectedText "add primary failure" -Message "Add publication failure masked the earlier history failure."

    foreach ($operation in @("create", "update", "delete", "restore")) {
        Reset-ScenarioState
        $script:HistoryFailure = "$operation directory history failure"
        Invoke-DirectoryRoute -Operation $operation
        Assert-Equal -Expected 1 -Actual $script:DirectoryServiceCalls -Message "Directory $operation did not invoke its mutation service once."
        Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Directory $operation should publish after a committed mutation when history fails."
        Assert-Equal -Expected "employee-directory" -Actual $script:LastPublishCategory -Message "Directory $operation published the wrong category."
        Assert-Contains -Value $script:CapturedMessage -ExpectedText "$operation directory history failure" -Message "Directory $operation lost its history failure."
    }

    Reset-ScenarioState
    $script:DirectoryServiceFailure = "directory partial service failure"
    $script:PublishFailure = "directory publish failure"
    Invoke-DirectoryRoute -Operation "update"
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Directory update should publish after a potentially partial service failure."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "directory partial service failure" -Message "Directory publication failure masked the earlier service failure."

    Reset-ScenarioState
    $script:PublishFailure = "directory publish-only failure"
    Invoke-DirectoryRoute -Operation "update"
    Assert-Equal -Expected 500 -Actual $script:CapturedStatusCode -Message "Directory publication-only failure should return an error."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "directory publish-only failure" -Message "Directory did not surface a publication-only failure."

    Reset-ScenarioState
    $script:HistoryFailure = "auth history failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 1 -Actual $script:AuthUpdateCalls -Message "Password reset should invoke the auth mutation once."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Password reset should publish after a committed auth mutation when history fails."
    Assert-Equal -Expected "auth" -Actual $script:LastPublishCategory -Message "Password reset published the wrong category."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth history failure" -Message "Password reset lost the history failure."

    Reset-ScenarioState
    $script:HistoryFailure = "auth primary failure"
    $script:PublishFailure = "auth publish failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Password reset should attempt publication when history and publication both fail."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth primary failure" -Message "Auth publication failure masked the earlier history failure."

    Reset-ScenarioState
    $script:SessionRevokeFailure = "session revoke failure"
    $script:PublishFailure = "auth publication after revoke failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Password reset should publish after the password commit when session revocation fails."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "session revoke failure" -Message "Auth publication failure masked the earlier session-revocation failure."

    Reset-ScenarioState
    $script:PublishFailure = "auth publish-only failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 500 -Actual $script:CapturedStatusCode -Message "Auth publication-only failure should return an error."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth publish-only failure" -Message "Password reset did not surface a publication-only failure."

    Reset-ScenarioState
    $script:AuthUpdateResult = $false
    Invoke-PasswordRoute
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Password reset must not publish when the auth service reports no committed update."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth precommit failure" -Message "Password reset lost its precommit failure."

    foreach ($operation in @("add", "update", "delete")) {
        Reset-ScenarioState
        $script:HistoryFailure = "$operation project history failure"
        $projectFailure = Invoke-ProjectRouteExpectingFailure -Operation $operation
        Assert-Equal -Expected 1 -Actual $script:WriteCount -Message "Project $operation should commit once before history fails (route error: $projectFailure)."
        Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Project $operation should publish after its committed mutation when history fails."
        Assert-Equal -Expected "project" -Actual $script:LastPublishCategory -Message "Project $operation published the wrong category."
        Assert-Contains -Value $projectFailure -ExpectedText "$operation project history failure" -Message "Project $operation lost its history failure."
    }

    Reset-ScenarioState
    $script:HistoryFailure = "project primary failure"
    $script:PublishFailure = "project publish failure"
    $projectFailure = Invoke-ProjectRouteExpectingFailure -Operation "update"
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Project update should attempt publication when history and publication both fail."
    Assert-Contains -Value $projectFailure -ExpectedText "project primary failure" -Message "Project publication failure masked the earlier history failure."

    Reset-ScenarioState
    $script:PublishFailure = "project publish-only failure"
    $projectFailure = Invoke-ProjectRouteExpectingFailure -Operation "update"
    Assert-Contains -Value $projectFailure -ExpectedText "project publish-only failure" -Message "Project update did not surface a publication-only failure."

    Reset-ScenarioState
    $script:WriteFailure = "project precommit failure"
    $projectFailure = Invoke-ProjectRouteExpectingFailure -Operation "update"
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Project update must not publish when its primary write did not commit."
    Assert-Contains -Value $projectFailure -ExpectedText "project precommit failure" -Message "Project update lost its precommit write failure."

    Reset-ScenarioState
    $script:SeedServiceFailure = "seed partial failure"
    Invoke-SeedRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Seed should conservatively publish after a service failure that may follow partial writes."
    Assert-Equal -Expected "seed" -Actual $script:LastPublishCategory -Message "Seed fallback published the wrong category."
    Assert-Equal -Expected "*" -Actual $script:LastPublishResource -Message "Seed fallback should publish a wildcard resource."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "seed partial failure" -Message "Seed lost the service failure."

    Reset-ScenarioState
    $script:SeedServiceFailure = "seed primary failure"
    $script:PublishFailure = "seed publish failure"
    Invoke-SeedRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Seed should attempt fallback publication when the service and publication both fail."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "seed primary failure" -Message "Seed publication failure masked the earlier service failure."

    Reset-ScenarioState
    Invoke-SeedRoute
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "The seed route should not duplicate the service publication after a successful call."

    $sourceAssertions = @(
        [PSCustomObject]@{ Path = "apps/admin/backend/routes/employee/update.routes.ps1"; CommitVariable = 'entryMutationCommitted' },
        [PSCustomObject]@{ Path = "apps/admin/backend/routes/employee/delete.routes.ps1"; CommitVariable = 'entryMutationCommitted' }
    )
    foreach ($assertion in $sourceAssertions) {
        $source = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath $assertion.Path))
        Assert-Contains -Value $source -ExpectedText ('$' + $assertion.CommitVariable + ' = $true') -Message "$($assertion.Path) does not mark its successful primary write."
        Assert-Contains -Value $source -ExpectedText 'if ($null -eq $entryMutationError)' -Message "$($assertion.Path) does not preserve error precedence during publication."
    }

    Write-Host "Route sync publication tests passed: committed writes publish through later failures, and earlier errors retain precedence."
}
finally {
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
}
