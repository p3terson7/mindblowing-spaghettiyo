$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$frontendRoot = Join-Path -Path $repoRoot -ChildPath "app/frontend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.UserAccessProfile.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.UserAccessProfile.psm1"
$authServicePath = Join-Path -Path $backendRoot -ChildPath "services/AuthService.ps1"
$utilitiesPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Utilities.js"
$dashboardPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/DashboardView.js"
$historyPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/HistoryView.js"
$employeesPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/EmployeesView.js"
$projectsPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/ProjectsView.js"
$indexPath = Join-Path -Path $frontendRoot -ChildPath "index.html"
$appShellPath = Join-Path -Path $frontendRoot -ChildPath "scripts/AppShell.js"
$architecturePath = Join-Path -Path $repoRoot -ChildPath "docs/ARCHITECTURE.md"
$expectedFrontendCacheKey = "20260817-chartjs-employee-cards-v2"

$expectedAccessFunctions = @(
    "Get-NormalizedRoleName",
    "ConvertTo-TimeEntryTypeArray",
    "Get-EmployeeTimeEntryTypesFromUserRecord"
)

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
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -cne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Get-PowerShellAst {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    Assert-Equal -Expected 0 -Actual @($parseErrors).Count -Message ("PowerShell parser errors were found in {0}." -f $Path)
    return $ast
}

function Get-NamedFunctionAst {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $Ast.Find({
        param($node)
        return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name)
    }, $true)
}

foreach ($requiredPath in @(
    $manifestPath,
    $modulePath,
    $authServicePath,
    $utilitiesPath,
    $dashboardPath,
    $historyPath,
    $employeesPath,
    $projectsPath,
    $indexPath,
    $appShellPath,
    $architecturePath
)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required Phase 6 file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.UserAccessProfile.psm1" -Actual ([string]$manifest.RootModule) -Message "The user-access RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "UserAccessProfile must remain compatible with Windows PowerShell 5.1."
Assert-Equal -Expected ($expectedAccessFunctions -join "|") -Actual (@($manifest.FunctionsToExport) -join "|") -Message "The user-access public API changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The user-access manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("UserAccessProfile must not export {0}." -f $emptyExportKey)
}

$moduleAst = Get-PowerShellAst -Path $modulePath
$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "datafolder", "usersfile", "sessionsfile", "projectsfile")
$implicitVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) {
        return $false
    }
    $name = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    if ($name.Contains(":")) {
        $name = $name.Substring($name.LastIndexOf(":") + 1)
    }
    return ($forbiddenCallerVariables -contains $name)
}, $true))
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "UserAccessProfile reads request, auth storage, DATA, projects, or caller-scope state."

$forbiddenModuleCommands = @(
    "Get-Variable", "Get-Content", "Set-Content", "Add-Content", "Out-File",
    "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item",
    "Copy-Item", "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod", "Get-Date",
    "Read-JsonArrayFile", "Write-JsonAtomic", "Write-JsonArrayAtomic", "Acquire-ResourceLock"
)
$moduleSideEffects = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.CommandAst])) {
        return $false
    }
    return ($forbiddenModuleCommands -contains [string]$node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $moduleSideEffects.Count -Message "UserAccessProfile acquired an I/O, lock, clock, network, or dynamic-scope dependency."

$authAst = Get-PowerShellAst -Path $authServicePath
foreach ($functionName in $expectedAccessFunctions) {
    $definition = Get-NamedFunctionAst -Ast $authAst -Name $functionName
    Assert-True -Condition ($null -ne $definition) -Message ("The {0} compatibility facade is missing from AuthService." -f $functionName)
    $commands = @($definition.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("The {0} facade must only delegate once." -f $functionName)
    Assert-Equal -Expected ("Saphir.UserAccessProfile\{0}" -f $functionName) -Actual ([string]$commands[0].GetCommandName()) -Message ("The {0} facade delegates to the wrong boundary." -f $functionName)
}

$utilitiesSource = [System.IO.File]::ReadAllText($utilitiesPath)
$dashboardSource = [System.IO.File]::ReadAllText($dashboardPath)
$historySource = [System.IO.File]::ReadAllText($historyPath)
$employeesSource = [System.IO.File]::ReadAllText($employeesPath)
$projectsSource = [System.IO.File]::ReadAllText($projectsPath)
$indexSource = [System.IO.File]::ReadAllText($indexPath)
$appShellSource = [System.IO.File]::ReadAllText($appShellPath)
$architectureSource = [System.IO.File]::ReadAllText($architecturePath)

Assert-True -Condition ($utilitiesSource.Contains("saphir.textSearch = Object.freeze({")) -Message "The shared text-search API is not encapsulated under window.Saphir."
foreach ($apiName in @("tokenize", "matchesAll")) {
    Assert-True -Condition ($utilitiesSource.Contains(("    {0}," -f $apiName))) -Message ("window.Saphir.textSearch does not publish {0}." -f $apiName)
}

foreach ($consumer in @(
    [PSCustomObject]@{ Name = "Utilities entry filtering"; Source = $utilitiesSource },
    [PSCustomObject]@{ Name = "Dashboard search"; Source = $dashboardSource },
    [PSCustomObject]@{ Name = "History search"; Source = $historySource },
    [PSCustomObject]@{ Name = "Personnel search"; Source = $employeesSource },
    [PSCustomObject]@{ Name = "Project portfolio search"; Source = $projectsSource }
)) {
    Assert-True -Condition ($consumer.Source.Contains("window.Saphir.textSearch.")) -Message ("{0} no longer delegates to textSearch." -f $consumer.Name)
}

$utilitiesIndex = $indexSource.IndexOf('scripts/Utilities.js?v=', [System.StringComparison]::Ordinal)
$appShellIndex = $indexSource.IndexOf('scripts/AppShell.js?v=', [System.StringComparison]::Ordinal)
Assert-True -Condition ($utilitiesIndex -ge 0 -and $appShellIndex -gt $utilitiesIndex) -Message "Utilities.js must load before AppShell and deferred views consume window.Saphir.textSearch."
foreach ($assetPath in @(
    "assets/styles.css",
    "assets/apple-ui.css",
    "scripts/I18n.js",
    "scripts/Utilities.js",
    "scripts/AppShell.js",
    "scripts/Views/ViewSwitching.js",
    "scripts/Views/SelfView.js"
)) {
    Assert-True -Condition ($indexSource.Contains(("{0}?v={1}" -f $assetPath, $expectedFrontendCacheKey))) -Message ("The Phase 6 cache key is stale for {0}." -f $assetPath)
}
foreach ($viewName in @("EmployeesView", "DashboardView", "ApprovalsView", "HistoryView", "ProjectsView")) {
    Assert-True -Condition ($appShellSource.Contains(("{0}.js?v={1}" -f $viewName, $expectedFrontendCacheKey))) -Message ("The Phase 6 deferred-view cache key is stale for {0}." -f $viewName)
}

Assert-True -Condition ($architectureSource.Contains("Saphir.UserAccessProfile")) -Message "The user-access profile boundary is not documented."
Assert-True -Condition ($architectureSource.Contains("window.Saphir.textSearch")) -Message "The text-search boundary is not documented."

Write-Host "Phase 6 access/search boundary tests passed: 3 user-access exports, 3 compatibility facades, and 2 text-search APIs."
