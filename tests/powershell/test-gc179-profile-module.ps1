$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.Gc179Profile.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.Gc179Profile.psm1"
$authServicePath = Join-Path -Path $backendRoot -ChildPath "services/AuthService.ps1"
$packageScriptPath = Join-Path -Path $repoRoot -ChildPath "scripts/package-app.ps1"
$releaseTestPath = Join-Path -Path $repoRoot -ChildPath "tests/powershell/test-release-package.ps1"

$expectedFunctions = @(
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
$privateFunctions = @(
    "Get-ObjectPropertyValue",
    "Get-ObjectStringProperty"
)
$expectedParameterContracts = @{
    "ConvertTo-Gc179UpperText"          = @('Value|System.String|[AllowNull()],[string]|<none>')
    "Get-Gc179NamePartsFromDisplayName" = @('DisplayName|System.String|[AllowNull()],[string]|<none>')
    "ConvertTo-Gc179BooleanValue"       = @('Value|System.Object||<none>', 'DefaultValue|System.Boolean|[bool]|$false')
    "ConvertTo-Gc179PriText"            = @('Value|System.String|[AllowNull()],[string]|<none>')
    "ConvertTo-Gc179HeaderCodeText"     = @('Value|System.String|[AllowNull()],[string]|<none>', 'MaximumLength|System.Int32|[Parameter(Mandatory=$true)],[int]|<none>')
    "ConvertTo-Gc179PositionText"       = @('Value|System.String|[AllowNull()],[string]|<none>')
    "ConvertTo-Gc179EchelonText"        = @('Value|System.String|[AllowNull()],[string]|<none>')
    "ConvertTo-Gc179ProfileObject"      = @('Value|System.Object||<none>', 'DisplayName|System.String|[AllowNull()],[string]|<none>')
    "Get-Gc179ProfileFromUserRecord"    = @('UserRecord|System.Object||<none>')
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

function Assert-ObjectEqual {
    param(
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-Equal -Expected (ConvertTo-ComparableJson -Value $Expected) -Actual (ConvertTo-ComparableJson -Value $Actual) -Message $Message
}

function Invoke-Gc179ProfileFunction {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [bool]$UseFacade = $false
    )

    if ($UseFacade) {
        return (& $Name @Arguments)
    }

    $qualifiedName = "Saphir.Gc179Profile\{0}" -f $Name
    return (& $qualifiedName @Arguments)
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

function Get-FunctionParameterContract {
    param([Parameter(Mandatory = $true)]$FunctionAst)

    return @($FunctionAst.Body.ParamBlock.Parameters | ForEach-Object {
        $parameter = $_
        $attributes = @($parameter.Attributes | ForEach-Object { $_.Extent.Text -replace "\s+", "" }) -join ","
        $defaultValue = if ($null -ne $parameter.DefaultValue) { $parameter.DefaultValue.Extent.Text } else { "<none>" }
        return ("{0}|{1}|{2}|{3}" -f $parameter.Name.VariablePath.UserPath, $parameter.StaticType.FullName, $attributes, $defaultValue)
    })
}

foreach ($requiredPath in @($manifestPath, $modulePath, $authServicePath, $packageScriptPath, $releaseTestPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required GC179 profile file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.Gc179Profile.psm1" -Actual ([string]$manifest.RootModule) -Message "The GC179 profile RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "The GC179 profile module must support Windows PowerShell 5.1."
Assert-SequenceEqual -Expected $expectedFunctions -Actual @($manifest.FunctionsToExport) -Message "The GC179 profile export contract changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The GC179 profile manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("The GC179 profile module must not export {0}." -f $emptyExportKey)
}
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
Assert-Equal -Expected 0 -Actual @($moduleParseErrors).Count -Message "The GC179 profile module has parser errors."
$definedFunctions = @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } | Sort-Object)
Assert-SequenceEqual -Expected @(($expectedFunctions + $privateFunctions) | Sort-Object) -Actual $definedFunctions -Message "The GC179 profile module contains an unexpected function."
foreach ($name in $expectedFunctions) {
    $definition = Get-FunctionAst -Ast $moduleAst -Name $name
    Assert-SequenceEqual -Expected @($expectedParameterContracts[$name]) -Actual @(Get-FunctionParameterContract -FunctionAst $definition) -Message ("GC179 module function {0} signature metadata changed." -f $name)
}

$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "datafolder", "usersfile", "sessionsfile")
$implicitVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
    $name = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    if ($name.Contains(":")) { $name = $name.Substring($name.LastIndexOf(":") + 1) }
    return ($forbiddenCallerVariables -contains $name)
}, $true))
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "The pure GC179 profile module reads request, auth-storage, or DATA state."

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
Assert-Equal -Expected 0 -Actual $sideEffectCommands.Count -Message "The pure GC179 profile module performs I/O, clock, network, or locking work."

