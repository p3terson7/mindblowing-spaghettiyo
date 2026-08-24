$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$frontendRoot = Join-Path -Path $repoRoot -ChildPath "app/frontend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.ProjectCatalog.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.ProjectCatalog.psm1"
$commonHelpersPath = Join-Path -Path $backendRoot -ChildPath "lib/CommonHelpers.ps1"
$analyticsPath = Join-Path -Path $backendRoot -ChildPath "services/AnalyticsReportService.ps1"
$utilitiesPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Utilities.js"
$selfViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/SelfView.js"
$employeesViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/EmployeesView.js"
$indexPath = Join-Path -Path $frontendRoot -ChildPath "index.html"
$architecturePath = Join-Path -Path $repoRoot -ChildPath "docs/ARCHITECTURE.md"

$expectedProjectCatalogFunctions = @(
    "Get-ProjectColorKeys",
    "Get-ProjectColorKeyFromText",
    "Get-DefaultProjectColorKey",
    "Test-ProjectColorKey",
    "Resolve-ProjectColorKey",
    "Get-ProjectMarkerKeys",
    "Get-ProjectMarkerKeyFromText",
    "Get-DefaultProjectMarkerKey",
    "Test-ProjectMarkerKey",
    "Resolve-ProjectMarkerKey",
    "ConvertTo-CodeArray",
    "Get-ProjectAdminCodes",
    "Get-ProjectBackupAdminCodes",
    "Test-ProjectArchived",
    "ConvertTo-NormalizedProjectObject",
    "ConvertTo-ProjectArchiveScope",
    "Select-ProjectsByArchiveScope"
)

