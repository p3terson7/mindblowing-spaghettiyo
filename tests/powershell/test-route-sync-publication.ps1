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

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-route-sync-test-{0}" -f ([Guid]::NewGuid().ToString("N")))
$script:sharedFolder = $tempFolder
$script:currentUser = [PSCustomObject]@{ username = "manager"; displayName = "Manager"; role = "super-admin" }

$script:RequestPayload = $null
$script:Entries = @()
$script:WriteCount = 0
$script:WriteFailure = ""
$script:HistoryFailure = ""
$script:HistoryCallCount = 0
$script:LastHistoryPublishChange = $true
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
$script:AuthUpdateFailure = ""
$script:AuthUpdateCalls = 0
$script:SessionRevokeFailure = ""
$script:ProjectOperation = ""
$script:Projects = @()
$script:ActiveResourceLockCount = 0
$script:PostCommitActionRanWhileLocked = $false
$script:LocalProjectCacheClearCount = 0

function Read-JsonRequestBody { param($Request) return $script:RequestPayload }
function Acquire-ResourceLock {
    param([string]$ResourcePath)
    $script:ActiveResourceLockCount++
    return [PSCustomObject]@{ Released = $false }
}
function Release-ResourceLock {
    param($LockHandle)
    if ($null -eq $LockHandle -or [bool]$LockHandle.Released) {
        return
    }
    $LockHandle.Released = $true
    $script:ActiveResourceLockCount--
}
function Acquire-ProjectReferenceLock {
    return (Acquire-ResourceLock -ResourcePath "project-reference")
}
function Test-ActiveProjectCodeFromDisk { param([string]$ProjectCode) return $ProjectCode -eq "P001" }
function Test-CurrentUserCanModifyActiveProjectCodeFromDisk { param($CurrentUser, [string]$ProjectCode) return $ProjectCode -eq "P001" }
function Read-JsonArrayFile { param([string]$Path) return @($script:Entries) }
function Write-JsonAtomic {
    param([string]$Path, $Value, [int]$Depth = 6)
    $script:WriteCount++
    if (-not [string]::IsNullOrWhiteSpace($script:WriteFailure)) {
        throw $script:WriteFailure
    }
}
function Write-JsonArrayAtomic {
    param([string]$Path, $Items = @(), [int]$Depth = 6)
    Write-JsonAtomic -Path $Path -Value @($Items) -Depth $Depth
}
function Find-EntryIndex { param($Entries, [string]$EntryId, [string]$Date, [string]$PunchIn) return 0 }
function Test-CurrentUserCanManageEntry { param($CurrentUser, $Entry) return $true }
function Test-CurrentUserCanApproveEmployeeRole { param($CurrentUser, [string]$EmployeeRole) return $true }
function Test-CurrentUserMatchesEmployeeCode { param($CurrentUser, [string]$EmployeeCode) return $false }
function Get-EmployeeRoleByCode { param([string]$EmployeeCode) return "employee" }
function Get-EmployeeUserByCode {
    param([string]$EmployeeCode)
    return [PSCustomObject]@{ username = $EmployeeCode; employeeCode = $EmployeeCode; disabled = $false }
}
function Test-EmployeeUserRecord { param($UserRecord, [string]$EmployeeCode) return $true }
function Ensure-EmployeeDataFile {
    param([string]$EmployeeCode)
    return (Join-Path -Path $script:sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode))
}
function Get-EmployeeName { param([string]$EmployeeCode) return "Employee $EmployeeCode" }
function Test-SaphirFileExists { param([string]$Path) return $true }
function Rethrow-HttpStatusException { param($Exception) }
function Get-EntryHistorySpanText { param([string]$StartTime, [string]$EndTime) return "from $StartTime to $EndTime" }
function Format-TimeForHistory { param([string]$TimeText) return $TimeText }
function logHistory {
    param(
        [string]$Action,
        [string]$Message,
        [string]$EmployeeName,
        [bool]$PublishChange = $true
    )
    $script:HistoryCallCount++
    $script:LastHistoryPublishChange = $PublishChange
    if ($script:ActiveResourceLockCount -gt 0) {
        $script:PostCommitActionRanWhileLocked = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($script:HistoryFailure)) {
        throw $script:HistoryFailure
    }
    if ($PublishChange) {
        Publish-DataChange -Category "history" -Resource $EmployeeName | Out-Null
    }
}
function Invoke-PostCommitActionSafely {
    param([string]$Description, [scriptblock]$Action)
    try { & $Action | Out-Null; return "" } catch { return "$Description`: $($_.Exception.Message)" }
}
function Clear-LocalProjectMutationCaches {
    if ($script:ActiveResourceLockCount -gt 0) {
        $script:PostCommitActionRanWhileLocked = $true
    }
    $script:LocalProjectCacheClearCount++
}
function Publish-DataChange {
    param(
        [string]$Category = "data",
        [string]$Resource = "shared",
        [string[]]$AffectedEmployeeCodes = @()
    )

    if ($script:ActiveResourceLockCount -gt 0) {
        $script:PostCommitActionRanWhileLocked = $true
    }
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
    $script:HistoryCallCount = 0
    $script:LastHistoryPublishChange = $true
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
    $script:AuthUpdateFailure = ""
    $script:AuthUpdateCalls = 0
    $script:SessionRevokeFailure = ""
    $script:ProjectOperation = ""
    $script:Projects = @()
    $script:ActiveResourceLockCount = 0
    $script:PostCommitActionRanWhileLocked = $false
    $script:LocalProjectCacheClearCount = 0
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
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/approval.routes.ps1")
    }
}