Remove-Module -Name "Saphir.Gc179Profile" -Force -ErrorAction SilentlyContinue
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null
$exportedCommands = @(Get-Command -Module "Saphir.Gc179Profile" | ForEach-Object { $_.Name } | Sort-Object)
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual $exportedCommands -Message "Repeated import changed the GC179 profile command set."
foreach ($privateName in $privateFunctions) {
    Assert-True -Condition (-not ($exportedCommands -contains $privateName)) -Message ("Private helper {0} leaked from the module." -f $privateName)
}

$unicodeUpperE = [string][char]0x00C9
$unicodeLowerE = [string][char]0x00E9
$unicodeRightQuote = [string][char]0x2019
$unicodeMixedName = ("{0}lodie O{1}Neil" -f $unicodeUpperE, $unicodeRightQuote)
$unicodeUpperName = ("{0}LODIE O{1}NEIL" -f $unicodeUpperE, $unicodeRightQuote)

$upperCases = @(
    [PSCustomObject]@{ Value = $null; Expected = ""; Label = "null" },
    [PSCustomObject]@{ Value = ""; Expected = ""; Label = "empty" },
    [PSCustomObject]@{ Value = "   "; Expected = ""; Label = "whitespace" },
    [PSCustomObject]@{ Value = " jane doe "; Expected = "JANE DOE"; Label = "trim and uppercase" },
    [PSCustomObject]@{ Value = (" {0} " -f $unicodeMixedName); Expected = $unicodeUpperName; Label = "Unicode" }
)
foreach ($case in $upperCases) {
    $actual = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179UpperText" -Arguments @{ Value = $case.Value }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("Upper-text golden failed for {0}." -f $case.Label)
}

$nameCases = @(
    [PSCustomObject]@{ Value = $null; Expected = [PSCustomObject]@{ surname = ""; givenName = ""; initials = "" }; Label = "null" },
    [PSCustomObject]@{ Value = "   "; Expected = [PSCustomObject]@{ surname = ""; givenName = ""; initials = "" }; Label = "blank" },
    [PSCustomObject]@{ Value = "Prince"; Expected = [PSCustomObject]@{ surname = "PRINCE"; givenName = ""; initials = "P" }; Label = "one token" },
    [PSCustomObject]@{ Value = " Jane   Mary Doe "; Expected = [PSCustomObject]@{ surname = "DOE"; givenName = "JANE MARY"; initials = "J.D" }; Label = "many tokens" },
    [PSCustomObject]@{ Value = $unicodeMixedName; Expected = [PSCustomObject]@{ surname = ("O{0}NEIL" -f $unicodeRightQuote); givenName = ("{0}LODIE" -f $unicodeUpperE); initials = ("{0}.O" -f $unicodeUpperE) }; Label = "Unicode initials" }
)
foreach ($case in $nameCases) {
    $actual = Invoke-Gc179ProfileFunction -Name "Get-Gc179NamePartsFromDisplayName" -Arguments @{ DisplayName = $case.Value }
    Assert-ObjectEqual -Expected $case.Expected -Actual $actual -Message ("Display-name golden failed for {0}." -f $case.Label)
    Assert-SequenceEqual -Expected @("surname", "givenName", "initials") -Actual @($actual.PSObject.Properties.Name) -Message ("Display-name shape changed for {0}." -f $case.Label)
}

