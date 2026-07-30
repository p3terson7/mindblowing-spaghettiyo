$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

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
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Assert-Contains {
    param(
        [string]$Value,
        [string]$ExpectedText,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Value -notlike "*$ExpectedText*") {
        throw ("{0} Expected '{1}' to contain '{2}'." -f $Message, $Value, $ExpectedText)
    }
}

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/EmployeeDirectoryService.ps1")

# Service contract fixtures. The auth/user mutation is canonical; all later
# mapping, entry-file, session, and display-name work is secondary.
$script:ServiceCalls = New-Object System.Collections.ArrayList
$script:CanonicalUpdateResult = $true
$script:MappingFailure = ""
$script:DataFileFailure = ""
$script:EntryNameFailure = ""
$script:SessionFailure = ""

function Reset-ServiceScenario {
    $script:ServiceCalls = New-Object System.Collections.ArrayList
    $script:CanonicalUpdateResult = $true
    $script:MappingFailure = ""
    $script:DataFileFailure = ""
    $script:EntryNameFailure = ""
    $script:SessionFailure = ""
}

function Ensure-EmployeeUser {
    param(
        [string]$EmployeeCode,
        [string]$DisplayName,
        [string]$InitialPassword,
        [bool]$MustChangePassword,
        [string]$Role,
        $TimeEntryTypes,
        $Gc179Profile
    )
    [void]$script:ServiceCalls.Add("canonical-create")
    return [PSCustomObject]@{
        updated = $script:CanonicalUpdateResult
        created = $script:CanonicalUpdateResult
        reactivated = $false
        error = if ($script:CanonicalUpdateResult) { $null } else { "canonical create failed" }
        temporaryPassword = "Temporary!123"
    }
}

function Set-EmployeeUserProfile {
    param(
        [string]$EmployeeCode,
        [string]$DisplayName,
        [string]$Role,
        $TimeEntryTypes,
        $Gc179Profile
    )
    [void]$script:ServiceCalls.Add("canonical-update")
    return [bool]$script:CanonicalUpdateResult
}

function Disable-EmployeeUser {
    param([string]$EmployeeCode)
    [void]$script:ServiceCalls.Add("canonical-delete")
    return [bool]$script:CanonicalUpdateResult
}

function Restore-EmployeeUser {
    param([string]$EmployeeCode)
    [void]$script:ServiceCalls.Add("canonical-restore")
    return [bool]$script:CanonicalUpdateResult
}

function Set-EmployeeDirectoryNameMapping {
    param([string]$EmployeeCode, [string]$DisplayName)
    [void]$script:ServiceCalls.Add("mapping")
    if (-not [string]::IsNullOrWhiteSpace($script:MappingFailure)) {
        throw $script:MappingFailure
    }
}

function Ensure-EmployeeDataFile {
    param([string]$EmployeeCode)
    [void]$script:ServiceCalls.Add("data-file")
    if (-not [string]::IsNullOrWhiteSpace($script:DataFileFailure)) {
        throw $script:DataFileFailure
    }
    return "$EmployeeCode`_data.json"
}

function Update-EmployeeEntryDisplayName {
    param([string]$EmployeeCode, [string]$DisplayName)
    [void]$script:ServiceCalls.Add("entry-names")
    if (-not [string]::IsNullOrWhiteSpace($script:EntryNameFailure)) {
        throw $script:EntryNameFailure
    }
    return 0
}

function Revoke-SessionsForUsername {
    param([string]$Username)
    [void]$script:ServiceCalls.Add("sessions")
    if (-not [string]::IsNullOrWhiteSpace($script:SessionFailure)) {
        throw $script:SessionFailure
    }
}

