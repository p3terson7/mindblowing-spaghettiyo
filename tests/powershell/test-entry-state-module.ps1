$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryState.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryState.psm1"
$entryServicePath = Join-Path -Path $backendRoot -ChildPath "services/EntryService.ps1"
$readModelServicePath = Join-Path -Path $backendRoot -ChildPath "services/ReadModelService.ps1"
$analyticsServicePath = Join-Path -Path $backendRoot -ChildPath "services/AnalyticsReportService.ps1"
$adminServerPath = Join-Path -Path $backendRoot -ChildPath "saphir-server.ps1"
$packageScriptPath = Join-Path -Path $repoRoot -ChildPath "scripts/package-app.ps1"
$releaseTestPath = Join-Path -Path $repoRoot -ChildPath "tests/powershell/test-release-package.ps1"

$expectedFunctions = @(
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

function Get-FunctionAst {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return @($Ast.FindAll({
        param($node)
        return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name)
    }, $true))[0]
}

function Assert-SingleQualifiedFacadeCall {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$FacadeName,
        [Parameter(Mandatory = $true)][string]$QualifiedCommand
    )

    $functionAst = Get-FunctionAst -Ast $Ast -Name $FacadeName
    Assert-True -Condition ($null -ne $functionAst) -Message ("Facade {0} is missing." -f $FacadeName)
    $commands = @($functionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    Assert-Equal -Expected 1 -Actual $commands.Count -Message ("Facade {0} must contain exactly one command." -f $FacadeName)
    Assert-Equal -Expected $QualifiedCommand -Actual $commands[0].GetCommandName() -Message ("Facade {0} does not delegate to the pure module." -f $FacadeName)
}

function Invoke-EntryStateFunction {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Arguments
    )

    $qualifiedName = "Saphir.EntryState\{0}" -f $Name
    return (& $qualifiedName @Arguments)
}

foreach ($requiredPath in @(
    $manifestPath,
    $modulePath,
    $entryServicePath,
    $readModelServicePath,
    $analyticsServicePath,
    $adminServerPath,
    $packageScriptPath,
    $releaseTestPath
)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required EntryState file is missing: {0}" -f $requiredPath)
}

$rawManifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.EntryState.psm1" -Actual ([string]$rawManifest.RootModule) -Message "The EntryState RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$rawManifest.PowerShellVersion) -Message "EntryState must support Windows PowerShell 5.1."
Assert-SequenceEqual -Expected $expectedFunctions -Actual @($rawManifest.FunctionsToExport) -Message "The EntryState export contract changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($rawManifest.ContainsKey($emptyExportKey)) -Message ("The manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($rawManifest[$emptyExportKey]).Count -Message ("EntryState must not export {0}." -f $emptyExportKey)
}
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
Assert-Equal -Expected 0 -Actual @($moduleParseErrors).Count -Message "EntryState has parser errors."
$functionDefinitions = @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual @($functionDefinitions | Sort-Object) -Message "EntryState must contain exactly its three public functions."

$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir")
$implicitVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
    $name = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    if ($name.Contains(":")) { $name = $name.Substring($name.LastIndexOf(":") + 1) }
    return ($forbiddenCallerVariables -contains $name)
}, $true))
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "EntryState reads request-loop state."

