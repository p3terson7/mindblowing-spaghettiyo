$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$routingManifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.Routing.psd1"
$routingFacadePath = Join-Path -Path $backendRoot -ChildPath "services/RouteDispatchService.ps1"

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
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Assert-StringSequenceEqual {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-Equal -Expected $Expected.Count -Actual $Actual.Count -Message ("{0} Item count changed." -f $Message)
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal -Expected $Expected[$index] -Actual $Actual[$index] -Message ("{0} Item {1} changed." -f $Message, $index)
    }
}

Assert-True -Condition (Test-Path -LiteralPath $routingManifestPath -PathType Leaf) -Message "The routing module manifest is missing."
Assert-True -Condition (Test-Path -LiteralPath $routingFacadePath -PathType Leaf) -Message "The route-dispatch compatibility facade is missing."

$manifest = Import-PowerShellDataFile -LiteralPath $routingManifestPath
Assert-Equal -Expected "Saphir.Routing.psm1" -Actual ([string]$manifest.RootModule) -Message "The routing manifest RootModule changed."
Assert-Equal -Expected "1.0.0" -Actual ([string]$manifest.ModuleVersion) -Message "The routing module version changed unexpectedly."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "The routing module no longer declares Windows PowerShell 5.1 compatibility."

$expectedExports = @(
    "Get-AdminRouteScriptPaths",
    "Resolve-AdminTopLevelRouteScript",
    "Resolve-EmployeeRouteScript",
    "Resolve-ProjectRouteScript",
    "Resolve-ProjectStatsRouteScript"
) | Sort-Object
Assert-StringSequenceEqual -Expected $expectedExports -Actual @($manifest.FunctionsToExport | Sort-Object) -Message "The routing manifest's explicit function exports changed."
Assert-Equal -Expected 0 -Actual @($manifest.CmdletsToExport).Count -Message "The pure routing module must not export cmdlets."
Assert-Equal -Expected 0 -Actual @($manifest.VariablesToExport).Count -Message "The pure routing module must not export variables."
Assert-Equal -Expected 0 -Actual @($manifest.AliasesToExport).Count -Message "The pure routing module must not export aliases."

. $routingFacadePath

$routingModule = Get-Module -Name "Saphir.Routing" | Select-Object -First 1
Assert-True -Condition ($null -ne $routingModule) -Message "The compatibility facade did not import the routing module."
Assert-StringSequenceEqual -Expected $expectedExports -Actual @($routingModule.ExportedFunctions.Keys | Sort-Object) -Message "The routing module's runtime exports changed."

$expectedRouteScripts = @(
    "routes/frontend.routes.ps1",
    "routes/auth.routes.ps1",
    "routes/sync.routes.ps1",
    "routes/seed.routes.ps1",
    "routes/self.routes.ps1",
    "routes/history.routes.ps1",
    "routes/dashboard.routes.ps1",
    "routes/employee.routes.ps1",
    "routes/employee/list.routes.ps1",
    "routes/employee/create-record.routes.ps1",
    "routes/employee/update-record.routes.ps1",
    "routes/employee/delete-record.routes.ps1",
    "routes/employee/restore-record.routes.ps1",
    "routes/employee/password.routes.ps1",
    "routes/employee/get.routes.ps1",
    "routes/employee/add.routes.ps1",
    "routes/employee/gc179-import.routes.ps1",
    "routes/employee/update.routes.ps1",
    "routes/employee/batch-approval.routes.ps1",
    "routes/employee/approval.routes.ps1",
    "routes/employee/message.routes.ps1",
    "routes/employee/delete.routes.ps1",
    "routes/project.routes.ps1",
    "routes/projects/get.routes.ps1",
    "routes/projects/bootstrap.routes.ps1",
    "routes/projects/add.routes.ps1",
    "routes/projects/restore.routes.ps1",
    "routes/projects/update.routes.ps1",
    "routes/projects/delete.routes.ps1",
    "routes/project-stats.routes.ps1",
    "routes/stats/analytics-export.routes.ps1",
    "routes/stats/summary.routes.ps1",
    "routes/stats/trends.routes.ps1",
    "routes/stats/detail.routes.ps1"
)

