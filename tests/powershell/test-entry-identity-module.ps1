$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryIdentity.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryIdentity.psm1"
$entryServicePath = Join-Path -Path $backendRoot -ChildPath "services/EntryService.ps1"

$expectedFunctions = @(
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

function Invoke-EntryIdentityFunction {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [Parameter(Mandatory = $true)][bool]$UseFacade
    )

    if ($UseFacade) {
        return (& $Name @Arguments)
    }

    $qualifiedName = "Saphir.EntryIdentity\{0}" -f $Name
    return (& $qualifiedName @Arguments)
}

function Assert-IdentityBehavior {
    param(
        [Parameter(Mandatory = $true)][bool]$UseFacade,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $emptyEntries = @()
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $emptyEntries; EntryId = "missing"; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label did not accept an empty entry collection."
    $emptyLookup = Invoke-EntryIdentityFunction -Name "New-EntryIndexLookup" -Arguments @{ Entries = $emptyEntries } -UseFacade $UseFacade
    Assert-Equal -Expected 0 -Actual $emptyLookup.ById.Count -Message "$Label populated the ID index for an empty collection."
    Assert-Equal -Expected 0 -Actual $emptyLookup.ByDateAndPunch.Count -Message "$Label populated the legacy index for an empty collection."
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndexFromLookup" -Arguments @{ Lookup = $emptyLookup; EntryId = ""; Date = "2026-08-01"; PunchIn = "08:00:00" } -UseFacade $UseFacade) -Message "$Label resolved an entry from an empty lookup."

    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $null; EntryId = "missing"; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label did not normalize a null entry collection."
    $nullLookup = Invoke-EntryIdentityFunction -Name "New-EntryIndexLookup" -Arguments @{ Entries = $null } -UseFacade $UseFacade
    Assert-Equal -Expected 0 -Actual $nullLookup.ById.Count -Message "$Label populated the ID index for a null collection."
    Assert-Equal -Expected 0 -Actual $nullLookup.ByDateAndPunch.Count -Message "$Label populated the legacy index for a null collection."

    $singleton = [PSCustomObject]@{
        entryId      = "single"
        date         = "2026-08-01"
        punchIn      = "08:00:00"
        exactPunchIn = "08:03:12"
    }
    Assert-Equal -Expected "single" -Actual (Invoke-EntryIdentityFunction -Name "Get-EntryIdentifierValue" -Arguments @{ Entry = $singleton } -UseFacade $UseFacade) -Message "$Label did not read a scalar entry ID."
    Assert-Equal -Expected "08:03:12" -Actual (Invoke-EntryIdentityFunction -Name "Get-EntryExactPunchInText" -Arguments @{ Entry = $singleton } -UseFacade $UseFacade) -Message "$Label did not prefer exact punch-in time."
    Assert-Equal -Expected "07:45:00" -Actual (Invoke-EntryIdentityFunction -Name "Get-EntryExactPunchInText" -Arguments @{ Entry = [PSCustomObject]@{ punchIn = "07:45:00" } } -UseFacade $UseFacade) -Message "$Label did not preserve the punch-in fallback for legacy entries."
    Assert-Equal -Expected 0 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $singleton; EntryId = "single"; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label did not normalize a scalar singleton."
    Assert-Equal -Expected 0 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $singleton; EntryId = ""; Date = "2026-08-01"; PunchIn = "08:03:12" } -UseFacade $UseFacade) -Message "$Label did not resolve a legacy exact punch-in."
    $singletonLookup = Invoke-EntryIdentityFunction -Name "New-EntryIndexLookup" -Arguments @{ Entries = $singleton } -UseFacade $UseFacade
    Assert-Equal -Expected 0 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndexFromLookup" -Arguments @{ Lookup = $singletonLookup; EntryId = "single"; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label did not index a scalar singleton."
    Assert-Equal -Expected 0 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndexFromLookup" -Arguments @{ Lookup = $singletonLookup; EntryId = ""; Date = "2026-08-01"; PunchIn = "08:03:12" } -UseFacade $UseFacade) -Message "$Label did not index exact punch-in time."

    $entries = @(
        [PSCustomObject]@{ entryId = "A"; date = "2026-08-01"; punchIn = "08:00:00"; exactPunchIn = "08:02:00" },
        [PSCustomObject]@{ entryId = "B"; date = "2026-08-02"; punchIn = "09:00:00"; exactPunchIn = "09:06:00" },
        [PSCustomObject]@{ entryId = "C"; date = "2026-08-03"; punchIn = "10:00:00"; exactPunchIn = "10:00:00" }
    )
    $lookup = Invoke-EntryIdentityFunction -Name "New-EntryIndexLookup" -Arguments @{ Entries = $entries } -UseFacade $UseFacade
    foreach ($case in @(
        [PSCustomObject]@{ Id = "A"; Index = 0 },
        [PSCustomObject]@{ Id = "B"; Index = 1 },
        [PSCustomObject]@{ Id = "C"; Index = 2 }
    )) {
        Assert-Equal -Expected $case.Index -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $entries; EntryId = $case.Id; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label linear lookup failed in a multi-entry file."
        Assert-Equal -Expected $case.Index -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndexFromLookup" -Arguments @{ Lookup = $lookup; EntryId = $case.Id; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label indexed lookup failed in a multi-entry file."
    }

    # Stable IDs are authoritative. Conflicting or matching legacy metadata may
    # never redirect a request whose supplied ID is missing or points elsewhere.
    Assert-Equal -Expected 1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $entries; EntryId = "B"; Date = "2026-08-01"; PunchIn = "08:00:00" } -UseFacade $UseFacade) -Message "$Label let legacy metadata override a stable ID."
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $entries; EntryId = "missing"; Date = "2026-08-01"; PunchIn = "08:00:00" } -UseFacade $UseFacade) -Message "$Label fell back from a missing stable ID."
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndexFromLookup" -Arguments @{ Lookup = $lookup; EntryId = "missing"; Date = "2026-08-01"; PunchIn = "08:00:00" } -UseFacade $UseFacade) -Message "$Label indexed lookup fell back from a missing stable ID."

    $duplicateIds = @(
        [PSCustomObject]@{ entryId = "duplicate"; date = "2026-08-04"; punchIn = "11:00:00" },
        [PSCustomObject]@{ entryId = "duplicate"; date = "2026-08-05"; punchIn = "12:00:00" }
    )
    $duplicateIdLookup = Invoke-EntryIdentityFunction -Name "New-EntryIndexLookup" -Arguments @{ Entries = $duplicateIds } -UseFacade $UseFacade
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $duplicateIds; EntryId = "duplicate"; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label selected an arbitrary duplicate stable ID."
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndexFromLookup" -Arguments @{ Lookup = $duplicateIdLookup; EntryId = "duplicate"; Date = ""; PunchIn = "" } -UseFacade $UseFacade) -Message "$Label indexed lookup selected an arbitrary duplicate stable ID."

    $ambiguousLegacy = @(
        [PSCustomObject]@{ entryId = "legacy-a"; date = "2026-08-06"; punchIn = "13:00:00"; exactPunchIn = "13:02:00" },
        [PSCustomObject]@{ entryId = "legacy-b"; date = "2026-08-06"; punchIn = "13:00:00"; exactPunchIn = "13:04:00" }
    )
    $ambiguousLegacyLookup = Invoke-EntryIdentityFunction -Name "New-EntryIndexLookup" -Arguments @{ Entries = $ambiguousLegacy } -UseFacade $UseFacade
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndex" -Arguments @{ Entries = $ambiguousLegacy; EntryId = ""; Date = "2026-08-06"; PunchIn = "13:00:00" } -UseFacade $UseFacade) -Message "$Label selected an arbitrary ambiguous legacy key."
    Assert-Equal -Expected -1 -Actual (Invoke-EntryIdentityFunction -Name "Find-EntryIndexFromLookup" -Arguments @{ Lookup = $ambiguousLegacyLookup; EntryId = ""; Date = "2026-08-06"; PunchIn = "13:00:00" } -UseFacade $UseFacade) -Message "$Label indexed lookup selected an arbitrary ambiguous legacy key."

    Assert-Equal -Expected "" -Actual (Invoke-EntryIdentityFunction -Name "Get-EntryLegacyLookupKey" -Arguments @{ Date = ""; PunchIn = "08:00:00" } -UseFacade $UseFacade) -Message "$Label created a partial legacy key."
    Assert-Equal -Expected ("2026-08-01{0}08:00:00" -f [char]31) -Actual (Invoke-EntryIdentityFunction -Name "Get-EntryLegacyLookupKey" -Arguments @{ Date = "2026-08-01"; PunchIn = "08:00:00" } -UseFacade $UseFacade) -Message "$Label changed the legacy key format."
}