$forbiddenCommands = @(
    "Get-Variable", "Get-Content", "Set-Content", "Add-Content", "Out-File",
    "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item",
    "Copy-Item", "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod",
    "Get-Date", "Acquire-ResourceLock", "Release-ResourceLock",
    "Read-JsonArrayFile", "Write-JsonAtomic", "Write-JsonArrayAtomic"
)
$impureCommands = @($moduleAst.FindAll({
    param($node)
    return ($node -is [System.Management.Automation.Language.CommandAst] -and $forbiddenCommands -contains $node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $impureCommands.Count -Message "EntryState performs I/O, clock, network, or locking work."

Remove-Module -Name "Saphir.EntryState" -Force -ErrorAction SilentlyContinue
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null
$exportedCommands = @(Get-Command -Module "Saphir.EntryState" | ForEach-Object { $_.Name } | Sort-Object)
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual $exportedCommands -Message "Repeated import changed the EntryState command set."

$flagCases = @(
    [PSCustomObject]@{ Label = "null"; Value = $null; Expected = $false },
    [PSCustomObject]@{ Label = "boolean true"; Value = $true; Expected = $true },
    [PSCustomObject]@{ Label = "boolean false"; Value = $false; Expected = $false },
    [PSCustomObject]@{ Label = "lower true"; Value = "true"; Expected = $true },
    [PSCustomObject]@{ Label = "upper true"; Value = "TRUE"; Expected = $true },
    [PSCustomObject]@{ Label = "spaced true"; Value = "  true  "; Expected = $true },
    [PSCustomObject]@{ Label = "one text"; Value = "1"; Expected = $true },
    [PSCustomObject]@{ Label = "mixed yes"; Value = " YeS "; Expected = $true },
    [PSCustomObject]@{ Label = "integer one"; Value = 1; Expected = $true },
    [PSCustomObject]@{ Label = "character one"; Value = [char]"1"; Expected = $true },
    [PSCustomObject]@{ Label = "false text"; Value = "false"; Expected = $false },
    [PSCustomObject]@{ Label = "zero text"; Value = "0"; Expected = $false },
    [PSCustomObject]@{ Label = "integer zero"; Value = 0; Expected = $false },
    [PSCustomObject]@{ Label = "integer two"; Value = 2; Expected = $false },
    [PSCustomObject]@{ Label = "empty"; Value = ""; Expected = $false },
    [PSCustomObject]@{ Label = "whitespace"; Value = "   "; Expected = $false },
    [PSCustomObject]@{ Label = "unsupported on"; Value = "on"; Expected = $false },
    [PSCustomObject]@{ Label = "unsupported y"; Value = "y"; Expected = $false }
)
foreach ($case in $flagCases) {
    $actual = Invoke-EntryStateFunction -Name "ConvertTo-BooleanFlag" -Arguments @{ Value = $case.Value }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("Boolean flag golden failed for {0}." -f $case.Label)
}

$forgottenCases = @(
    [PSCustomObject]@{ Label = "null entry"; Entry = $null; Expected = $false },
    [PSCustomObject]@{ Label = "no flags"; Entry = [PSCustomObject]@{}; Expected = $false },
    [PSCustomObject]@{ Label = "legacy bool"; Entry = [PSCustomObject]@{ forgottenClockOut = $true }; Expected = $true },
    [PSCustomObject]@{ Label = "legacy string"; Entry = [PSCustomObject]@{ forgottenClockOut = " YES " }; Expected = $true },
    [PSCustomObject]@{ Label = "review bool"; Entry = [PSCustomObject]@{ needsClockOutReview = $true }; Expected = $true },
    [PSCustomObject]@{ Label = "review string"; Entry = [PSCustomObject]@{ needsClockOutReview = " 1 " }; Expected = $true },
    [PSCustomObject]@{ Label = "false flags"; Entry = [PSCustomObject]@{ forgottenClockOut = $false; needsClockOutReview = "0" }; Expected = $false },
    [PSCustomObject]@{ Label = "legacy true wins"; Entry = [PSCustomObject]@{ forgottenClockOut = "true"; needsClockOutReview = $false }; Expected = $true },
    [PSCustomObject]@{ Label = "review true wins"; Entry = [PSCustomObject]@{ forgottenClockOut = "false"; needsClockOutReview = "yes" }; Expected = $true },
    [PSCustomObject]@{ Label = "unsupported flags"; Entry = [PSCustomObject]@{ forgottenClockOut = "on"; needsClockOutReview = 2 }; Expected = $false }
)
foreach ($case in $forgottenCases) {
    $before = if ($null -eq $case.Entry) { "<null>" } else { $case.Entry | ConvertTo-Json -Compress -Depth 8 }
    $actual = Invoke-EntryStateFunction -Name "Test-EntryForgottenClockOut" -Arguments @{ Entry = $case.Entry }
    $after = if ($null -eq $case.Entry) { "<null>" } else { $case.Entry | ConvertTo-Json -Compress -Depth 8 }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("Forgotten-clock-out golden failed for {0}." -f $case.Label)
    Assert-Equal -Expected $before -Actual $after -Message ("Forgotten-clock-out check mutated {0}." -f $case.Label)
}

$openCases = @(
    [PSCustomObject]@{ Label = "null entry"; Entry = $null; Expected = $false },
    [PSCustomObject]@{ Label = "empty entry"; Entry = [PSCustomObject]@{}; Expected = $false },
    [PSCustomObject]@{ Label = "missing punch-out"; Entry = [PSCustomObject]@{ punchIn = "08:00:00" }; Expected = $true },
    [PSCustomObject]@{ Label = "null punch-out"; Entry = [PSCustomObject]@{ punchIn = "08:00:00"; punchOut = $null }; Expected = $true },
    [PSCustomObject]@{ Label = "blank punch-out"; Entry = [PSCustomObject]@{ punchIn = "08:00:00"; punchOut = "   " }; Expected = $true },
    [PSCustomObject]@{ Label = "blank punch-in"; Entry = [PSCustomObject]@{ punchIn = "   "; punchOut = $null }; Expected = $false },
    [PSCustomObject]@{ Label = "closed"; Entry = [PSCustomObject]@{ punchIn = "08:00:00"; punchOut = "10:00:00" }; Expected = $false },
    [PSCustomObject]@{ Label = "forgotten legacy"; Entry = [PSCustomObject]@{ punchIn = "08:00:00"; punchOut = $null; forgottenClockOut = "1" }; Expected = $false },
    [PSCustomObject]@{ Label = "forgotten review"; Entry = [PSCustomObject]@{ punchIn = "08:00:00"; punchOut = $null; needsClockOutReview = "YES" }; Expected = $false },
    [PSCustomObject]@{ Label = "explicit false flags"; Entry = [PSCustomObject]@{ punchIn = "08:00:00"; punchOut = $null; forgottenClockOut = $false; needsClockOutReview = "false" }; Expected = $true },
    [PSCustomObject]@{ Label = "numeric punch-in"; Entry = [PSCustomObject]@{ punchIn = 0; punchOut = $null }; Expected = $true },
    [PSCustomObject]@{ Label = "numeric punch-out"; Entry = [PSCustomObject]@{ punchIn = "08:00:00"; punchOut = 0 }; Expected = $false },
    [PSCustomObject]@{ Label = "legacy hashtable adapter"; Entry = @{ punchIn = "08:00:00"; punchOut = $null; forgottenClockOut = "yes" }; Expected = $true }
)
foreach ($case in $openCases) {
    $actual = Invoke-EntryStateFunction -Name "Test-EntryOpen" -Arguments @{ Entry = $case.Entry }
    Assert-Equal -Expected $case.Expected -Actual $actual -Message ("Open-entry golden failed for {0}." -f $case.Label)
}

$cardinalityCases = @(
    [PSCustomObject]@{ Label = "zero"; Entries = @(); Expected = @() },
    [PSCustomObject]@{ Label = "one"; Entries = @([PSCustomObject]@{ punchIn = "08:00:00" }); Expected = @($true) },
    [PSCustomObject]@{
        Label = "many"
        Entries = @(
            [PSCustomObject]@{ punchIn = "08:00:00" },
            [PSCustomObject]@{ punchIn = "09:00:00"; punchOut = "10:00:00" },
            [PSCustomObject]@{ punchIn = "11:00:00"; forgottenClockOut = $true }
        )
        Expected = @($true, $false, $false)
    }
)
foreach ($case in $cardinalityCases) {
    $actual = @(foreach ($entry in @($case.Entries)) { Invoke-EntryStateFunction -Name "Test-EntryOpen" -Arguments @{ Entry = $entry } })
    Assert-SequenceEqual -Expected @($case.Expected) -Actual $actual -Message ("Entry-state {0}-entry golden changed." -f $case.Label)
}

# Analytics is intentionally usable as a standalone service definition. It may
# import EntryState when absent, but a later dot-source must not overwrite the
# compatibility facades already defined by EntryService and ReadModelService.
Remove-Module -Name "Saphir.EntryState" -Force -ErrorAction SilentlyContinue
. $analyticsServicePath
Assert-True -Condition ($null -ne (Get-Module -Name "Saphir.EntryState")) -Message "Standalone analytics did not load EntryState."
Assert-Equal -Expected $true -Actual (Test-AnalyticsReportForgottenClockOut -Entry ([PSCustomObject]@{ needsClockOutReview = "yes" })) -Message "Standalone analytics lost legacy review flags."

. $entryServicePath
. $readModelServicePath
$forgottenFacadeBeforeAnalyticsReload = (Get-Command -Name "Test-EntryForgottenClockOut" -CommandType Function).ScriptBlock.ToString()
$openFacadeBeforeAnalyticsReload = (Get-Command -Name "Test-EntryOpen" -CommandType Function).ScriptBlock.ToString()
. $analyticsServicePath
Assert-Equal -Expected $forgottenFacadeBeforeAnalyticsReload -Actual (Get-Command -Name "Test-EntryForgottenClockOut" -CommandType Function).ScriptBlock.ToString() -Message "Analytics destructively reimported over the forgotten-clock-out facade."
Assert-Equal -Expected $openFacadeBeforeAnalyticsReload -Actual (Get-Command -Name "Test-EntryOpen" -CommandType Function).ScriptBlock.ToString() -Message "Analytics destructively reimported over the open-entry facade."

foreach ($case in $flagCases) {
    $moduleValue = Invoke-EntryStateFunction -Name "ConvertTo-BooleanFlag" -Arguments @{ Value = $case.Value }
    Assert-Equal -Expected $moduleValue -Actual (Convert-ToBooleanFlag -Value $case.Value) -Message ("Boolean compatibility facade differs for {0}." -f $case.Label)
}
foreach ($case in $forgottenCases) {
    $moduleValue = Invoke-EntryStateFunction -Name "Test-EntryForgottenClockOut" -Arguments @{ Entry = $case.Entry }
    Assert-Equal -Expected $moduleValue -Actual (Test-EntryForgottenClockOut -Entry $case.Entry) -Message ("Forgotten compatibility facade differs for {0}." -f $case.Label)
    Assert-Equal -Expected $moduleValue -Actual (Test-AnalyticsReportForgottenClockOut -Entry $case.Entry) -Message ("Analytics compatibility facade differs for {0}." -f $case.Label)
}
foreach ($case in $openCases) {
    $moduleValue = Invoke-EntryStateFunction -Name "Test-EntryOpen" -Arguments @{ Entry = $case.Entry }
    Assert-Equal -Expected $moduleValue -Actual (Test-EntryOpen -Entry $case.Entry) -Message ("Open-entry compatibility facade differs for {0}." -f $case.Label)
}

$entryTokens = $null
$entryParseErrors = $null
$entryAst = [System.Management.Automation.Language.Parser]::ParseFile($entryServicePath, [ref]$entryTokens, [ref]$entryParseErrors)
Assert-Equal -Expected 0 -Actual @($entryParseErrors).Count -Message "EntryService has parser errors."
Assert-SingleQualifiedFacadeCall -Ast $entryAst -FacadeName "Convert-ToBooleanFlag" -QualifiedCommand "Saphir.EntryState\ConvertTo-BooleanFlag"
Assert-SingleQualifiedFacadeCall -Ast $entryAst -FacadeName "Test-EntryForgottenClockOut" -QualifiedCommand "Saphir.EntryState\Test-EntryForgottenClockOut"

$readModelTokens = $null
$readModelParseErrors = $null
$readModelAst = [System.Management.Automation.Language.Parser]::ParseFile($readModelServicePath, [ref]$readModelTokens, [ref]$readModelParseErrors)
Assert-Equal -Expected 0 -Actual @($readModelParseErrors).Count -Message "ReadModelService has parser errors."
Assert-SingleQualifiedFacadeCall -Ast $readModelAst -FacadeName "Test-EntryOpen" -QualifiedCommand "Saphir.EntryState\Test-EntryOpen"

$analyticsTokens = $null
$analyticsParseErrors = $null
$analyticsAst = [System.Management.Automation.Language.Parser]::ParseFile($analyticsServicePath, [ref]$analyticsTokens, [ref]$analyticsParseErrors)
Assert-Equal -Expected 0 -Actual @($analyticsParseErrors).Count -Message "AnalyticsReportService has parser errors."
Assert-SingleQualifiedFacadeCall -Ast $analyticsAst -FacadeName "Test-AnalyticsReportForgottenClockOut" -QualifiedCommand "Saphir.EntryState\Test-EntryForgottenClockOut"

$adminServerSource = Get-Content -LiteralPath $adminServerPath -Raw
$entryLoadIndex = $adminServerSource.IndexOf('services/EntryService.ps1')
$readModelLoadIndex = $adminServerSource.IndexOf('services/ReadModelService.ps1')
$directoryLoadIndex = $adminServerSource.IndexOf('services/EmployeeDirectoryService.ps1')
$analyticsLoadIndex = $adminServerSource.IndexOf('services/AnalyticsReportService.ps1')
Assert-True -Condition ($entryLoadIndex -ge 0 -and $entryLoadIndex -lt $readModelLoadIndex) -Message "EntryService must load before ReadModelService."
Assert-True -Condition ($readModelLoadIndex -lt $directoryLoadIndex -and $directoryLoadIndex -lt $analyticsLoadIndex) -Message "ReadModel, EmployeeDirectory, and Analytics load order changed."

$packageSource = Get-Content -LiteralPath $packageScriptPath -Raw
$releaseTestSource = Get-Content -LiteralPath $releaseTestPath -Raw
foreach ($fileName in @("Saphir.EntryState.psd1", "Saphir.EntryState.psm1")) {
    Assert-True -Condition $packageSource.Contains($fileName) -Message ("Runtime package validation omits {0}." -f $fileName)
    Assert-True -Condition $releaseTestSource.Contains($fileName) -Message ("Release package test omits {0}." -f $fileName)
}

Write-Host "Entry state module tests passed: exact exports, pure behavior, legacy facades, standalone analytics, and package coverage."
