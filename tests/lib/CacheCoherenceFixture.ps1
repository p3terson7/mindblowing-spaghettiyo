param([string]$FixtureFolder, [switch]$Create, [int]$EmployeeCount = 3, [string]$ApplicationRoot = "")
$ErrorActionPreference = "Stop"
$fixtureRepo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:sharedFolder = $FixtureFolder
$script:lockFolder = Join-Path $FixtureFolder ".locks"
$script:SyncStateWatcherInitialized = $true
$script:AuthStorageEnsured = $true
$script:SyncStateValidationIntervalMs = 10000
foreach ($pair in @(
    @("usersFile", "users.json"), @("sessionsFile", "sessions.json"), @("projectsFile", "projects.json"),
    @("mappingFile", "employeeNames.json"), @("historyFile", "history.json"), @("syncStateFile", "sync-state.json"),
    @("overtimeCodesFile", "overtimeCodes.json"), @("paymentOptionsFile", "paymentOptions.json"), @("reasonCodesFile", "reasonCodes.json"),
    @("compensationGridFile", "compensation-grid.json"), @("budgetPeriodsFile", "budget-periods.json"), @("bugReportsFile", "bug-reports.json")
)) { Set-Variable -Scope Script -Name $pair[0] -Value (Join-Path $FixtureFolder $pair[1]) }
function Write-CoherenceFixtureJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 14), (New-Object Text.UTF8Encoding($false)))
}
if ($Create) {
    New-Item -ItemType Directory $FixtureFolder -Force | Out-Null
    $users = @([PSCustomObject]@{ username = "audit-super"; displayName = "Audit Supervisor"; role = "superAdmin"; disabled = $false },
        [PSCustomObject]@{ username = "audit-limited"; employeeCode = "000799999"; displayName = "Limited Supervisor"; role = "admin"; disabled = $false })
    $names = [ordered]@{}
    foreach ($index in 1..$EmployeeCount) {
        $code = "{0:000000000}" -f (710000 + $index)
        $names[$code] = "Employee $index"
        $users += [PSCustomObject]@{ username = $code; employeeCode = $code; displayName = "Employee $index"; role = "employee"; disabled = $false; timeEntryTypes = @("overtime"); gc179Profile = [PSCustomObject]@{ group = "CR"; subGroup = "04"; level = "01" } }
        Write-CoherenceFixtureJson (Join-Path $FixtureFolder "$($code)_data.json") @([PSCustomObject]@{
            entryId = "entry-$index"; date = (Get-Date -Format "yyyy-MM-01"); punchIn = "17:00:00"; punchOut = "18:00:00"; exactPunchIn = "17:00:00"; exactPunchOut = "18:00:00"; overtime = "01:00:00"; status = "pending"; entryType = "overtime"; projectCode = if ($index -eq 2) { "P2" } else { "P1" }; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular"; message = ""
        })
    }
    Write-CoherenceFixtureJson $usersFile $users
    Write-CoherenceFixtureJson $mappingFile ([PSCustomObject]$names)
    Write-CoherenceFixtureJson (Join-Path $FixtureFolder "000799999_data.json") @()
    Write-CoherenceFixtureJson $projectsFile @([PSCustomObject]@{ projectCode = "P1"; projectName = "Project 1"; admins = @("000799999"); backupAdmins = @(); archived = $false }, [PSCustomObject]@{ projectCode = "P2"; projectName = "Project 2"; admins = @(); backupAdmins = @(); archived = $false })
    foreach ($path in @($sessionsFile, $historyFile, $overtimeCodesFile, $paymentOptionsFile, $reasonCodesFile, $bugReportsFile)) { Write-CoherenceFixtureJson $path @() }
    Copy-Item (Join-Path $fixtureRepo "app/backend/defaults/compensation-grid.v1.json") $compensationGridFile
    Copy-Item (Join-Path $fixtureRepo "app/backend/defaults/budget-periods.v2.json") $budgetPeriodsFile
}
foreach ($file in @("lib/PerformanceTrace.ps1", "lib/FileStore.ps1", "lib/CommonHelpers.ps1", "services/AuthService.ps1", "services/EntryService.ps1", "services/ReadModelService.ps1", "services/EmployeeDirectoryService.ps1", "services/SyncService.ps1", "services/CompensationGridService.ps1", "services/OvertimeCostSnapshotService.ps1")) {
    $backendFile = if ($ApplicationRoot) { Join-Path $ApplicationRoot "backend/$file" } else { Join-Path $fixtureRepo "app/backend/$file" }
    . $backendFile
}

function Invoke-CoherenceFixtureMutation {
    param([string]$Code = "000710001", [string]$Operation = "modify", [switch]$WithoutPublication)
    if ($Operation -eq "failed-revoke") {
        function Publish-DataChange { param([string]$Category, [string]$Resource) throw "injected publication failure" }
        Revoke-SessionsForUsername -Username "audit-limited"
        return
    }
    if ($Operation -eq "revoke") { Revoke-SessionsForUsername -Username "audit-limited"; return }
    $path = if ($Operation -in @("disable", "permission")) { $usersFile } else { Join-Path $sharedFolder "$($Code)_data.json" }
    $lock = Acquire-ResourceLock $path
    try {
        $items = @(Read-JsonArrayFile $path)
        if ($Operation -eq "disable") { ($items | Where-Object username -eq "audit-limited").disabled = $true }
        elseif ($Operation -eq "permission") { ($items | Where-Object username -eq $Code).role = "admin" }
        elseif ($Operation -eq "add") { $new = $items[0].PSObject.Copy(); $new.entryId = "added-$([Guid]::NewGuid().ToString('N'))"; $items += $new }
        elseif ($Operation -eq "delete") { $items = @($items | Select-Object -Skip 1) }
        elseif ($Operation -eq "approve") { $items[0].status = "approved" }
        elseif ($Operation -eq "reject") { $items[0].status = "rejected" }
        elseif ($Operation -eq "reassign") { $items[0].projectCode = "P2" }
        else { $items[0].overtime = "02:00:00" }
        Write-JsonArrayAtomic -Path $path -Items $items -Depth 14
    } finally { Release-ResourceLock $lock }
    if (-not $WithoutPublication) {
        $category = if ($Operation -in @("disable", "permission")) { "auth" } else { "employee" }
        Publish-DataChange -Category $category -Resource $Code | Out-Null
    }
}