function Invoke-AddRouteScenario {
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
            . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/add.routes.ps1")
        }
    }
    catch {
        return $_.Exception.Message
    }

    return $script:CapturedMessage
}

function Test-CurrentUserMatchesEmployeeCode { param($CurrentUser, [string]$EmployeeCode) return $false }
function Get-ActiveProjects { return @([PSCustomObject]@{ projectCode = "P001" }) }
function Test-CurrentUserCanModifyProjectCode { param($CurrentUser, [string]$ProjectCode) return $true }
function Get-OvertimeCodes { return @() }
function Get-PaymentOptions { return @() }
function Get-ReasonCodes { return @() }
function Test-OptionCode { param($Options, [string]$Code, [bool]$AllowBlank) return $true }
function Convert-ToNormalizedDateText { param([string]$DateText) return $DateText }
function Convert-ToNormalizedTimeText { param([string]$TimeText) return $TimeText }
function Convert-ToNearestQuarterHourText { param([string]$Date, [string]$TimeText) return $TimeText }
function Get-QuarterHourCreditSummary {
    param([string]$Date, [string]$PunchIn, [string]$PunchOut)
    return [PSCustomObject]@{ isValid = $true; creditedOvertime = "01:00:00" }
}
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
            $routePath = "app/backend/routes/employee/create-record.routes.ps1"
            $httpMethod = "POST"
            $absolutePath = "/employees"
        }
        "update" {
            $routePath = "app/backend/routes/employee/update-record.routes.ps1"
            $httpMethod = "PUT"
            $absolutePath = "/employees/$employeeCode"
        }
        "delete" {
            $routePath = "app/backend/routes/employee/delete-record.routes.ps1"
            $httpMethod = "DELETE"
            $absolutePath = "/employees/$employeeCode"
        }
        "restore" {
            $routePath = "app/backend/routes/employee/restore-record.routes.ps1"
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
    if (-not [string]::IsNullOrWhiteSpace($script:AuthUpdateFailure)) {
        throw $script:AuthUpdateFailure
    }
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
    $response = [PSCustomObject]@{ Headers = @{} }
    $script:RequestPayload = [PSCustomObject]@{ newPassword = "Secure-password-123"; mustChangePassword = $true }
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/password.routes.ps1")
    }
}