$booleanCases = @(
    [PSCustomObject]@{ Value = $null; Default = $false; Expected = $false; Label = "null false default" },
    [PSCustomObject]@{ Value = $null; Default = $true; Expected = $true; Label = "null true default" },
    [PSCustomObject]@{ Value = $true; Default = $false; Expected = $true; Label = "boolean true" },
    [PSCustomObject]@{ Value = $false; Default = $true; Expected = $false; Label = "boolean false" },
    [PSCustomObject]@{ Value = " TRUE "; Default = $false; Expected = $true; Label = "true text" },
    [PSCustomObject]@{ Value = "1"; Default = $false; Expected = $true; Label = "one text" },
    [PSCustomObject]@{ Value = "YeS"; Default = $false; Expected = $true; Label = "yes text" },
    [PSCustomObject]@{ Value = " y "; Default = $false; Expected = $true; Label = "y text" },
    [PSCustomObject]@{ Value = "ON"; Default = $false; Expected = $true; Label = "on text" },
    [PSCustomObject]@{ Value = "false"; Default = $true; Expected = $false; Label = "false text" },
    [PSCustomObject]@{ Value = "0"; Default = $true; Expected = $false; Label = "zero text" },
    [PSCustomObject]@{ Value = "No"; Default = $true; Expected = $false; Label = "no text" },
    [PSCustomObject]@{ Value = " n "; Default = $true; Expected = $false; Label = "n text" },
    [PSCustomObject]@{ Value = "OFF"; Default = $true; Expected = $false; Label = "off text" },
    [PSCustomObject]@{ Value = "maybe"; Default = $false; Expected = $false; Label = "unknown false default" },
    [PSCustomObject]@{ Value = "maybe"; Default = $true; Expected = $true; Label = "unknown true default" },
    [PSCustomObject]@{ Value = 1; Default = $false; Expected = $true; Label = "numeric one" },
    [PSCustomObject]@{ Value = 0; Default = $true; Expected = $false; Label = "numeric zero" }
)
foreach ($case in $booleanCases) {
    $actual = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179BooleanValue" -Arguments @{ Value = $case.Value; DefaultValue = $case.Default }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("Boolean golden failed for {0}." -f $case.Label)
}
Assert-Equal -Expected $false -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179BooleanValue" -Arguments @{ Value = $null }) -Message "The boolean default changed."

$priCases = @(
    [PSCustomObject]@{ Value = $null; Expected = "" },
    [PSCustomObject]@{ Value = "abc"; Expected = "" },
    [PSCustomObject]@{ Value = "1"; Expected = "1" },
    [PSCustomObject]@{ Value = "1234"; Expected = "123 4" },
    [PSCustomObject]@{ Value = "12-3456-78"; Expected = "123 456 78" },
    [PSCustomObject]@{ Value = "123-456-789"; Expected = "123 456 789" },
    [PSCustomObject]@{ Value = "12-3456-7890"; Expected = "123 456 789" }
)
foreach ($case in $priCases) {
    $actual = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179PriText" -Arguments @{ Value = $case.Value }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("PRI golden failed for {0}." -f [string]$case.Value)
}

$headerCases = @(
    [PSCustomObject]@{ Value = $null; MaximumLength = 6; Expected = ""; Label = "null" },
    [PSCustomObject]@{ Value = "ABC"; MaximumLength = 0; Expected = ""; Label = "zero limit" },
    [PSCustomObject]@{ Value = "ABC"; MaximumLength = -1; Expected = ""; Label = "negative limit" },
    [PSCustomObject]@{ Value = " as - 03() "; MaximumLength = 20; Expected = "AS-03"; Label = "whitespace and punctuation" },
    [PSCustomObject]@{ Value = (" {0} ab ._/ - 12 " -f $unicodeLowerE); MaximumLength = 20; Expected = "AB._/-12"; Label = "allowed symbols and accent removal" },
    [PSCustomObject]@{ Value = "abcdefghijkl"; MaximumLength = 6; Expected = "ABCDEF"; Label = "truncation" }
)
foreach ($case in $headerCases) {
    $actual = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179HeaderCodeText" -Arguments @{ Value = $case.Value; MaximumLength = $case.MaximumLength }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("Header-code golden failed for {0}." -f $case.Label)
}
Assert-Equal -Expected "ABCDEF" -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179PositionText" -Arguments @{ Value = "abcdefghijkl" }) -Message "Position no longer uses the six-character limit."
Assert-Equal -Expected "ABCDEFGHIJ" -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179EchelonText" -Arguments @{ Value = "abcdefghijkl" }) -Message "Echelon no longer uses the ten-character limit."
Assert-Equal -Expected "AS-03" -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179PositionText" -Arguments @{ Value = " as-03() " }) -Message "Position normalization changed."
Assert-Equal -Expected "CR/01" -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179EchelonText" -Arguments @{ Value = " cr/01!? " }) -Message "Echelon normalization changed."