Assert-True -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Message "The Saphir.EntryIdentity manifest is missing."
Assert-True -Condition (Test-Path -LiteralPath $modulePath -PathType Leaf) -Message "The Saphir.EntryIdentity root module is missing."

$rawManifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.EntryIdentity.psm1" -Actual ([string]$rawManifest.RootModule) -Message "The entry identity RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$rawManifest.PowerShellVersion) -Message "The entry identity module must support Windows PowerShell 5.1."
Assert-SequenceEqual -Expected $expectedFunctions -Actual @($rawManifest.FunctionsToExport) -Message "The entry identity export contract changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($rawManifest.ContainsKey($emptyExportKey)) -Message ("The manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($rawManifest[$emptyExportKey]).Count -Message ("The module must not export {0}." -f $emptyExportKey)
}
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
Assert-Equal -Expected 0 -Actual @($moduleParseErrors).Count -Message "The entry identity module has parser errors."
$functionDefinitions = @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual @($functionDefinitions | Sort-Object) -Message "The entry identity module must contain exactly its six public functions."

$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir")
$implicitVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
    $name = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    if ($name.Contains(":")) { $name = $name.Substring($name.LastIndexOf(":") + 1) }
    return ($forbiddenCallerVariables -contains $name)
}, $true))
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "The pure module reads request-loop state."