function ConvertTo-CodeArray { param($Value) return @($Value) }
function Test-EmployeeCodeHasAdminRole { param([string]$EmployeeCode) return $true }
function Test-ProjectCodeFormat { param([string]$ProjectCode) return ($ProjectCode -match '^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$') }
function Get-ProjectColorKeys { return @("blue", "green", "violet", "teal", "amber", "coral", "pink", "indigo", "graphite", "mint") }
function Test-ProjectColorKey {
    param([AllowNull()][string]$ColorKey)
    return (@(Get-ProjectColorKeys) -contains ([string]$ColorKey).Trim().ToLowerInvariant())
}
function Resolve-ProjectColorKey {
    param([AllowNull()][string]$ColorKey, [AllowNull()][string]$ProjectCode)
    $candidate = ([string]$ColorKey).Trim().ToLowerInvariant()
    if (Test-ProjectColorKey -ColorKey $candidate) { return $candidate }
    return "blue"
}
function Set-ProjectRecordColorKey {
    param([Parameter(Mandatory = $true)]$Project, [AllowNull()][string]$ColorKey)
    $resolved = Resolve-ProjectColorKey -ColorKey $ColorKey -ProjectCode ([string]$Project.projectCode)
    if ($Project.PSObject.Properties.Name -contains "colorKey") { $Project.colorKey = $resolved }
    else { $Project | Add-Member -NotePropertyName colorKey -NotePropertyValue $resolved }
    return $resolved
}
function Get-ProjectMarkerKeys { return @("circle", "square", "diamond", "triangle") }
function Test-ProjectMarkerKey {
    param([AllowNull()][string]$MarkerKey)
    return (@(Get-ProjectMarkerKeys) -contains ([string]$MarkerKey).Trim().ToLowerInvariant())
}
function Resolve-ProjectMarkerKey {
    param([AllowNull()][string]$MarkerKey, [AllowNull()][string]$ProjectCode)
    $candidate = ([string]$MarkerKey).Trim().ToLowerInvariant()
    if (Test-ProjectMarkerKey -MarkerKey $candidate) { return $candidate }
    return "circle"
}
function Set-ProjectRecordMarkerKey {
    param([Parameter(Mandatory = $true)]$Project, [AllowNull()][string]$MarkerKey)
    $resolved = Resolve-ProjectMarkerKey -MarkerKey $MarkerKey -ProjectCode ([string]$Project.projectCode)
    if ($Project.PSObject.Properties.Name -contains "markerKey") { $Project.markerKey = $resolved }
    else { $Project | Add-Member -NotePropertyName markerKey -NotePropertyValue $resolved }
    return $resolved
}
function Get-Projects { return ,@($script:Projects) }
function Read-ProjectsFromDisk { return @($script:Projects) }
function Test-ProjectArchived {
    param($Project)
    return ($Project.PSObject.Properties.Name -contains "archived" -and [bool]$Project.archived)
}
function Invoke-ProjectRouteScenario {
    param([string]$Operation)

    $script:ProjectOperation = $Operation
    $projectCode = if ($Operation -eq "add") { "P002" } else { "P001" }
    $routePath = ""
    $httpMethod = ""
    $absolutePath = ""
    switch ($Operation) {
        "add" {
            $routePath = "app/backend/routes/projects/add.routes.ps1"
            $httpMethod = "POST"
            $absolutePath = "/projects"
            $script:Projects = @([PSCustomObject]@{ projectCode = "P001"; projectName = "Existing"; archived = $false })
        }
        "update" {
            $routePath = "app/backend/routes/projects/update.routes.ps1"
            $httpMethod = "PUT"
            $absolutePath = "/projects/$projectCode"
            $script:Projects = @([PSCustomObject]@{ projectCode = $projectCode; projectName = "Existing"; sector = ""; admins = @(); backupAdmins = @(); archived = $false })
        }
        "delete" {
            $routePath = "app/backend/routes/projects/delete.routes.ps1"
            $httpMethod = "DELETE"
            $absolutePath = "/projects/$projectCode"
            $script:Projects = @([PSCustomObject]@{ projectCode = $projectCode; projectName = "Existing"; archived = $false })
        }
        "restore" {
            $routePath = "app/backend/routes/projects/restore.routes.ps1"
            $httpMethod = "POST"
            $absolutePath = "/projects/$projectCode/restore"
            $script:Projects = @([PSCustomObject]@{ projectCode = $projectCode; projectName = "Existing"; archived = $true })
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

    return $script:CapturedMessage
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
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/seed.routes.ps1")
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
    Assert-Equal -Expected 1 -Actual $script:HistoryCallCount -Message "Approval should append one history record."
    Assert-Equal -Expected $false -Actual $script:LastHistoryPublishChange -Message "Approval history should defer to the employee publication."
    Assert-Equal -Expected "employee" -Actual $script:LastPublishCategory -Message "Approval published the wrong sync category."
    Assert-Equal -Expected "000000001" -Actual $script:LastPublishResource -Message "Approval published the wrong employee resource."
    Assert-Equal -Expected 0 -Actual $script:ActiveResourceLockCount -Message "Approval leaked its employee-file lock."
    Assert-Equal -Expected $false -Actual $script:PostCommitActionRanWhileLocked -Message "Approval ran history or sync publication while holding the employee-file lock."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Approval must report a committed mutation as success when history logging fails."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "approval history failure" -Message "Approval lost the history failure."

    Reset-ScenarioState
    $script:HistoryFailure = "approval primary failure"
    $script:PublishFailure = "approval publish failure"
    Invoke-ApprovalRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Approval should still attempt publication when history and publication both fail."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Approval must report a committed mutation as success when post-commit actions fail."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "approval primary failure" -Message "Approval publication failure masked the earlier history failure."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "approval publish failure" -Message "Approval lost the publication warning."

    Reset-ScenarioState
    $script:PublishFailure = "approval publish-only failure"
    Invoke-ApprovalRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Approval publication-only failure must not turn a committed mutation into an error."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "approval publish-only failure" -Message "Approval did not surface a publication-only failure."

    Reset-ScenarioState
    $script:WriteFailure = "approval write failure"
    Invoke-ApprovalRoute
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Approval must not publish when its primary write did not commit."

    Reset-ScenarioState
    $script:HistoryFailure = "add history failure"
    $addResult = Invoke-AddRouteScenario
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Add should publish after a committed mutation even when history fails."
    Assert-Equal -Expected 1 -Actual $script:HistoryCallCount -Message "Add should append one history record."
    Assert-Equal -Expected $false -Actual $script:LastHistoryPublishChange -Message "Add history should defer to the employee publication."
    Assert-Equal -Expected "employee" -Actual $script:LastPublishCategory -Message "Add published the wrong sync category."
    Assert-Equal -Expected "000000001" -Actual $script:LastPublishResource -Message "Add published the wrong employee resource."
    Assert-Equal -Expected 0 -Actual $script:ActiveResourceLockCount -Message "Add leaked its employee-file lock."
    Assert-Equal -Expected $false -Actual $script:PostCommitActionRanWhileLocked -Message "Add ran history or sync publication while holding a data-file lock."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Add must report a committed mutation as success when history logging fails."
    Assert-Contains -Value $addResult -ExpectedText "add history failure" -Message "Add lost the history failure."

    Reset-ScenarioState
    $script:HistoryFailure = "add primary failure"
    $script:PublishFailure = "add publish failure"
    $addResult = Invoke-AddRouteScenario
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Add must report a committed mutation as success when post-commit actions fail."
    Assert-Contains -Value $addResult -ExpectedText "add primary failure" -Message "Add lost the history warning."
    Assert-Contains -Value $addResult -ExpectedText "add publish failure" -Message "Add lost the publication warning."

    foreach ($operation in @("create", "update", "delete", "restore")) {
        Reset-ScenarioState
        $script:HistoryFailure = "$operation directory history failure"
        Invoke-DirectoryRoute -Operation $operation
        Assert-Equal -Expected 1 -Actual $script:DirectoryServiceCalls -Message "Directory $operation did not invoke its mutation service once."
        Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Directory $operation should publish after a committed mutation when history fails."
        Assert-Equal -Expected $false -Actual $script:LastHistoryPublishChange -Message "Directory $operation history should defer to the directory publication."
        Assert-Equal -Expected "employee-directory" -Actual $script:LastPublishCategory -Message "Directory $operation published the wrong category."
        Assert-Equal -Expected "000000001" -Actual $script:LastPublishResource -Message "Directory $operation published the wrong employee resource."
        Assert-Contains -Value $script:CapturedMessage -ExpectedText "$operation directory history failure" -Message "Directory $operation lost its history failure."
    }

    Reset-ScenarioState
    $script:DirectoryServiceFailure = "directory partial service failure"
    $script:PublishFailure = "directory publish failure"
    Invoke-DirectoryRoute -Operation "update"
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Directory update must not publish when its service did not report a committed mutation."
    Assert-Equal -Expected 500 -Actual $script:CapturedStatusCode -Message "Directory service failure should remain a pre-commit error."
    Assert-Equal -Expected "Unable to update employee." -Actual $script:CapturedMessage -Message "Directory update exposed its internal service exception."

    Reset-ScenarioState
    $script:PublishFailure = "directory publish-only failure"
    Invoke-DirectoryRoute -Operation "update"
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Directory publication-only failure must not turn a committed update into an error."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "directory publish-only failure" -Message "Directory did not surface a publication-only failure."

    Reset-ScenarioState
    $script:HistoryFailure = "auth history failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 1 -Actual $script:AuthUpdateCalls -Message "Password reset should invoke the auth mutation once."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Password reset should publish after a committed auth mutation when history fails."
    Assert-Equal -Expected $false -Actual $script:LastHistoryPublishChange -Message "Password history should defer to the auth publication."
    Assert-Equal -Expected "auth" -Actual $script:LastPublishCategory -Message "Password reset published the wrong category."
    Assert-Equal -Expected "000000001" -Actual $script:LastPublishResource -Message "Password reset published the wrong employee resource."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Password reset must report a committed password as success when history fails."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth history failure" -Message "Password reset lost the history failure."

    Reset-ScenarioState
    $script:HistoryFailure = "auth primary failure"
    $script:PublishFailure = "auth publish failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Password reset should attempt publication when history and publication both fail."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Password reset must remain successful after post-commit history and publication failures."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth primary failure" -Message "Auth publication failure masked the earlier history failure."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth publish failure" -Message "Password reset lost the publication warning."

    Reset-ScenarioState
    $script:SessionRevokeFailure = "session revoke failure"
    $script:PublishFailure = "auth publication after revoke failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Password reset should publish after the password commit when session revocation fails."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Password reset must remain successful after post-commit session-revocation and publication failures."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "session revoke failure" -Message "Auth publication failure masked the earlier session-revocation failure."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth publication after revoke failure" -Message "Password reset lost the publication warning after session revocation failed."

    Reset-ScenarioState
    $script:PublishFailure = "auth publish-only failure"
    Invoke-PasswordRoute
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Auth publication-only failure must not turn a committed password reset into an error."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth publish-only failure" -Message "Password reset did not surface a publication-only failure."

    Reset-ScenarioState
    $script:AuthUpdateResult = $false
    Invoke-PasswordRoute
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Password reset must not publish when the auth service reports no committed update."
    Assert-Equal -Expected 409 -Actual $script:CapturedStatusCode -Message "A structured employee-account conflict should return HTTP 409."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText "auth precommit failure" -Message "Password reset lost its precommit failure."

    Reset-ScenarioState
    $script:AuthUpdateFailure = "users path C:\secret\users.json could not be written"
    Invoke-PasswordRoute
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Password reset must not publish after an auth service exception."
    Assert-Equal -Expected 500 -Actual $script:CapturedStatusCode -Message "An auth service exception returned the wrong status."
    Assert-Equal -Expected "Unable to update employee password." -Actual $script:CapturedMessage -Message "Password reset exposed an internal auth service exception."

    foreach ($operation in @("add", "update", "delete", "restore")) {
        Reset-ScenarioState
        $script:HistoryFailure = "$operation project history failure"
        $projectResult = Invoke-ProjectRouteScenario -Operation $operation
        Assert-Equal -Expected 1 -Actual $script:WriteCount -Message "Project $operation should commit once before history fails (route result: $projectResult)."
        Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Project $operation should publish after its committed mutation when history fails."
        Assert-Equal -Expected 1 -Actual $script:LocalProjectCacheClearCount -Message "Project $operation should clear local caches after its committed mutation."
        Assert-Equal -Expected $false -Actual $script:LastHistoryPublishChange -Message "Project $operation history should defer to the project publication."
        Assert-Equal -Expected "project" -Actual $script:LastPublishCategory -Message "Project $operation published the wrong category."
        $expectedProjectResource = if ($operation -eq "add") { "P002" } else { "P001" }
        Assert-Equal -Expected $expectedProjectResource -Actual $script:LastPublishResource -Message "Project $operation published the wrong resource."
        Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Project $operation must report a committed mutation as success when history logging fails."
        Assert-Contains -Value $projectResult -ExpectedText "$operation project history failure" -Message "Project $operation lost its history failure."
    }

    Reset-ScenarioState
    $script:HistoryFailure = "project primary failure"
    $script:PublishFailure = "project publish failure"
    $projectResult = Invoke-ProjectRouteScenario -Operation "update"
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Project update should attempt publication when history and publication both fail."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Project update must report a committed mutation as success when post-commit actions fail."
    Assert-Contains -Value $projectResult -ExpectedText "project primary failure" -Message "Project update lost the history warning."
    Assert-Contains -Value $projectResult -ExpectedText "project publish failure" -Message "Project update lost the publication warning."

    Reset-ScenarioState
    $script:PublishFailure = "project publish-only failure"
    $projectResult = Invoke-ProjectRouteScenario -Operation "update"
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Project publication-only failure must not turn a committed mutation into an error."
    Assert-Contains -Value $projectResult -ExpectedText "project publish-only failure" -Message "Project update did not surface a publication-only failure."

    Reset-ScenarioState
    $script:PublishFailure = "restore publish-only failure"
    $restoreResult = Invoke-ProjectRouteScenario -Operation "restore"
    Assert-Equal -Expected 1 -Actual $script:WriteCount -Message "Project restore did not commit before its publication failure."
    Assert-Equal -Expected 1 -Actual $script:LocalProjectCacheClearCount -Message "Project restore did not invalidate local caches when publication failed."
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Project restore publication failure must not turn a committed restore into an error."
    Assert-Contains -Value $restoreResult -ExpectedText "restore publish-only failure" -Message "Project restore did not surface its publication warning."

    Reset-ScenarioState
    $script:WriteFailure = "project precommit failure"
    $projectFailure = Invoke-ProjectRouteScenario -Operation "update"
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Project update must not publish when its primary write did not commit."
    Assert-Contains -Value $projectFailure -ExpectedText "project precommit failure" -Message "Project update lost its precommit write failure."

    Reset-ScenarioState
    $script:WriteFailure = "restore precommit failure"
    $restoreFailure = Invoke-ProjectRouteScenario -Operation "restore"
    Assert-Equal -Expected 0 -Actual $script:LocalProjectCacheClearCount -Message "Project restore cleared caches despite a failed primary write."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Project restore must not publish when its primary write did not commit."
    Assert-Contains -Value $restoreFailure -ExpectedText "Unable to restore project." -Message "Project restore did not return its safe precommit failure response."

    Reset-ScenarioState
    $script:SeedServiceFailure = "seed partial failure"
    Invoke-SeedRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Seed should conservatively publish after a service failure that may follow partial writes."
    Assert-Equal -Expected "seed" -Actual $script:LastPublishCategory -Message "Seed fallback published the wrong category."
    Assert-Equal -Expected "*" -Actual $script:LastPublishResource -Message "Seed fallback should publish a wildcard resource."
    Assert-Equal -Expected "Unable to seed demo entries." -Actual $script:CapturedMessage -Message "Seed exposed its internal service exception."

    Reset-ScenarioState
    $script:SeedServiceFailure = "seed primary failure"
    $script:PublishFailure = "seed publish failure"
    Invoke-SeedRoute
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Seed should attempt fallback publication when the service and publication both fail."
    Assert-Equal -Expected "Unable to seed demo entries." -Actual $script:CapturedMessage -Message "Seed exposed internal service/publication exceptions."

    Reset-ScenarioState
    Invoke-SeedRoute
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "The seed route should not duplicate the service publication after a successful call."

    $sourceAssertions = @(
        [PSCustomObject]@{ Path = "app/backend/routes/employee/update.routes.ps1"; CommitVariable = 'entryMutationCommitted' },
        [PSCustomObject]@{ Path = "app/backend/routes/employee/delete.routes.ps1"; CommitVariable = 'entryMutationCommitted' }
    )
    foreach ($assertion in $sourceAssertions) {
        $source = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath $assertion.Path))
        Assert-Contains -Value $source -ExpectedText ('$' + $assertion.CommitVariable + ' = $true') -Message "$($assertion.Path) does not mark its successful primary write."
        Assert-Contains -Value $source -ExpectedText 'Invoke-PostCommitActionSafely' -Message "$($assertion.Path) does not isolate post-commit failures from the successful mutation."
        $commitIndex = $source.IndexOf(('$' + $assertion.CommitVariable + ' = $true'), [StringComparison]::Ordinal)
        $releaseIndex = $source.IndexOf('Release-ResourceLock -LockHandle $lockHandle', $commitIndex, [StringComparison]::Ordinal)
        $historyIndex = $source.IndexOf('logHistory ', $commitIndex, [StringComparison]::Ordinal)
        Assert-True -Condition ($commitIndex -ge 0 -and $releaseIndex -gt $commitIndex -and $historyIndex -gt $releaseIndex) -Message "$($assertion.Path) keeps its employee-file lock through history logging."
        Assert-Contains -Value $source -ExpectedText '-PublishChange:$false' -Message "$($assertion.Path) lets history logging duplicate its authoritative publication."
    }

    Write-Host "Route sync publication tests passed: post-commit failures are warnings while pre-commit failures remain errors."
}
finally {
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
}