$profileCases = @(
    [PSCustomObject]@{
        Label = "null fallback"
        Value = $null
        DisplayName = "Jane Mary Doe"
        Expected = [PSCustomObject]@{ surname = "DOE"; givenName = "JANE MARY"; initials = "J.D"; pri = ""; position = "STS"; level = "SUF-00"; compressedWorkWeek = $false }
    },
    [PSCustomObject]@{
        Label = "canonical"
        Value = [PSCustomObject]@{ surname = " smith "; givenName = " jane "; initials = " js "; pri = "000123456"; position = " as-03() "; level = " cr/01!? "; compressedWorkWeek = " ON " }
        DisplayName = "Fallback Person"
        Expected = [PSCustomObject]@{ surname = "SMITH"; givenName = "JANE"; initials = "JS"; pri = "000 123 456"; position = "AS-03"; level = "CR/01"; compressedWorkWeek = $true }
    },
    [PSCustomObject]@{
        Label = "legacy aliases"
        Value = [PSCustomObject]@{ lastName = " legacy "; Given = " user "; Initials = " lu "; PRI = "12-3456-7890"; poste = " abc 12 "; Echelon = " xy / 99 "; isCompressedWorkWeek = "yes" }
        DisplayName = "Fallback Person"
        Expected = [PSCustomObject]@{ surname = "LEGACY"; givenName = "USER"; initials = "LU"; pri = "123 456 789"; position = "ABC12"; level = "XY/99"; compressedWorkWeek = $true }
    },
    [PSCustomObject]@{
        Label = "hashtable"
        Value = @{ lastName = "Hash"; Given = "Table"; classification = "ab 12"; level = "l-001"; compressed = "y" }
        DisplayName = "Fallback Person"
        Expected = [PSCustomObject]@{ surname = "HASH"; givenName = "TABLE"; initials = "F.P"; pri = ""; position = "AB12"; level = "L-001"; compressedWorkWeek = $true }
    },
    [PSCustomObject]@{
        Label = "blank aliases and compressed precedence"
        Value = [PSCustomObject]@{ surname = ""; lastName = "Alias"; givenName = ""; Given = "Name"; Initials = "AN"; position = ""; classification = "zz-99"; level = ""; Echelon = "l/2"; compressedWorkWeek = ""; isCompressedWorkWeek = $true }
        DisplayName = "Fallback Person"
        Expected = [PSCustomObject]@{ surname = "ALIAS"; givenName = "NAME"; initials = "AN"; pri = ""; position = "ZZ-99"; level = "L/2"; compressedWorkWeek = $false }
    },
    [PSCustomObject]@{
        Label = "one-token defaults"
        Value = [PSCustomObject]@{ unknown = "preserve nowhere" }
        DisplayName = "Prince"
        Expected = [PSCustomObject]@{ surname = "PRINCE"; givenName = ""; initials = "P"; pri = ""; position = "STS"; level = "SUF-00"; compressedWorkWeek = $false }
    }
)
$profilePropertyOrder = @("surname", "givenName", "initials", "pri", "position", "level", "compressedWorkWeek")
foreach ($case in $profileCases) {
    $before = ConvertTo-ComparableJson -Value $case.Value
    $actual = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179ProfileObject" -Arguments @{ Value = $case.Value; DisplayName = $case.DisplayName }
    Assert-ObjectEqual -Expected $case.Expected -Actual $actual -Message ("Profile golden failed for {0}." -f $case.Label)
    Assert-SequenceEqual -Expected $profilePropertyOrder -Actual @($actual.PSObject.Properties.Name) -Message ("Profile shape changed for {0}." -f $case.Label)
    Assert-True -Condition ($actual.compressedWorkWeek -is [bool]) -Message ("Profile boolean type changed for {0}." -f $case.Label)
    Assert-Equal -Expected $before -Actual (ConvertTo-ComparableJson -Value $case.Value) -Message ("Profile normalization mutated {0}." -f $case.Label)
}