$expectedCommonHelperFacades = @(
    "Get-ProjectColorKeys",
    "Get-DefaultProjectColorKey",
    "Test-ProjectColorKey",
    "Resolve-ProjectColorKey",
    "Get-ProjectMarkerKeys",
    "Get-DefaultProjectMarkerKey",
    "Test-ProjectMarkerKey",
    "Resolve-ProjectMarkerKey",
    "ConvertTo-CodeArray",
    "Get-ProjectAdminCodes",
    "Get-ProjectBackupAdminCodes",
    "Test-ProjectArchived",
    "ConvertTo-NormalizedProjectObject",
    "ConvertTo-ProjectArchiveScope",
    "Select-ProjectsByArchiveScope"
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

foreach ($requiredPath in @($manifestPath, $modulePath, $commonHelpersPath, $analyticsPath, $utilitiesPath, $selfViewPath, $employeesViewPath, $indexPath, $architecturePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required Phase 3 file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.ProjectCatalog.psm1" -Actual ([string]$manifest.RootModule) -Message "The project catalog RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "The project catalog must remain compatible with Windows PowerShell 5.1."
Assert-Equal -Expected ($expectedProjectCatalogFunctions -join "|") -Actual (@($manifest.FunctionsToExport) -join "|") -Message "The project catalog public API changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The project catalog manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("The project catalog must not export {0}." -f $emptyExportKey)
}

$moduleAst = Get-PowerShellAst -Path $modulePath
$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "projectsfile")
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
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "The project catalog reads request, DATA, or caller-scope state."

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
Assert-Equal -Expected 0 -Actual $moduleSideEffects.Count -Message "The project catalog acquired an I/O, lock, clock, or dynamic-scope dependency."

$commonHelpersAst = Get-PowerShellAst -Path $commonHelpersPath
foreach ($functionName in $expectedCommonHelperFacades) {
    $functionDefinition = Get-NamedFunctionAst -Ast $commonHelpersAst -Name $functionName
    Assert-True -Condition ($null -ne $functionDefinition) -Message ("CommonHelpers lost its {0} compatibility facade." -f $functionName)
    $commands = @($functionDefinition.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("The {0} project facade must only delegate once." -f $functionName)
    Assert-Equal -Expected ("Saphir.ProjectCatalog\{0}" -f $functionName) -Actual ([string]$commands[0].GetCommandName()) -Message ("The {0} facade no longer delegates to ProjectCatalog." -f $functionName)
}

$analyticsAst = Get-PowerShellAst -Path $analyticsPath
$analyticsColorFunction = Get-NamedFunctionAst -Ast $analyticsAst -Name "Get-AnalyticsReportProjectColorKey"
Assert-True -Condition ($null -ne $analyticsColorFunction) -Message "The analytics color compatibility adapter is missing."
$analyticsColorCommands = @($analyticsColorFunction.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { [string]$_.GetCommandName() })
Assert-True -Condition ($analyticsColorCommands -contains "Saphir.ProjectCatalog\Test-ProjectColorKey") -Message "Analytics no longer validates colors through ProjectCatalog."
Assert-True -Condition ($analyticsColorCommands -contains "Saphir.ProjectCatalog\Get-ProjectColorKeyFromText") -Message "Analytics no longer delegates legacy raw-code hashing to ProjectCatalog."
Assert-True -Condition (-not $analyticsColorFunction.Extent.Text.Contains('@("blue"')) -Message "The duplicated analytics project palette returned."

$analyticsMarkerFunction = Get-NamedFunctionAst -Ast $analyticsAst -Name "Get-AnalyticsReportProjectMarkerKey"
Assert-True -Condition ($null -ne $analyticsMarkerFunction) -Message "The analytics marker compatibility adapter is missing."
$analyticsMarkerCommands = @($analyticsMarkerFunction.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { [string]$_.GetCommandName() })
Assert-True -Condition ($analyticsMarkerCommands -contains "Saphir.ProjectCatalog\Test-ProjectMarkerKey") -Message "Analytics no longer validates markers through ProjectCatalog."
Assert-True -Condition ($analyticsMarkerCommands -contains "Saphir.ProjectCatalog\Get-ProjectMarkerKeyFromText") -Message "Analytics no longer delegates raw-code marker hashing to ProjectCatalog."

$utilitiesSource = [System.IO.File]::ReadAllText($utilitiesPath)
$selfSource = [System.IO.File]::ReadAllText($selfViewPath)
$employeesSource = [System.IO.File]::ReadAllText($employeesViewPath)
$indexSource = [System.IO.File]::ReadAllText($indexPath)
$architectureSource = [System.IO.File]::ReadAllText($architecturePath)

Assert-True -Condition ($utilitiesSource.Contains("saphir.entryStats = Object.freeze({")) -Message "The shared entry statistics API is not encapsulated under window.Saphir."
foreach ($apiName in @("resolveStatus", "selectTopBucket", "summarize")) {
    Assert-True -Condition ($utilitiesSource.Contains(("    {0}," -f $apiName))) -Message ("window.Saphir.entryStats does not publish {0}." -f $apiName)
}

foreach ($facadeCheck in @(
    [PSCustomObject]@{ Source = $selfSource; Name = "Self status"; Needle = "window.Saphir.entryStats.resolveStatus(" },
    [PSCustomObject]@{ Source = $selfSource; Name = "Self top bucket"; Needle = "window.Saphir.entryStats.selectTopBucket(" },
    [PSCustomObject]@{ Source = $selfSource; Name = "Self summary"; Needle = "window.Saphir.entryStats.summarize(" },
    [PSCustomObject]@{ Source = $employeesSource; Name = "Employee status"; Needle = "window.Saphir.entryStats.resolveStatus(" },
    [PSCustomObject]@{ Source = $employeesSource; Name = "Employee top bucket"; Needle = "window.Saphir.entryStats.selectTopBucket(" },
    [PSCustomObject]@{ Source = $employeesSource; Name = "Employee summary"; Needle = "window.Saphir.entryStats.summarize(" }
)) {
    Assert-True -Condition ($facadeCheck.Source.Contains($facadeCheck.Needle)) -Message ("The {0} facade no longer delegates to entryStats." -f $facadeCheck.Name)
}

$utilitiesIndex = $indexSource.IndexOf('scripts/Utilities.js?v=', [System.StringComparison]::Ordinal)
$selfIndex = $indexSource.IndexOf('scripts/Views/SelfView.js?v=', [System.StringComparison]::Ordinal)
Assert-True -Condition ($utilitiesIndex -ge 0 -and $selfIndex -gt $utilitiesIndex) -Message "Utilities.js must load before SelfView consumes window.Saphir.entryStats."

Assert-True -Condition ($architectureSource.Contains("Saphir.ProjectCatalog")) -Message "The ProjectCatalog boundary is not documented."
Assert-True -Condition ($architectureSource.Contains("window.Saphir.entryStats")) -Message "The entry statistics boundary is not documented."

Write-Host ("Phase 3 shared-domain boundary tests passed: {0} project exports, {1} compatibility facades, and 3 entry-stat APIs." -f $expectedProjectCatalogFunctions.Count, $expectedCommonHelperFacades.Count)
