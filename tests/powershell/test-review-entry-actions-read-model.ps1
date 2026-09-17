$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/CommonHelpers.ps1")
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/EntryService.ps1")

# ReadModelService consumes the authentication role normalizer, but this
# focused projection test intentionally avoids initializing the auth store.
function Get-NormalizedRoleName {
    param([string]$Role)
    $normalized = ([string]$Role).Trim().ToLowerInvariant().Replace("_", "").Replace("-", "")
    if ($normalized -eq "superadmin") { return "superAdmin" }
    if ($normalized -eq "admin") { return "admin" }
    return "employee"
}

. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/ReadModelService.ps1")

$entry = [PSCustomObject]@{
    entryId       = "entry-review-actions"
    entryType     = "overtime"
    date          = "2026-08-12"
    punchIn       = "17:00:00"
    exactPunchIn  = "17:03:00"
    punchOut      = "19:00:00"
    exactPunchOut = "19:07:00"
    overtime      = "02:00:00"
    status        = "pending"
    message       = "Ready for review"
    messageAuthorName = "Test Supervisor"
    messageAuthorUsername = "supervisor"
    messageUpdatedAt = "2026-08-12T20:00:00.0000000Z"
    projectCode   = "P001"
    overtimeCode  = "260"
    paymentOption = "cash"
    reasonCode    = "D"
    workComment   = "Prepared the briefing"
}

$editableProjectSet = @{ "P001" = $true }
$editable = New-EmployeeEntryProjectionForAccessModel `
    -EmployeeCode "000100001" `
    -EmployeeName "Demo Employee" `
    -Entry $entry `
    -ModifyProjectCodeSet $editableProjectSet

Assert-True -Condition ([bool]$editable.canModify) -Message "An editable Review entry lost its shared modification permission."
Assert-True -Condition ([bool]$editable.canApprove) -Message "An editable employee entry lost approval permission."
Assert-Equal -Expected "entry-review-actions" -Actual $editable.entryId -Message "The stable entry identifier was not projected."
Assert-Equal -Expected "17:03:00" -Actual $editable.exactPunchIn -Message "The exact start time required by the shared editor was not projected."
Assert-Equal -Expected "19:07:00" -Actual $editable.exactPunchOut -Message "The exact end time required by the shared editor was not projected."
Assert-Equal -Expected "Prepared the briefing" -Actual $editable.workComment -Message "The employee comment required by the shared editor was not projected."
Assert-Equal -Expected "Ready for review" -Actual $editable.message -Message "The supervisor note required by the shared editor was not projected."
Assert-Equal -Expected "Test Supervisor" -Actual $editable.messageAuthorName -Message "The supervisor-note author name was not projected."
Assert-Equal -Expected "supervisor" -Actual $editable.messageAuthorUsername -Message "The supervisor-note author username was not projected."
Assert-Equal -Expected "2026-08-12T20:00:00.0000000Z" -Actual $editable.messageUpdatedAt -Message "The supervisor-note update timestamp was not projected."

$readOnly = New-EmployeeEntryProjectionForAccessModel `
    -EmployeeCode "000100001" `
    -EmployeeName "Demo Employee" `
    -Entry $entry `
    -ModifyProjectCodeSet @{}
Assert-True -Condition (-not [bool]$readOnly.canModify) -Message "Review granted edit/delete outside the current user's project scope."
Assert-Equal -Expected "readOnlyProject" -Actual $readOnly.permissionReason -Message "The read-only explanation diverged from the employee file."

$diverseForSuperAdmin = $entry.PSObject.Copy()
$diverseForSuperAdmin.entryType = "diverse"
$diverseForSuperAdmin.projectCode = ""
$superAdminProjection = New-EmployeeEntryProjectionForAccessModel `
    -EmployeeCode "000100001" `
    -EmployeeName "Demo Employee" `
    -Entry $diverseForSuperAdmin `
    -ModifyProjectCodeSet @{} `
    -IsSuperAdmin:$true
Assert-True -Condition ([bool]$superAdminProjection.canModify) -Message "Super admins must retain management access to Diverse entries in Review."

Write-Host "Review entry action read-model contracts passed."
