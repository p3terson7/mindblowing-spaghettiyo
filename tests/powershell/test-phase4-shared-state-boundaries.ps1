$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$frontendRoot = Join-Path -Path $repoRoot -ChildPath "app/frontend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryState.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryState.psm1"
$entryServicePath = Join-Path -Path $backendRoot -ChildPath "services/EntryService.ps1"
$readModelPath = Join-Path -Path $backendRoot -ChildPath "services/ReadModelService.ps1"
$analyticsPath = Join-Path -Path $backendRoot -ChildPath "services/AnalyticsReportService.ps1"
$utilitiesPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Utilities.js"
$selfViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/SelfView.js"
$employeesViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/EmployeesView.js"
$indexPath = Join-Path -Path $frontendRoot -ChildPath "index.html"
$architecturePath = Join-Path -Path $repoRoot -ChildPath "docs/ARCHITECTURE.md"

$expectedEntryStateFunctions = @(
    "ConvertTo-BooleanFlag",
    "Test-EntryForgottenClockOut",
    "Test-EntryOpen"
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
    $entryServicePath,
    $readModelPath,
    $analyticsPath,
    $utilitiesPath,
    $selfViewPath,
    $employeesViewPath,
    $indexPath,
    $architecturePath
)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required Phase 4 file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.EntryState.psm1" -Actual ([string]$manifest.RootModule) -Message "The entry-state RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "EntryState must remain compatible with Windows PowerShell 5.1."
Assert-Equal -Expected ($expectedEntryStateFunctions -join "|") -Actual (@($manifest.FunctionsToExport) -join "|") -Message "The entry-state public API changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The entry-state manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("EntryState must not export {0}." -f $emptyExportKey)
}

$moduleAst = Get-PowerShellAst -Path $modulePath
$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "datafolder")
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
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "EntryState reads request, DATA, or caller-scope state."

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
Assert-Equal -Expected 0 -Actual $moduleSideEffects.Count -Message "EntryState acquired an I/O, lock, clock, or dynamic-scope dependency."

$facadeContracts = @(
    [PSCustomObject]@{ Path = $entryServicePath; Function = "Convert-ToBooleanFlag"; Target = "Saphir.EntryState\ConvertTo-BooleanFlag" },
    [PSCustomObject]@{ Path = $entryServicePath; Function = "Test-EntryForgottenClockOut"; Target = "Saphir.EntryState\Test-EntryForgottenClockOut" },
    [PSCustomObject]@{ Path = $readModelPath; Function = "Test-EntryOpen"; Target = "Saphir.EntryState\Test-EntryOpen" },
    [PSCustomObject]@{ Path = $analyticsPath; Function = "Test-AnalyticsReportForgottenClockOut"; Target = "Saphir.EntryState\Test-EntryForgottenClockOut" }
)
$astsByPath = @{}
foreach ($contract in $facadeContracts) {
    if (-not $astsByPath.ContainsKey([string]$contract.Path)) {
        $astsByPath[[string]$contract.Path] = Get-PowerShellAst -Path ([string]$contract.Path)
    }
    $definition = Get-NamedFunctionAst -Ast $astsByPath[[string]$contract.Path] -Name ([string]$contract.Function)
    Assert-True -Condition ($null -ne $definition) -Message ("The {0} compatibility facade is missing." -f $contract.Function)
    $commands = @($definition.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("The {0} facade must only delegate once." -f $contract.Function)
    Assert-Equal -Expected ([string]$contract.Target) -Actual ([string]$commands[0].GetCommandName()) -Message ("The {0} facade delegates to the wrong boundary." -f $contract.Function)
}

$utilitiesSource = [System.IO.File]::ReadAllText($utilitiesPath)
$selfSource = [System.IO.File]::ReadAllText($selfViewPath)
$employeesSource = [System.IO.File]::ReadAllText($employeesViewPath)
$indexSource = [System.IO.File]::ReadAllText($indexPath)
$architectureSource = [System.IO.File]::ReadAllText($architecturePath)

Assert-True -Condition ($utilitiesSource.Contains("saphir.calendarMonths = Object.freeze({")) -Message "The shared calendar-month API is not encapsulated under window.Saphir."
foreach ($apiName in @("resolveActiveMonth", "buildYear")) {
    Assert-True -Condition ($utilitiesSource.Contains(("    {0}," -f $apiName))) -Message ("window.Saphir.calendarMonths does not publish {0}." -f $apiName)
}

foreach ($facadeCheck in @(
    [PSCustomObject]@{ Source = $selfSource; Name = "Self active month"; Needle = "window.Saphir.calendarMonths.resolveActiveMonth(" },
    [PSCustomObject]@{ Source = $selfSource; Name = "Self month board"; Needle = "window.Saphir.calendarMonths.buildYear(" },
    [PSCustomObject]@{ Source = $employeesSource; Name = "Employee active month"; Needle = "window.Saphir.calendarMonths.resolveActiveMonth(" },
    [PSCustomObject]@{ Source = $employeesSource; Name = "Employee month board"; Needle = "window.Saphir.calendarMonths.buildYear(" }
)) {
    Assert-True -Condition ($facadeCheck.Source.Contains($facadeCheck.Needle)) -Message ("The {0} facade no longer delegates to calendarMonths." -f $facadeCheck.Name)
}

$utilitiesIndex = $indexSource.IndexOf('scripts/Utilities.js?v=', [System.StringComparison]::Ordinal)
$selfIndex = $indexSource.IndexOf('scripts/Views/SelfView.js?v=', [System.StringComparison]::Ordinal)
Assert-True -Condition ($utilitiesIndex -ge 0 -and $selfIndex -gt $utilitiesIndex) -Message "Utilities.js must load before SelfView consumes window.Saphir.calendarMonths."

Assert-True -Condition ($architectureSource.Contains("Saphir.EntryState")) -Message "The EntryState boundary is not documented."
Assert-True -Condition ($architectureSource.Contains("window.Saphir.calendarMonths")) -Message "The calendar-month boundary is not documented."

Write-Host "Phase 4 shared-state boundary tests passed: 3 entry-state exports, 4 compatibility facades, and 2 calendar-month APIs."
