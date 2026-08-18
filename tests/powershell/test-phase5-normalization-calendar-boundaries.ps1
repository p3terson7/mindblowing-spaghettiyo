$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$frontendRoot = Join-Path -Path $repoRoot -ChildPath "app/frontend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.Gc179Profile.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.Gc179Profile.psm1"
$authServicePath = Join-Path -Path $backendRoot -ChildPath "services/AuthService.ps1"
$utilitiesPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Utilities.js"
$selfViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/SelfView.js"
$employeesViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/EmployeesView.js"
$indexPath = Join-Path -Path $frontendRoot -ChildPath "index.html"
$architecturePath = Join-Path -Path $repoRoot -ChildPath "docs/ARCHITECTURE.md"

$expectedGc179ProfileFunctions = @(
    "ConvertTo-Gc179UpperText",
    "Get-Gc179NamePartsFromDisplayName",
    "ConvertTo-Gc179BooleanValue",
    "ConvertTo-Gc179PriText",
    "ConvertTo-Gc179HeaderCodeText",
    "ConvertTo-Gc179PositionText",
    "ConvertTo-Gc179EchelonText",
    "ConvertTo-Gc179ProfileObject",
    "Get-Gc179ProfileFromUserRecord"
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
    $selfViewPath,
    $employeesViewPath,
    $indexPath,
    $architecturePath
)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required Phase 5 file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.Gc179Profile.psm1" -Actual ([string]$manifest.RootModule) -Message "The GC179 profile RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "Gc179Profile must remain compatible with Windows PowerShell 5.1."
Assert-Equal -Expected ($expectedGc179ProfileFunctions -join "|") -Actual (@($manifest.FunctionsToExport) -join "|") -Message "The GC179 profile public API changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The GC179 profile manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("Gc179Profile must not export {0}." -f $emptyExportKey)
}

$moduleAst = Get-PowerShellAst -Path $modulePath
$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "datafolder", "userspath", "sessionspath")
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
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "Gc179Profile reads request, auth storage, DATA, or caller-scope state."

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
Assert-Equal -Expected 0 -Actual $moduleSideEffects.Count -Message "Gc179Profile acquired an I/O, lock, clock, network, or dynamic-scope dependency."

$authAst = Get-PowerShellAst -Path $authServicePath
foreach ($functionName in $expectedGc179ProfileFunctions) {
    $definition = Get-NamedFunctionAst -Ast $authAst -Name $functionName
    Assert-True -Condition ($null -ne $definition) -Message ("The {0} compatibility facade is missing from AuthService." -f $functionName)
    $commands = @($definition.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("The {0} facade must only delegate once." -f $functionName)
    Assert-Equal -Expected ("Saphir.Gc179Profile\{0}" -f $functionName) -Actual ([string]$commands[0].GetCommandName()) -Message ("The {0} facade delegates to the wrong boundary." -f $functionName)
}

$utilitiesSource = [System.IO.File]::ReadAllText($utilitiesPath)
$selfSource = [System.IO.File]::ReadAllText($selfViewPath)
$employeesSource = [System.IO.File]::ReadAllText($employeesViewPath)
$indexSource = [System.IO.File]::ReadAllText($indexPath)
$architectureSource = [System.IO.File]::ReadAllText($architecturePath)

Assert-True -Condition ($utilitiesSource.Contains("saphir.calendarDays = Object.freeze({")) -Message "The shared calendar-day API is not encapsulated under window.Saphir."
Assert-True -Condition ($utilitiesSource.Contains("    buildMonth,")) -Message "window.Saphir.calendarDays does not publish buildMonth."
Assert-True -Condition ($selfSource.Contains("window.Saphir.calendarDays.buildMonth(")) -Message "The Self calendar no longer delegates to calendarDays."
Assert-True -Condition ($employeesSource.Contains("window.Saphir.calendarDays.buildMonth(")) -Message "The Personnel calendar no longer delegates to calendarDays."

$utilitiesIndex = $indexSource.IndexOf('scripts/Utilities.js?v=', [System.StringComparison]::Ordinal)
$selfIndex = $indexSource.IndexOf('scripts/Views/SelfView.js?v=', [System.StringComparison]::Ordinal)
Assert-True -Condition ($utilitiesIndex -ge 0 -and $selfIndex -gt $utilitiesIndex) -Message "Utilities.js must load before SelfView consumes window.Saphir.calendarDays."

Assert-True -Condition ($architectureSource.Contains("Saphir.Gc179Profile")) -Message "The GC179 profile boundary is not documented."
Assert-True -Condition ($architectureSource.Contains("window.Saphir.calendarDays")) -Message "The calendar-day boundary is not documented."

Write-Host ("Phase 5 normalization/calendar boundary tests passed: {0} GC179 profile exports, {0} compatibility facades, and 1 calendar-day API." -f $expectedGc179ProfileFunctions.Count)