$forbiddenCommands = @(
    "Get-Variable", "Get-Content", "Set-Content", "Add-Content", "Out-File",
    "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item",
    "Copy-Item", "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod", "Get-Date"
)
$sideEffectCommands = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.CommandAst])) { return $false }
    return ($forbiddenCommands -contains [string]$node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $sideEffectCommands.Count -Message "The pure module contains filesystem, network, clock, or dynamic-scope commands."

Remove-Module -Name "Saphir.EntryIdentity" -Force -ErrorAction SilentlyContinue
$firstModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
$firstExports = @($firstModule.ExportedCommands.Keys | Sort-Object)
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual $firstExports -Message "The first module import exposed unexpected commands."
Assert-IdentityBehavior -UseFacade $false -Label "Pure module"

$secondModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
$secondExports = @($secondModule.ExportedCommands.Keys | Sort-Object)
Assert-SequenceEqual -Expected $firstExports -Actual $secondExports -Message "Repeated imports changed the module exports."
Assert-Equal -Expected 1 -Actual @(Get-Module -Name "Saphir.EntryIdentity").Count -Message "Repeated imports left duplicate modules loaded."
Assert-IdentityBehavior -UseFacade $false -Label "Reimported pure module"

. $entryServicePath
Assert-IdentityBehavior -UseFacade $true -Label "EntryService facade"
Assert-IdentityBehavior -UseFacade $false -Label "Module behind facade"

# Dot-sourcing the compatibility service more than once is common in focused
# tests and must leave both the historical and qualified APIs usable.
. $entryServicePath
Assert-Equal -Expected "Function" -Actual ([string](Get-Command -Name "Find-EntryIndex" -CommandType Function).CommandType) -Message "Repeated facade loading lost the historical function."
Assert-IdentityBehavior -UseFacade $true -Label "Reloaded EntryService facade"

Remove-Module -Name "Saphir.EntryIdentity" -Force -ErrorAction SilentlyContinue
Write-Host "Entry identity module tests passed: exact exports, pure runtime, and zero/scalar/multi-entry facade parity."