$userCases = @(
    [PSCustomObject]@{ Label = "null user"; Value = $null; Expected = [PSCustomObject]@{ surname = ""; givenName = ""; initials = ""; pri = ""; position = "STS"; level = "SUF-00"; compressedWorkWeek = $false } },
    [PSCustomObject]@{ Label = "display fallback"; Value = [PSCustomObject]@{ displayName = "Legacy Employee" }; Expected = [PSCustomObject]@{ surname = "EMPLOYEE"; givenName = "LEGACY"; initials = "L.E"; pri = ""; position = "STS"; level = "SUF-00"; compressedWorkWeek = $false } },
    [PSCustomObject]@{ Label = "saved profile"; Value = [PSCustomObject]@{ displayName = "Fallback Employee"; gc179Profile = [PSCustomObject]@{ surname = "Saved"; givenName = "Person"; position = "CR4"; level = "L-02"; compressedWorkWeek = $true } }; Expected = [PSCustomObject]@{ surname = "SAVED"; givenName = "PERSON"; initials = "F.E"; pri = ""; position = "CR4"; level = "L-02"; compressedWorkWeek = $true } },
    [PSCustomObject]@{ Label = "legacy hashtable user adapter"; Value = @{ displayName = "Hash User"; gc179Profile = @{ surname = "Ignored" } }; Expected = [PSCustomObject]@{ surname = ""; givenName = ""; initials = ""; pri = ""; position = "STS"; level = "SUF-00"; compressedWorkWeek = $false } }
)
foreach ($case in $userCases) {
    $before = ConvertTo-ComparableJson -Value $case.Value
    $actual = Invoke-Gc179ProfileFunction -Name "Get-Gc179ProfileFromUserRecord" -Arguments @{ UserRecord = $case.Value }
    Assert-ObjectEqual -Expected $case.Expected -Actual $actual -Message ("User-record profile golden failed for {0}." -f $case.Label)
    Assert-Equal -Expected $before -Actual (ConvertTo-ComparableJson -Value $case.Value) -Message ("User-record normalization mutated {0}." -f $case.Label)
}

# AuthService still initializes storage when used normally. Suppress that one
# composition-root side effect here so the test can inspect only its historical
# compatibility functions without creating or reading DATA.
$script:AuthStorageEnsured = $true
. $authServicePath

