$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/RouteDispatchService.ps1")

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

$topLevelCases = @(
    @("GET", "/", "routes/frontend.routes.ps1"),
    @("GET", "/scripts/AppShell.js", "routes/frontend.routes.ps1"),
    @("POST", "/auth/login", "routes/auth.routes.ps1"),
    @("GET", "/health", "routes/sync.routes.ps1"),
    @("GET", "/sync/status", "routes/sync.routes.ps1"),
    @("POST", "/seed/demo-entries", "routes/seed.routes.ps1"),
    @("GET", "/self/bootstrap", "routes/self.routes.ps1"),
    @("GET", "/history/recent", "routes/history.routes.ps1"),
    @("GET", "/dashboard/bootstrap", "routes/dashboard.routes.ps1"),
    @("GET", "/approvals/entries", "routes/dashboard.routes.ps1"),
    @("GET", "/review/bootstrap", "routes/dashboard.routes.ps1"),
    @("GET", "/employees", "routes/employee.routes.ps1"),
    @("GET", "/employee/000000001", "routes/employee.routes.ps1"),
    @("GET", "/projects", "routes/project.routes.ps1"),
    @("GET", "/stats/projects", "routes/project-stats.routes.ps1"),
    @("GET", "/unknown", "")
)

foreach ($case in $topLevelCases) {
    $actual = Resolve-AdminTopLevelRouteScript -Method $case[0] -Path $case[1]
    Assert-Equal -Expected $case[2] -Actual $actual -Message ("Top-level dispatch failed for {0} {1}." -f $case[0], $case[1])
}

$employeeCases = @(
    @("GET", "/employees", "routes/employee/list.routes.ps1"),
    @("GET", "/employees/bootstrap", "routes/employee/list.routes.ps1"),
    @("POST", "/employees", "routes/employee/create-record.routes.ps1"),
    @("PUT", "/employees/000000001", "routes/employee/update-record.routes.ps1"),
    @("DELETE", "/employees/000000001", "routes/employee/delete-record.routes.ps1"),
    @("POST", "/employees/000000001/restore", "routes/employee/restore-record.routes.ps1"),
    @("POST", "/employee/password/000000001", "routes/employee/password.routes.ps1"),
    @("GET", "/employee/000000001", "routes/employee/get.routes.ps1"),
    @("POST", "/employee/000000001/gc179-open", "routes/employee/get.routes.ps1"),
    @("POST", "/employee/add/000000001", "routes/employee/add.routes.ps1"),
    @("POST", "/employee/gc179-import/preview", "routes/employee/gc179-import.routes.ps1"),
    @("POST", "/employee/gc179-import/commit", "routes/employee/gc179-import.routes.ps1"),
    @("PUT", "/employee/000000001", "routes/employee/update.routes.ps1"),
    @("POST", "/employee/approval/batch", "routes/employee/batch-approval.routes.ps1"),
    @("POST", "/employee/approval/000000001", "routes/employee/approval.routes.ps1"),
    @("PUT", "/employee/message/000000001", "routes/employee/message.routes.ps1"),
    @("DELETE", "/employee/000000001", "routes/employee/delete.routes.ps1"),
    @("PATCH", "/employee/000000001", "")
)

$resolvedEmployeeScripts = @{}
foreach ($case in $employeeCases) {
    $actual = Resolve-EmployeeRouteScript -Method $case[0] -Path $case[1]
    Assert-Equal -Expected $case[2] -Actual $actual -Message ("Employee dispatch failed for {0} {1}." -f $case[0], $case[1])
    if (-not [string]::IsNullOrWhiteSpace([string]$actual)) {
        $resolvedEmployeeScripts[[string]$actual] = $true
    }
}
Assert-Equal -Expected 14 -Actual $resolvedEmployeeScripts.Count -Message "The employee resolver does not reach every leaf route script."

$projectCases = @(
    @("GET", "/projects", "routes/projects/get.routes.ps1"),
    @("GET", "/projects/", "routes/projects/get.routes.ps1"),
    @("GET", "/projects/bootstrap", "routes/projects/bootstrap.routes.ps1"),
    @("POST", "/projects", "routes/projects/add.routes.ps1"),
    @("PUT", "/projects/ABC-1", "routes/projects/update.routes.ps1"),
    @("DELETE", "/projects/ABC-1", "routes/projects/delete.routes.ps1")
)
foreach ($case in $projectCases) {
    $actual = Resolve-ProjectRouteScript -Method $case[0] -Path $case[1]
    Assert-Equal -Expected $case[2] -Actual $actual -Message ("Project dispatch failed for {0} {1}." -f $case[0], $case[1])
}

$statsCases = @(
    @("GET", "/stats/projects", "routes/stats/summary.routes.ps1"),
    @("GET", "/stats/projects/", "routes/stats/summary.routes.ps1"),
    @("GET", "/stats/projects/trends", "routes/stats/trends.routes.ps1"),
    @("GET", "/stats/projects/ABC-1", "routes/stats/detail.routes.ps1"),
    @("POST", "/stats/projects", "")
)
foreach ($case in $statsCases) {
    $actual = Resolve-ProjectStatsRouteScript -Method $case[0] -Path $case[1]
    Assert-Equal -Expected $case[2] -Actual $actual -Message ("Stats dispatch failed for {0} {1}." -f $case[0], $case[1])
}

$adminServerSource = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/admin-server.ps1"))
Assert-Equal -Expected 0 -Actual ([regex]::Matches($adminServerSource, '\$script:RouteScriptBlocks\["routes/').Count) -Message "The request loop should not invoke a hard-coded fan-out of top-level routes."
Assert-Equal -Expected 1 -Actual ([regex]::Matches($adminServerSource, 'Resolve-AdminTopLevelRouteScript').Count) -Message "The request loop should resolve one top-level route."

$employeeAggregatorSource = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee.routes.ps1"))
Assert-Equal -Expected 1 -Actual ([regex]::Matches($employeeAggregatorSource, 'Invoke-CachedRouteScript').Count) -Message "The employee aggregator should invoke only its resolved leaf route."

Write-Host "Route dispatch test passed: one top-level and one leaf handler are selected for every known request shape."
