$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$frontendRoot = Join-Path -Path $repoRoot -ChildPath "app/frontend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryIdentity.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryIdentity.psm1"
$facadePath = Join-Path -Path $backendRoot -ChildPath "services/EntryService.ps1"
$utilitiesPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Utilities.js"
$selfViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/SelfView.js"
$projectsViewPath = Join-Path -Path $frontendRoot -ChildPath "scripts/Views/ProjectsView.js"
$indexPath = Join-Path -Path $frontendRoot -ChildPath "index.html"
$architecturePath = Join-Path -Path $repoRoot -ChildPath "docs/ARCHITECTURE.md"

$expectedEntryIdentityFunctions = @(
    "Get-EntryIdentifierValue",
    "Get-EntryExactPunchInText",
    "Get-EntryLegacyLookupKey",
    "Find-EntryIndex",
    "New-EntryIndexLookup",
    "Find-EntryIndexFromLookup"
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

foreach ($requiredPath in @($manifestPath, $modulePath, $facadePath, $utilitiesPath, $selfViewPath, $projectsViewPath, $indexPath, $architecturePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required Phase 2 file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.EntryIdentity.psm1" -Actual ([string]$manifest.RootModule) -Message "The entry identity RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "The entry identity module must remain compatible with Windows PowerShell 5.1."
Assert-Equal -Expected ($expectedEntryIdentityFunctions -join "|") -Actual (@($manifest.FunctionsToExport) -join "|") -Message "The entry identity public API changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The entry identity manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("The entry identity module must not export {0}." -f $emptyExportKey)
}

$moduleAst = Get-PowerShellAst -Path $modulePath
$forbiddenModuleCommands = @(
    "Get-Variable", "Get-Content", "Set-Content", "Add-Content", "Out-File",
    "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item",
    "Copy-Item", "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod", "Get-Date"
)
$moduleSideEffects = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.CommandAst])) {
        return $false
    }
    return ($forbiddenModuleCommands -contains [string]$node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $moduleSideEffects.Count -Message "The entry identity module acquired an I/O, clock, or dynamic-scope dependency."

$facadeAst = Get-PowerShellAst -Path $facadePath
foreach ($functionName in $expectedEntryIdentityFunctions) {
    $functionDefinition = $facadeAst.Find({
        param($node)
        return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName)
    }, $true)
    Assert-True -Condition ($null -ne $functionDefinition) -Message ("EntryService lost its compatibility facade for {0}." -f $functionName)

    $commands = @($functionDefinition.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("The {0} facade must only delegate once." -f $functionName)
    Assert-Equal -Expected ("Saphir.EntryIdentity\{0}" -f $functionName) -Actual ([string]$commands[0].GetCommandName()) -Message ("The {0} facade no longer delegates to the pure module." -f $functionName)

    $controlFlow = @($functionDefinition.Body.FindAll({
        param($node)
        return (
            $node -is [System.Management.Automation.Language.IfStatementAst] -or
            $node -is [System.Management.Automation.Language.ForStatementAst] -or
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -or
            $node -is [System.Management.Automation.Language.WhileStatementAst] -or
            $node -is [System.Management.Automation.Language.DoWhileStatementAst] -or
            $node -is [System.Management.Automation.Language.DoUntilStatementAst]
        )
    }, $true))
    Assert-Equal -Expected 0 -Actual $controlFlow.Count -Message ("The {0} facade duplicated domain logic." -f $functionName)
}

$utilitiesSource = [System.IO.File]::ReadAllText($utilitiesPath)
$selfSource = [System.IO.File]::ReadAllText($selfViewPath)
$projectsSource = [System.IO.File]::ReadAllText($projectsViewPath)
$indexSource = [System.IO.File]::ReadAllText($indexPath)
$architectureSource = [System.IO.File]::ReadAllText($architecturePath)

Assert-True -Condition ($utilitiesSource.Contains("saphir.dateRanges = Object.freeze({")) -Message "The frontend date-range API is not encapsulated under window.Saphir."
Assert-True -Condition ($utilitiesSource.Contains("resolveSelf,")) -Message "The Self date-range resolver is not published."
Assert-True -Condition ($utilitiesSource.Contains("resolveProjects,")) -Message "The Projects date-range resolver is not published."
Assert-True -Condition ($selfSource.Contains("window.Saphir.dateRanges.resolveSelf(")) -Message "The historical Self facade does not delegate to the shared resolver."
Assert-True -Condition ($projectsSource.Contains("window.Saphir.dateRanges.resolveProjects(")) -Message "The historical Projects facade does not delegate to the shared resolver."
Assert-True -Condition (-not $selfSource.Contains("function toSelfDateInputValue(")) -Message "The removed duplicate Self date formatter returned."

$utilitiesIndex = $indexSource.IndexOf('scripts/Utilities.js?v=', [System.StringComparison]::Ordinal)
$selfIndex = $indexSource.IndexOf('scripts/Views/SelfView.js?v=', [System.StringComparison]::Ordinal)
Assert-True -Condition ($utilitiesIndex -ge 0 -and $selfIndex -gt $utilitiesIndex) -Message "Utilities.js must load before the Self facade that consumes window.Saphir.dateRanges."

Assert-True -Condition ($architectureSource.Contains("Saphir.EntryIdentity")) -Message "The EntryIdentity boundary is not documented."
Assert-True -Condition ($architectureSource.Contains("window.Saphir.dateRanges")) -Message "The frontend date-range boundary is not documented."

Write-Host ("Phase 2 domain boundary tests passed: {0} entry exports and 2 deterministic date-range resolvers." -f $expectedEntryIdentityFunctions.Count)