$authTokens = $null
$authParseErrors = $null
$authAst = [System.Management.Automation.Language.Parser]::ParseFile($authServicePath, [ref]$authTokens, [ref]$authParseErrors)
Assert-Equal -Expected 0 -Actual @($authParseErrors).Count -Message "AuthService has parser errors."
foreach ($name in $expectedFunctions) {
    $definition = Get-FunctionAst -Ast $authAst -Name $name
    Assert-True -Condition ($null -ne $definition) -Message ("Historical GC179 facade {0} is missing." -f $name)
    Assert-SequenceEqual -Expected @($expectedParameterContracts[$name]) -Actual @(Get-FunctionParameterContract -FunctionAst $definition) -Message ("Historical GC179 facade {0} signature metadata changed." -f $name)
    $commands = @($definition.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("Historical GC179 facade {0} must delegate exactly once." -f $name)
    Assert-Equal -Expected ("Saphir.Gc179Profile\{0}" -f $name) -Actual $commands[0].GetCommandName() -Message ("Historical GC179 facade {0} delegates to the wrong command." -f $name)
}
foreach ($privateName in $privateFunctions) {
    Assert-True -Condition ($null -eq (Get-FunctionAst -Ast $authAst -Name $privateName)) -Message ("AuthService still duplicates private helper {0}." -f $privateName)
}

foreach ($case in $upperCases) {
    $moduleValue = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179UpperText" -Arguments @{ Value = $case.Value }
    $facadeValue = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179UpperText" -Arguments @{ Value = $case.Value } -UseFacade $true
    Assert-Equal -Expected $moduleValue -Actual $facadeValue -Message ("Upper-text facade differs for {0}." -f $case.Label)
}
foreach ($case in $nameCases) {
    $moduleValue = Invoke-Gc179ProfileFunction -Name "Get-Gc179NamePartsFromDisplayName" -Arguments @{ DisplayName = $case.Value }
    $facadeValue = Invoke-Gc179ProfileFunction -Name "Get-Gc179NamePartsFromDisplayName" -Arguments @{ DisplayName = $case.Value } -UseFacade $true
    Assert-ObjectEqual -Expected $moduleValue -Actual $facadeValue -Message ("Name-parts facade differs for {0}." -f $case.Label)
}
foreach ($case in $booleanCases) {
    $arguments = @{ Value = $case.Value; DefaultValue = $case.Default }
    $moduleValue = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179BooleanValue" -Arguments $arguments
    $facadeValue = Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179BooleanValue" -Arguments $arguments -UseFacade $true
    Assert-Equal -Expected $moduleValue -Actual $facadeValue -Message ("Boolean facade differs for {0}." -f $case.Label)
}
Assert-Equal -Expected $false -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179BooleanValue" -Arguments @{ Value = $null } -UseFacade $true) -Message "The historical boolean facade default changed."
foreach ($case in $priCases) {
    $arguments = @{ Value = $case.Value }
    Assert-Equal -Expected (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179PriText" -Arguments $arguments) -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179PriText" -Arguments $arguments -UseFacade $true) -Message "PRI facade differs."
}
foreach ($case in $headerCases) {
    $arguments = @{ Value = $case.Value; MaximumLength = $case.MaximumLength }
    Assert-Equal -Expected (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179HeaderCodeText" -Arguments $arguments) -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179HeaderCodeText" -Arguments $arguments -UseFacade $true) -Message ("Header-code facade differs for {0}." -f $case.Label)
}
foreach ($name in @("ConvertTo-Gc179PositionText", "ConvertTo-Gc179EchelonText")) {
    foreach ($value in @($null, " as-03() ", "abcdefghijkl")) {
        $arguments = @{ Value = $value }
        Assert-Equal -Expected (Invoke-Gc179ProfileFunction -Name $name -Arguments $arguments) -Actual (Invoke-Gc179ProfileFunction -Name $name -Arguments $arguments -UseFacade $true) -Message ("{0} facade differs." -f $name)
    }
}
foreach ($case in $profileCases) {
    $arguments = @{ Value = $case.Value; DisplayName = $case.DisplayName }
    Assert-ObjectEqual -Expected (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179ProfileObject" -Arguments $arguments) -Actual (Invoke-Gc179ProfileFunction -Name "ConvertTo-Gc179ProfileObject" -Arguments $arguments -UseFacade $true) -Message ("Profile facade differs for {0}." -f $case.Label)
}
foreach ($case in $userCases) {
    $arguments = @{ UserRecord = $case.Value }
    Assert-ObjectEqual -Expected (Invoke-Gc179ProfileFunction -Name "Get-Gc179ProfileFromUserRecord" -Arguments $arguments) -Actual (Invoke-Gc179ProfileFunction -Name "Get-Gc179ProfileFromUserRecord" -Arguments $arguments -UseFacade $true) -Message ("User-record facade differs for {0}." -f $case.Label)
}

$packageSource = Get-Content -LiteralPath $packageScriptPath -Raw
$releaseTestSource = Get-Content -LiteralPath $releaseTestPath -Raw
foreach ($fileName in @("Saphir.Gc179Profile.psd1", "Saphir.Gc179Profile.psm1")) {
    Assert-True -Condition $packageSource.Contains($fileName) -Message ("Runtime package validation omits {0}." -f $fileName)
    Assert-True -Condition $releaseTestSource.Contains($fileName) -Message ("Release package test omits {0}." -f $fileName)
}

Write-Host "GC179 profile module tests passed: exact exports, private helpers, legacy goldens, facade parity, purity, and package coverage."
