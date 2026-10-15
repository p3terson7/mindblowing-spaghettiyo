$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.UserAccessProfile.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.UserAccessProfile.psm1"
$authServicePath = Join-Path -Path $backendRoot -ChildPath "services/AuthService.ps1"
$packageScriptPath = Join-Path -Path $repoRoot -ChildPath "scripts/package-app.ps1"
$releaseTestPath = Join-Path -Path $repoRoot -ChildPath "tests/powershell/test-release-package.ps1"

$expectedFunctions = @(
    "Get-NormalizedRoleName",
    "ConvertTo-TimeEntryTypeArray",
    "Get-EmployeeTimeEntryTypesFromUserRecord"
)
$expectedFacadeParameters = @{
    "Get-NormalizedRoleName"                    = @("Role")
    "ConvertTo-TimeEntryTypeArray"              = @("Value")
    "Get-EmployeeTimeEntryTypesFromUserRecord"  = @("UserRecord")
}

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

function Assert-SequenceEqual {
    param(
        [AllowEmptyCollection()][object[]]$Expected,
        [AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $expectedItems = @($Expected)
    $actualItems = @($Actual)
    Assert-Equal -Expected $expectedItems.Count -Actual $actualItems.Count -Message ("{0} Item count differs." -f $Message)
    for ($index = 0; $index -lt $expectedItems.Count; $index++) {
        Assert-Equal -Expected $expectedItems[$index] -Actual $actualItems[$index] -Message ("{0} Difference at index {1}." -f $Message, $index)
    }
}

function ConvertTo-ComparableJson {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return "null"
    }
    return ($Value | ConvertTo-Json -Compress -Depth 12)
}

function Get-FunctionAst {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $Ast.Find({
        param($node)
        return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name)
    }, $true)
}

function Invoke-UserAccessProfileFunction {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [bool]$UseFacade = $false
    )

    if ($UseFacade) {
        return (& $Name @Arguments)
    }

    $qualifiedName = "Saphir.UserAccessProfile\{0}" -f $Name
    return (& $qualifiedName @Arguments)
}

foreach ($requiredPath in @($manifestPath, $modulePath, $authServicePath, $packageScriptPath, $releaseTestPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required user access profile file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.UserAccessProfile.psm1" -Actual ([string]$manifest.RootModule) -Message "The user access profile RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "The user access profile module must support Windows PowerShell 5.1."
Assert-SequenceEqual -Expected $expectedFunctions -Actual @($manifest.FunctionsToExport) -Message "The user access profile export contract changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The user access profile manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("The user access profile module must not export {0}." -f $emptyExportKey)
}
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
Assert-Equal -Expected 0 -Actual @($moduleParseErrors).Count -Message "The user access profile module has parser errors."
$definedFunctions = @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } | Sort-Object)
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual $definedFunctions -Message "The user access profile module contains an unexpected function."

$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "datafolder", "usersfile", "sessionsfile", "bootstrapadminusername")
$implicitVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
    $name = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    if ($name.Contains(":")) { $name = $name.Substring($name.LastIndexOf(":") + 1) }
    return ($forbiddenCallerVariables -contains $name)
}, $true))
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "The pure user access profile module reads request, auth-storage, bootstrap, or DATA state."

$scopedVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
    $path = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    return ($path.StartsWith("script:") -or $path.StartsWith("global:") -or $path.StartsWith("env:"))
}, $true))
Assert-Equal -Expected 0 -Actual $scopedVariables.Count -Message "The pure user access profile module reads scoped runtime state."