Reset-ServiceScenario
$script:MappingFailure = "mapping fixture failure"
$script:DataFileFailure = "data fixture failure"
$script:EntryNameFailure = "entry-name fixture failure"
$createServiceResult = Add-EmployeeDirectoryRecord -EmployeeCode "000000001" -DisplayName "Employee One" -InitialPassword "Temporary!123"
Assert-True -Condition ([bool]$createServiceResult.updated) -Message "A committed account creation was reported as failed after secondary failures."
Assert-Equal -Expected 3 -Actual @($createServiceResult.warnings).Count -Message "Create did not report every secondary failure."
Assert-Equal -Expected "canonical-create" -Actual ([string]$script:ServiceCalls[0]) -Message "Create attempted secondary state before the canonical account write."
Assert-Equal -Expected "canonical-create,mapping,data-file,entry-names" -Actual (@($script:ServiceCalls) -join ",") -Message "Create stopped repairing secondary state after the first failure."

Reset-ServiceScenario
$script:MappingFailure = "mapping update fixture failure"
$script:EntryNameFailure = "entry update fixture failure"
$updateServiceResult = Update-EmployeeDirectoryRecord -EmployeeCode "000000001" -DisplayName "Employee Renamed" -Role "employee"
Assert-True -Condition ([bool]$updateServiceResult.updated) -Message "A committed profile update was reported as failed after secondary failures."
Assert-Equal -Expected 2 -Actual @($updateServiceResult.warnings).Count -Message "Update did not report every secondary failure."
Assert-Equal -Expected "canonical-update,mapping,entry-names" -Actual (@($script:ServiceCalls) -join ",") -Message "Update did not commit the account before repairing secondary state."

Reset-ServiceScenario
$script:CanonicalUpdateResult = $false
$failedUpdateResult = Update-EmployeeDirectoryRecord -EmployeeCode "000000001" -DisplayName "Not Saved"
Assert-True -Condition (-not [bool]$failedUpdateResult.updated) -Message "A failed canonical profile update was reported as committed."
Assert-Equal -Expected "canonical-update" -Actual (@($script:ServiceCalls) -join ",") -Message "Update changed secondary state after the canonical mutation failed."

Reset-ServiceScenario
$script:SessionFailure = "session fixture failure"
$deleteServiceResult = Remove-EmployeeDirectoryRecord -EmployeeCode "000000001"
Assert-True -Condition ([bool]$deleteServiceResult.updated) -Message "A disabled account was reported as active after session cleanup failed."
Assert-Equal -Expected 1 -Actual @($deleteServiceResult.warnings).Count -Message "Delete lost its session-revocation warning."
Assert-Equal -Expected "canonical-delete,sessions" -Actual (@($script:ServiceCalls) -join ",") -Message "Delete did not disable the account before revoking sessions."

Reset-ServiceScenario
$script:DataFileFailure = "restore data fixture failure"
$restoreServiceResult = Restore-EmployeeDirectoryRecord -EmployeeCode "000000001"
Assert-True -Condition ([bool]$restoreServiceResult.updated) -Message "A restored account was reported as archived after data initialization failed."
Assert-Equal -Expected 1 -Actual @($restoreServiceResult.warnings).Count -Message "Restore lost its data-file warning."
Assert-Equal -Expected "canonical-restore,data-file" -Actual (@($script:ServiceCalls) -join ",") -Message "Restore did not activate the account before initializing secondary data."

# Route contract fixtures. Service warnings, history, and publication are all
# post-commit outcomes and must be returned with HTTP 200.
$script:RouteOperation = ""
$script:RouteExistingState = "active"
$script:RouteServiceFailure = ""
$script:RouteServiceUpdated = $true
$script:RouteServiceWarnings = @()
$script:RouteServiceCalls = 0
$script:RouteHistoryCalls = 0
$script:RouteHistoryFailure = ""
$script:RoutePublishCalls = 0
$script:RoutePublishFailure = ""
$script:CapturedStatusCode = 0
$script:CapturedMessage = ""
$script:RequestPayload = $null
$currentUser = [PSCustomObject]@{ username = "super"; role = "super-admin" }

function Reset-RouteScenario {
    $script:RouteExistingState = "active"
    $script:RouteServiceFailure = ""
    $script:RouteServiceUpdated = $true
    $script:RouteServiceWarnings = @()
    $script:RouteServiceCalls = 0
    $script:RouteHistoryCalls = 0
    $script:RouteHistoryFailure = ""
    $script:RoutePublishCalls = 0
    $script:RoutePublishFailure = ""
    $script:CapturedStatusCode = 0
    $script:CapturedMessage = ""
}