$routeCatalog = @(Get-AdminRouteScriptPaths)
$moduleRouteCatalog = @(Saphir.Routing\Get-AdminRouteScriptPaths)
Assert-StringSequenceEqual -Expected $expectedRouteScripts -Actual $routeCatalog -Message "The facade route catalog or its preload order changed."
Assert-StringSequenceEqual -Expected $expectedRouteScripts -Actual $moduleRouteCatalog -Message "The module route catalog or its preload order changed."
Assert-Equal -Expected $routeCatalog.Count -Actual @($routeCatalog | Sort-Object -Unique).Count -Message "The route catalog contains duplicate scripts."
foreach ($relativeRoutePath in $routeCatalog) {
    $absoluteRoutePath = Join-Path -Path $backendRoot -ChildPath $relativeRoutePath
    Assert-True -Condition (Test-Path -LiteralPath $absoluteRoutePath -PathType Leaf) -Message "The route catalog references a missing script: $relativeRoutePath"
}

$resolvedRouteScripts = @{}
function Assert-ResolverCase {
    param(
        [Parameter(Mandatory = $true)][string]$ResolverName,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $arguments = @{
        Method = $Method
        Path   = $Path
    }
    $facadeCommand = Get-Command -Name $ResolverName -CommandType Function -ErrorAction Stop
    $moduleCommandName = "Saphir.Routing\{0}" -f $ResolverName
    $facadeActual = & $facadeCommand @arguments
    $moduleActual = & $moduleCommandName @arguments

    Assert-Equal -Expected $Expected -Actual $facadeActual -Message ("{0} facade failed for {1} {2}." -f $Label, $Method, $Path)
    Assert-Equal -Expected $Expected -Actual $moduleActual -Message ("{0} module failed for {1} {2}." -f $Label, $Method, $Path)
    Assert-Equal -Expected $moduleActual -Actual $facadeActual -Message ("{0} facade/module equivalence failed for {1} {2}." -f $Label, $Method, $Path)

    if (-not [string]::IsNullOrWhiteSpace([string]$facadeActual)) {
        $script:resolvedRouteScripts[[string]$facadeActual] = $true
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
    @("POST", "/", ""),
    @("GET", "/employeeish/000000001", ""),
    @("GET", "/unknown", "")
)
foreach ($case in $topLevelCases) {
    Assert-ResolverCase -ResolverName "Resolve-AdminTopLevelRouteScript" -Method $case[0] -Path $case[1] -Expected $case[2] -Label "Top-level dispatch"
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
    @("POST", "/employee/gc179-import/undo", "routes/employee/gc179-import.routes.ps1"),
    @("PUT", "/employee/000000001", "routes/employee/update.routes.ps1"),
    @("POST", "/employee/approval/batch", "routes/employee/batch-approval.routes.ps1"),
    @("POST", "/employee/approval/000000001", "routes/employee/approval.routes.ps1"),
    @("PUT", "/employee/message/000000001", "routes/employee/message.routes.ps1"),
    @("DELETE", "/employee/000000001", "routes/employee/delete.routes.ps1"),
    @("PATCH", "/employee/000000001", ""),
    @("GET", "/employees/not-a-code", ""),
    @("POST", "/employee/gc179-import/unknown", "")
)
foreach ($case in $employeeCases) {
    Assert-ResolverCase -ResolverName "Resolve-EmployeeRouteScript" -Method $case[0] -Path $case[1] -Expected $case[2] -Label "Employee dispatch"
}

$projectCases = @(
    @("GET", "/projects", "routes/projects/get.routes.ps1"),
    @("GET", "/projects/", "routes/projects/get.routes.ps1"),
    @("GET", "/projects/bootstrap", "routes/projects/bootstrap.routes.ps1"),
    @("POST", "/projects", "routes/projects/add.routes.ps1"),
    @("POST", "/projects/ABC-1/restore", "routes/projects/restore.routes.ps1"),
    @("PUT", "/projects/ABC-1", "routes/projects/update.routes.ps1"),
    @("DELETE", "/projects/ABC-1", "routes/projects/delete.routes.ps1"),
    @("PATCH", "/projects/ABC-1", ""),
    @("POST", "/projects/ABC-1/unknown", "")
)
foreach ($case in $projectCases) {
    Assert-ResolverCase -ResolverName "Resolve-ProjectRouteScript" -Method $case[0] -Path $case[1] -Expected $case[2] -Label "Project dispatch"
}

$statsCases = @(
    @("GET", "/stats/analytics-export", "routes/stats/analytics-export.routes.ps1"),
    @("GET", "/stats/projects", "routes/stats/summary.routes.ps1"),
    @("GET", "/stats/projects/", "routes/stats/summary.routes.ps1"),
    @("GET", "/stats/projects/trends", "routes/stats/trends.routes.ps1"),
    @("GET", "/stats/projects/ABC-1", "routes/stats/detail.routes.ps1"),
    @("POST", "/stats/projects", ""),
    @("POST", "/stats/analytics-export", ""),
    @("GET", "/stats/projects/trends/extra", ""),
    @("GET", "/stats/unknown", "")
)
foreach ($case in $statsCases) {
    Assert-ResolverCase -ResolverName "Resolve-ProjectStatsRouteScript" -Method $case[0] -Path $case[1] -Expected $case[2] -Label "Stats dispatch"
}

Assert-Equal -Expected $routeCatalog.Count -Actual $script:resolvedRouteScripts.Count -Message "The resolver cases do not reach every catalogued route script."
foreach ($relativeRoutePath in $routeCatalog) {
    Assert-True -Condition $script:resolvedRouteScripts.ContainsKey($relativeRoutePath) -Message "No resolver case reaches the catalogued route script: $relativeRoutePath"
}

$adminServerSource = [System.IO.File]::ReadAllText((Join-Path -Path $backendRoot -ChildPath "saphir-server.ps1"))
$remainingServerRoutePaths = @([regex]::Matches($adminServerSource, '"(routes/[^"\r\n]+\.ps1)"') | ForEach-Object { $_.Groups[1].Value })
Assert-StringSequenceEqual `
    -Expected @("routes/frontend.routes.ps1", "routes/auth.routes.ps1") `
    -Actual $remainingServerRoutePaths `
    -Message "The admin server should retain only the two password-gate route comparisons outside the preload catalog."
Assert-Equal -Expected 1 -Actual ([regex]::Matches($adminServerSource, 'Get-AdminRouteScriptPaths').Count) -Message "The admin server should preload routes from the catalog exactly once."
Assert-Equal -Expected 1 -Actual ([regex]::Matches($adminServerSource, 'Register-RouteScriptBlock\s+-RelativePath\s+\$_').Count) -Message "The admin server should register each catalogued route through one preload loop."
Assert-Equal -Expected 0 -Actual ([regex]::Matches($adminServerSource, '\$script:RouteScriptBlocks\["routes/').Count) -Message "The request loop should not invoke a hard-coded fan-out of top-level routes."
Assert-Equal -Expected 1 -Actual ([regex]::Matches($adminServerSource, 'Resolve-AdminTopLevelRouteScript').Count) -Message "The request loop should resolve one top-level route."

$employeeAggregatorSource = [System.IO.File]::ReadAllText((Join-Path -Path $backendRoot -ChildPath "routes/employee.routes.ps1"))
Assert-Equal -Expected 1 -Actual ([regex]::Matches($employeeAggregatorSource, 'Invoke-CachedRouteScript').Count) -Message "The employee aggregator should invoke only its resolved leaf route."

Write-Host "Route dispatch test passed: the PS5.1 module, compatibility facade, ordered 34-route catalog, and all known/unknown dispatch cases agree."
