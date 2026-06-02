param(
    [int]$MinimumEntriesPerEmployee = 4,
    [int]$MaximumEntriesPerEmployee = 8,
    [int]$MonthsBack = 6
)

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptDir = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend"

. (Join-Path -Path $scriptDir -ChildPath "lib/AdminContext.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/CommonHelpers.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/FileStore.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/ResponseHelpers.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/AuthService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/EntryService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/ReadModelService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/EmployeeDirectoryService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/SyncService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/ProjectStatsService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/HistoryService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/SeedService.ps1")

$currentUser = [PSCustomObject]@{
    username = "seed-script"
    displayName = "Seed Script"
    role = "superAdmin"
    employeeCode = ""
}

$result = New-DemoOvertimeEntries -CurrentUser $currentUser -MinimumEntriesPerEmployee $MinimumEntriesPerEmployee -MaximumEntriesPerEmployee $MaximumEntriesPerEmployee -MonthsBack $MonthsBack
$result | ConvertTo-Json -Depth 8