function Test-CurrentUserSuperAdmin { param($CurrentUser) return $true }
function Read-JsonRequestBody { param($Request) return $script:RequestPayload }
function Get-NormalizedRoleName { param([string]$Role) return $Role }
function ConvertTo-TimeEntryTypeArray { param($Value) return @($Value) }
function Get-EmployeeDirectoryRecordMetadata {
    param([string]$EmployeeCode, [bool]$IncludeDisabled = $false)

    if ($script:RouteExistingState -eq "missing") {
        return $null
    }
    if ($script:RouteExistingState -eq "archived" -and -not $IncludeDisabled) {
        return $null
    }
    return [PSCustomObject]@{
        code = $EmployeeCode
        name = "Directory Employee"
        archived = ($script:RouteExistingState -eq "archived")
    }
}

function Invoke-RouteDirectoryService {
    $script:RouteServiceCalls++
    if (-not [string]::IsNullOrWhiteSpace($script:RouteServiceFailure)) {
        throw $script:RouteServiceFailure
    }
    return [PSCustomObject]@{
        updated = [bool]$script:RouteServiceUpdated
        error = if ($script:RouteServiceUpdated) { $null } else { "canonical fixture failure" }
        created = ($script:RouteOperation -eq "create")
        reactivated = $false
        temporaryPassword = "Temporary!123"
        warnings = @($script:RouteServiceWarnings)
    }
}

function Add-EmployeeDirectoryRecord {
    param([string]$EmployeeCode, [string]$DisplayName, [string]$InitialPassword, [bool]$MustChangePassword, [string]$Role, $TimeEntryTypes, $Gc179Profile)
    return (Invoke-RouteDirectoryService)
}
function Update-EmployeeDirectoryRecord {
    param([string]$EmployeeCode, [string]$DisplayName, [string]$Role, $TimeEntryTypes, $Gc179Profile)
    return (Invoke-RouteDirectoryService)
}
function Remove-EmployeeDirectoryRecord {
    param([string]$EmployeeCode)
    return (Invoke-RouteDirectoryService)
}
function Restore-EmployeeDirectoryRecord {
    param([string]$EmployeeCode)
    return (Invoke-RouteDirectoryService)
}

function logHistory {
    param(
        [string]$Action,
        [string]$Message,
        [string]$EmployeeName,
        [bool]$PublishChange = $true
    )
    $script:RouteHistoryCalls++
    if (-not [string]::IsNullOrWhiteSpace($script:RouteHistoryFailure)) {
        throw $script:RouteHistoryFailure
    }
}

function Publish-DataChange {
    param([string]$Category, [string]$Resource)
    $script:RoutePublishCalls++
    if (-not [string]::IsNullOrWhiteSpace($script:RoutePublishFailure)) {
        throw $script:RoutePublishFailure
    }
}

function Invoke-PostCommitActionSafely {
    param([string]$Description, [scriptblock]$Action)

    try {
        & $Action | Out-Null
        return ""
    }
    catch {
        return "$Description`: $($_.Exception.Message)"
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

function Invoke-EmployeeDirectoryRoute {
    param([Parameter(Mandatory = $true)][string]$Operation)

    $script:RouteOperation = $Operation
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
        default {
            throw "Unknown employee-directory operation '$Operation'."
        }
    }

    $script:RequestPayload = [PSCustomObject]@{
        code = $employeeCode
        name = "Directory Employee"
        role = "employee"
        timeEntryTypes = @("overtime")
        initialPassword = "Temporary!123"
        mustChangePassword = $true
    }
    $request = [PSCustomObject]@{
        HttpMethod = $httpMethod
        Url = [PSCustomObject]@{ AbsolutePath = $absolutePath }
    }
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath $routePath)
    }
}