$forbiddenCommands = @(
    "Get-Variable", "Get-Content", "Set-Content", "Add-Content", "Out-File",
    "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item",
    "Copy-Item", "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod",
    "Get-Date", "Acquire-ResourceLock", "Release-ResourceLock",
    "Read-JsonArrayFile", "Write-JsonAtomic", "Write-JsonArrayAtomic"
)
$sideEffectCommands = @($moduleAst.FindAll({
    param($node)
    return ($node -is [System.Management.Automation.Language.CommandAst] -and $forbiddenCommands -contains [string]$node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $sideEffectCommands.Count -Message "The pure user access profile module performs I/O, clock, network, or locking work."

Remove-Module -Name "Saphir.UserAccessProfile" -Force -ErrorAction SilentlyContinue
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null
$exportedCommands = @(Get-Command -Module "Saphir.UserAccessProfile" | ForEach-Object { $_.Name } | Sort-Object)
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual $exportedCommands -Message "Repeated standalone import changed the user access profile command set."

$roleCases = @(
    [PSCustomObject]@{ Value = $null; Expected = "employee"; Label = "null fails closed" },
    [PSCustomObject]@{ Value = ""; Expected = "employee"; Label = "empty" },
    [PSCustomObject]@{ Value = "  "; Expected = "employee"; Label = "whitespace" },
    [PSCustomObject]@{ Value = "employee"; Expected = "employee"; Label = "employee" },
    [PSCustomObject]@{ Value = " ADMIN "; Expected = "admin"; Label = "admin case and spaces" },
    [PSCustomObject]@{ Value = "super"; Expected = "superAdmin"; Label = "super alias" },
    [PSCustomObject]@{ Value = "Super Admin"; Expected = "superAdmin"; Label = "super space" },
    [PSCustomObject]@{ Value = "super_admin"; Expected = "superAdmin"; Label = "super underscore" },
    [PSCustomObject]@{ Value = "super-admin"; Expected = "superAdmin"; Label = "super hyphen" },
    [PSCustomObject]@{ Value = " s-u_p e r "; Expected = "superAdmin"; Label = "separators removed throughout" },
    [PSCustomObject]@{ Value = "manager"; Expected = "employee"; Label = "unknown fails closed" },
    [PSCustomObject]@{ Value = "administrator"; Expected = "employee"; Label = "near alias fails closed" }
)
foreach ($case in $roleCases) {
    $actual = Invoke-UserAccessProfileFunction -Name "Get-NormalizedRoleName" -Arguments @{ Role = $case.Value }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("Role golden failed for {0}." -f $case.Label)
}

$entryTypeCases = @(
    [PSCustomObject]@{ Value = $null; Expected = @("overtime"); Label = "null fallback" },
    [PSCustomObject]@{ Value = @(); Expected = @("overtime"); Label = "empty fallback" },
    [PSCustomObject]@{ Value = "  "; Expected = @("overtime"); Label = "blank fallback" },
    [PSCustomObject]@{ Value = " OT "; Expected = @("overtime"); Label = "ot alias" },
    [PSCustomObject]@{ Value = "DIVERSE"; Expected = @("diverse"); Label = "diverse only remains possible" },
    [PSCustomObject]@{ Value = @(" diverse ", "OT"); Expected = @("diverse", "overtime"); Label = "first occurrence order" },
    [PSCustomObject]@{ Value = @("ot", "OVERTIME", "diverse", "DIVERSE"); Expected = @("overtime", "diverse"); Label = "aliases and duplicates" },
    [PSCustomObject]@{ Value = @("unknown", "diverse", $null); Expected = @("diverse"); Label = "unknown values ignored" },
    [PSCustomObject]@{ Value = @("unknown", "other"); Expected = @("overtime"); Label = "all invalid fallback" },
    [PSCustomObject]@{ Value = 1; Expected = @("overtime"); Label = "unsupported scalar fallback" }
)
foreach ($case in $entryTypeCases) {
    $before = ConvertTo-ComparableJson -Value $case.Value
    $actual = @(Invoke-UserAccessProfileFunction -Name "ConvertTo-TimeEntryTypeArray" -Arguments @{ Value = $case.Value })
    Assert-SequenceEqual -Expected $case.Expected -Actual $actual -Message ("Time-entry-type golden failed for {0}." -f $case.Label)
    Assert-Equal -Expected $before -Actual (ConvertTo-ComparableJson -Value $case.Value) -Message ("Time-entry-type normalization mutated {0}." -f $case.Label)
}

$userCases = @(
    [PSCustomObject]@{ Value = $null; Expected = @("overtime"); Label = "null user" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{}; Expected = @("overtime"); Label = "missing properties" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ timeEntryTypes = "diverse" }; Expected = @("diverse"); Label = "explicit diverse only" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ TimeEntryTypes = @("ot", "diverse") }; Expected = @("overtime", "diverse"); Label = "case-insensitive explicit property" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ timeEntryTypes = $null; canPunchDiverse = $true; hasDiverse = $true }; Expected = @("overtime"); Label = "explicit null blocks legacy flags" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ timeEntryTypes = @(); canPunchDiverse = $true }; Expected = @("overtime"); Label = "explicit empty blocks legacy flag" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ timeEntryTypes = "invalid"; hasDiverse = $true }; Expected = @("overtime"); Label = "explicit invalid blocks legacy flag" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = $true }; Expected = @("overtime", "diverse"); Label = "legacy boolean true" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = " TRUE " }; Expected = @("overtime", "diverse"); Label = "legacy true text" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = 1 }; Expected = @("overtime", "diverse"); Label = "legacy numeric one" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = "YeS" }; Expected = @("overtime", "diverse"); Label = "legacy yes text" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = "y" }; Expected = @("overtime"); Label = "legacy y remains false" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = "on" }; Expected = @("overtime"); Label = "legacy on remains false" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = $false; hasDiverse = $true }; Expected = @("overtime", "diverse"); Label = "second legacy flag fallback" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ canPunchDiverse = $null; hasDiverse = $true }; Expected = @("overtime", "diverse"); Label = "null first flag still checks second" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ hasDiverse = $true }; Expected = @("overtime", "diverse"); Label = "hasDiverse boolean true" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ hasDiverse = $false }; Expected = @("overtime"); Label = "hasDiverse boolean false" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ hasDiverse = "false" }; Expected = @("overtime", "diverse"); Label = "legacy nonempty-string boolean cast" },
    [PSCustomObject]@{ Value = [PSCustomObject]@{ hasDiverse = "" }; Expected = @("overtime"); Label = "legacy empty-string boolean cast" },
    [PSCustomObject]@{ Value = @{ timeEntryTypes = @("diverse"); canPunchDiverse = $true }; Expected = @("overtime"); Label = "legacy hashtable adapter" }
)
foreach ($case in $userCases) {
    $before = ConvertTo-ComparableJson -Value $case.Value
    $actual = @(Invoke-UserAccessProfileFunction -Name "Get-EmployeeTimeEntryTypesFromUserRecord" -Arguments @{ UserRecord = $case.Value })
    Assert-SequenceEqual -Expected $case.Expected -Actual $actual -Message ("User-record access golden failed for {0}." -f $case.Label)
    Assert-Equal -Expected $before -Actual (ConvertTo-ComparableJson -Value $case.Value) -Message ("User-record access normalization mutated {0}." -f $case.Label)
}

