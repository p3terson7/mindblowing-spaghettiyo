$ErrorActionPreference = "Stop"

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/EntryService.ps1")

$entry = [PSCustomObject]@{ message = "Legacy note" }
$manager = [PSCustomObject]@{
    displayName = "Marie Tremblay"
    username    = "mtremblay"
    role        = "admin"
}

Set-EntrySupervisorNote -Entry $entry -Note "  Entry checked with payroll.  " -CurrentUser $manager | Out-Null
Assert-Equal -Expected "Entry checked with payroll." -Actual $entry.message -Message "Supervisor-note text was not normalized."
Assert-Equal -Expected "Marie Tremblay" -Actual $entry.messageAuthorName -Message "Supervisor-note display-name attribution is missing."
Assert-Equal -Expected "mtremblay" -Actual $entry.messageAuthorUsername -Message "Supervisor-note username attribution is missing."
$parsedUpdatedAt = [DateTimeOffset]::MinValue
Assert-True -Condition ([DateTimeOffset]::TryParse([string]$entry.messageUpdatedAt, [ref]$parsedUpdatedAt)) -Message "Supervisor-note timestamp is not a valid date."
Assert-Equal -Expected ([TimeSpan]::Zero) -Actual $parsedUpdatedAt.Offset -Message "Supervisor-note timestamp must be recorded in UTC."

$usernameOnlyEntry = [PSCustomObject]@{}
Set-EntrySupervisorNote -Entry $usernameOnlyEntry -Note "Reviewed." -CurrentUser ([PSCustomObject]@{ username = "fallback.user" }) | Out-Null
Assert-Equal -Expected "fallback.user" -Actual $usernameOnlyEntry.messageAuthorName -Message "A missing display name did not fall back to the username."

Set-EntrySupervisorNote -Entry $entry -Note "   " -CurrentUser $manager | Out-Null
Assert-Equal -Expected "" -Actual $entry.message -Message "Clearing a supervisor note did not clear its text."
Assert-Equal -Expected "" -Actual $entry.messageAuthorName -Message "Clearing a supervisor note retained a misleading author name."
Assert-Equal -Expected "" -Actual $entry.messageAuthorUsername -Message "Clearing a supervisor note retained a misleading username."
Assert-Equal -Expected "" -Actual $entry.messageUpdatedAt -Message "Clearing a supervisor note retained a misleading timestamp."

$legacyProjection = Convert-ToNormalizedEntryObject -Entry ([PSCustomObject]@{
    entryId = "legacy-note"
    date = "2026-08-18"
    punchIn = "08:00:00"
    message = "A note written before attribution existed."
})
Assert-Equal -Expected "A note written before attribution existed." -Actual $legacyProjection.message -Message "Legacy note text was not preserved."
Assert-Equal -Expected "" -Actual $legacyProjection.messageAuthorName -Message "A legacy entry invented a supervisor name."
Assert-Equal -Expected "" -Actual $legacyProjection.messageAuthorUsername -Message "A legacy entry invented a supervisor username."
Assert-Equal -Expected "" -Actual $legacyProjection.messageUpdatedAt -Message "A legacy entry invented a note timestamp."

$approvalRoute = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/approval.routes.ps1") -Raw
$batchRoute = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/batch-approval.routes.ps1") -Raw
$messageRoute = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/message.routes.ps1") -Raw
$updateRoute = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/update.routes.ps1") -Raw
$addRoute = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/add.routes.ps1") -Raw
$deleteRoute = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/employee/delete.routes.ps1") -Raw
foreach ($routeContract in @($approvalRoute, $batchRoute, $messageRoute, $updateRoute, $addRoute)) {
    Assert-True -Condition ($routeContract -match "Set-EntrySupervisorNote") -Message "An entry-note mutation route bypasses supervisor attribution."
}
Assert-True -Condition ($deleteRoute -match 'logHistory\s+"Delete"') -Message "Deleted-entry notes must retain their author through audit history."

Write-Host "Supervisor-note attribution contracts passed."