foreach ($operation in @("create", "update", "delete", "restore")) {
    Reset-RouteScenario
    $script:RouteExistingState = if ($operation -eq "create") { "missing" } elseif ($operation -eq "restore") { "archived" } else { "active" }
    $script:RouteServiceWarnings = @("$operation secondary warning")
    $script:RouteHistoryFailure = "$operation history warning"
    $script:RoutePublishFailure = "$operation publication warning"
    Invoke-EmployeeDirectoryRoute -Operation $operation

    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Directory $operation returned a false error after its canonical mutation."
    Assert-Equal -Expected 1 -Actual $script:RouteServiceCalls -Message "Directory $operation did not invoke its canonical service once."
    Assert-Equal -Expected 1 -Actual $script:RouteHistoryCalls -Message "Directory $operation did not attempt history after the canonical mutation."
    Assert-Equal -Expected 1 -Actual $script:RoutePublishCalls -Message "Directory $operation did not attempt publication after the canonical mutation."
    $routeResult = $script:CapturedMessage | ConvertFrom-Json
    Assert-Equal -Expected 3 -Actual @($routeResult.warnings).Count -Message "Directory $operation did not return all post-commit warnings."
    Assert-Contains -Value (@($routeResult.warnings) -join " ") -ExpectedText "$operation secondary warning" -Message "Directory $operation lost the service warning."
    Assert-Contains -Value (@($routeResult.warnings) -join " ") -ExpectedText "$operation history warning" -Message "Directory $operation lost the history warning."
    Assert-Contains -Value (@($routeResult.warnings) -join " ") -ExpectedText "$operation publication warning" -Message "Directory $operation lost the publication warning."
}

Reset-RouteScenario
$script:RouteExistingState = "active"
$script:RouteServiceFailure = "canonical update fixture failure"
Invoke-EmployeeDirectoryRoute -Operation "update"
Assert-Equal -Expected 500 -Actual $script:CapturedStatusCode -Message "A canonical update failure was incorrectly reported as committed."
Assert-Equal -Expected "Unable to update employee." -Actual $script:CapturedMessage -Message "A canonical update exception leaked internal details to the client."
Assert-Equal -Expected 0 -Actual $script:RouteHistoryCalls -Message "A canonical update failure wrote history."
Assert-Equal -Expected 0 -Actual $script:RoutePublishCalls -Message "A canonical update failure published a change."

Reset-RouteScenario
$script:RouteExistingState = "archived"
Invoke-EmployeeDirectoryRoute -Operation "delete"
$deleteRetryResult = $script:CapturedMessage | ConvertFrom-Json
Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Retrying an already-archived delete did not succeed."
Assert-True -Condition ([bool]$deleteRetryResult.alreadyArchived) -Message "Delete retry did not identify its idempotent path."
Assert-Equal -Expected 0 -Actual $script:RouteHistoryCalls -Message "Delete retry duplicated its history entry."
Assert-Equal -Expected 1 -Actual $script:RoutePublishCalls -Message "Delete retry did not publish repaired state."

Reset-RouteScenario
$script:RouteExistingState = "active"
Invoke-EmployeeDirectoryRoute -Operation "restore"
$restoreRetryResult = $script:CapturedMessage | ConvertFrom-Json
Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "Retrying an already-active restore did not succeed."
Assert-True -Condition ([bool]$restoreRetryResult.alreadyActive) -Message "Restore retry did not identify its idempotent path."
Assert-Equal -Expected 0 -Actual $script:RouteHistoryCalls -Message "Restore retry duplicated its history entry."
Assert-Equal -Expected 1 -Actual $script:RoutePublishCalls -Message "Restore retry did not publish repaired state."

Reset-RouteScenario
$script:RouteExistingState = "active"
Invoke-EmployeeDirectoryRoute -Operation "create"
Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Create unsafely replayed an existing account without an idempotency key."
Assert-Equal -Expected 0 -Actual $script:RouteServiceCalls -Message "Create changed an existing account during an ambiguous retry."

Write-Host "Employee-directory commit contract tests passed: canonical writes survive secondary failures, and delete/restore retries are idempotent."