# Suppress AuthService's normal storage initialization so this test exercises
# only the historical compatibility facades and performs no DATA I/O.
$script:AuthStorageEnsured = $true
. $authServicePath

$authTokens = $null
$authParseErrors = $null
$authAst = [System.Management.Automation.Language.Parser]::ParseFile($authServicePath, [ref]$authTokens, [ref]$authParseErrors)
Assert-Equal -Expected 0 -Actual @($authParseErrors).Count -Message "AuthService has parser errors."
foreach ($name in $expectedFunctions) {
    $definition = Get-FunctionAst -Ast $authAst -Name $name
    Assert-True -Condition ($null -ne $definition) -Message ("Historical user access profile facade {0} is missing." -f $name)
    $actualParameterNames = @($definition.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-SequenceEqual -Expected @($expectedFacadeParameters[$name]) -Actual $actualParameterNames -Message ("Historical user access profile facade {0} signature changed." -f $name)
    $commands = @($definition.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("Historical user access profile facade {0} must delegate exactly once." -f $name)
    Assert-Equal -Expected ("Saphir.UserAccessProfile\{0}" -f $name) -Actual $commands[0].GetCommandName() -Message ("Historical user access profile facade {0} delegates to the wrong command." -f $name)
}

foreach ($case in $roleCases) {
    $arguments = @{ Role = $case.Value }
    $moduleValue = Invoke-UserAccessProfileFunction -Name "Get-NormalizedRoleName" -Arguments $arguments
    $facadeValue = Invoke-UserAccessProfileFunction -Name "Get-NormalizedRoleName" -Arguments $arguments -UseFacade $true
    Assert-Equal -Expected $moduleValue -Actual $facadeValue -Message ("Role facade differs for {0}." -f $case.Label)
}
foreach ($case in $entryTypeCases) {
    $arguments = @{ Value = $case.Value }
    $moduleValue = @(Invoke-UserAccessProfileFunction -Name "ConvertTo-TimeEntryTypeArray" -Arguments $arguments)
    $facadeValue = @(Invoke-UserAccessProfileFunction -Name "ConvertTo-TimeEntryTypeArray" -Arguments $arguments -UseFacade $true)
    Assert-SequenceEqual -Expected $moduleValue -Actual $facadeValue -Message ("Time-entry-type facade differs for {0}." -f $case.Label)
}
foreach ($case in $userCases) {
    $arguments = @{ UserRecord = $case.Value }
    $moduleValue = @(Invoke-UserAccessProfileFunction -Name "Get-EmployeeTimeEntryTypesFromUserRecord" -Arguments $arguments)
    $facadeValue = @(Invoke-UserAccessProfileFunction -Name "Get-EmployeeTimeEntryTypesFromUserRecord" -Arguments $arguments -UseFacade $true)
    Assert-SequenceEqual -Expected $moduleValue -Actual $facadeValue -Message ("User-record access facade differs for {0}." -f $case.Label)
}

$packageSource = Get-Content -LiteralPath $packageScriptPath -Raw
$releaseTestSource = Get-Content -LiteralPath $releaseTestPath -Raw
foreach ($fileName in @("Saphir.UserAccessProfile.psd1", "Saphir.UserAccessProfile.psm1")) {
    Assert-True -Condition $packageSource.Contains($fileName) -Message ("Runtime package validation omits {0}." -f $fileName)
    Assert-True -Condition $releaseTestSource.Contains($fileName) -Message ("Release package test omits {0}." -f $fileName)
}

Write-Host "User access profile module tests passed: exact exports, legacy goldens, facade parity, purity, and package coverage."
