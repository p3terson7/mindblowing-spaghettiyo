$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.CompensationGrid.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.CompensationGrid.psm1"
$templatePath = Join-Path -Path $backendRoot -ChildPath "defaults/compensation-grid.v1.json"

$expectedFunctions = @(
    "ConvertTo-CompensationGridCode",
    "ConvertTo-CompensationSalaryBand",
    "Test-CompensationSalaryGridDocument",
    "ConvertTo-CompensationSalaryGridDocument",
    "Resolve-CompensationSalaryBand"
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

function Assert-ThrowsArgumentException {
    param(
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch [System.ArgumentException] {
        $threw = $true
    }

    Assert-True -Condition $threw -Message $Message
}

foreach ($requiredPath in @($manifestPath, $modulePath, $templatePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required compensation-grid file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.CompensationGrid.psm1" -Actual ([string]$manifest.RootModule) -Message "The compensation grid RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "Compensation grid must support Windows PowerShell 5.1."
Assert-SequenceEqual -Expected $expectedFunctions -Actual @($manifest.FunctionsToExport) -Message "The compensation-grid export contract changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("The compensation grid must not export {0}." -f $emptyExportKey)
}
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
Assert-Equal -Expected 0 -Actual @($moduleParseErrors).Count -Message "The compensation-grid module has parser errors."
$definedFunctions = @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
foreach ($expectedFunction in $expectedFunctions) {
    Assert-True -Condition ($definedFunctions -contains $expectedFunction) -Message ("Compensation-grid public function is missing: {0}" -f $expectedFunction)
}

$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "datafolder", "usersfile", "salarybandsfile")
$implicitVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
    $name = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    if ($name.Contains(":")) { $name = $name.Substring($name.LastIndexOf(":") + 1) }
    return ($forbiddenCallerVariables -contains $name)
}, $true))
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "The pure compensation-grid module reads request, file, or DATA state."

$forbiddenCommands = @(
    "Get-Variable", "Get-Content", "Set-Content", "Add-Content", "Out-File",
    "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item",
    "Copy-Item", "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod", "Get-Date",
    "Read-JsonArrayFile", "Write-JsonAtomic", "Write-JsonArrayAtomic", "Acquire-ResourceLock"
)
$sideEffectCommands = @($moduleAst.FindAll({
    param($node)
    return ($node -is [System.Management.Automation.Language.CommandAst] -and $forbiddenCommands -contains [string]$node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $sideEffectCommands.Count -Message "Compensation-grid module performs filesystem, network, clock, or lock work."

Remove-Module -Name "Saphir.CompensationGrid" -Force -ErrorAction SilentlyContinue
$module = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual @($module.ExportedCommands.Keys | Sort-Object) -Message "Compensation-grid module exported an unexpected command."

$template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
$templateValidation = Test-CompensationSalaryGridDocument -Value $template
Assert-Equal -Expected $true -Actual ([bool]$templateValidation.isValid) -Message "The seeded compensation grid is invalid."
Assert-Equal -Expected 1 -Actual ([int]$templateValidation.document.schemaVersion) -Message "Seeded salary grid schema version changed."
Assert-Equal -Expected "CAD" -Actual ([string]$templateValidation.document.currency) -Message "Seeded salary grid currency changed."
Assert-Equal -Expected 10 -Actual @($templateValidation.document.bands).Count -Message "Seeded salary grid must contain all supplied salary bands."

$seededBandExpectations = @{
    "CR|04|01" = 5727100
    "CR|04|02" = 5873800
    "CR|04|03" = 6025500
    "CR|04|04" = 6176100
    "AS|03|01" = 7379800
    "AS|03|02" = 7659900
    "AS|03|03" = 7951100
    "AS|04|01" = 8061200
    "AS|04|02" = 8367500
    "AS|04|03" = 8710800
}
foreach ($band in @($templateValidation.document.bands)) {
    $key = ("{0}|{1}|{2}" -f [string]$band.group, [string]$band.subGroup, [string]$band.level)
    Assert-True -Condition $seededBandExpectations.ContainsKey($key) -Message ("Unexpected seed band: {0}" -f $key)
    Assert-Equal -Expected $seededBandExpectations[$key] -Actual $band.annualSalaryCents -Message ("Seeded salary changed for {0}." -f $key)
    Assert-Equal -Expected "2026-01-01" -Actual $band.effectiveFrom -Message ("Seeded effective date changed for {0}." -f $key)
}

Assert-Equal -Expected "CR" -Actual (ConvertTo-CompensationGridCode -Value " cr " -MaximumLength 6) -Message "Group normalization changed."
Assert-Equal -Expected "04" -Actual (ConvertTo-CompensationGridCode -Value " 0 4 " -MaximumLength 10) -Message "Sub-group normalization changed."
Assert-ThrowsArgumentException -Action { ConvertTo-CompensationGridCode -Value "AS*" -MaximumLength 6 } -Message "Wildcard classification codes must not be accepted."
Assert-ThrowsArgumentException -Action { ConvertTo-CompensationGridCode -Value "OVERLONG" -MaximumLength 6 } -Message "Overlong classification codes must not be accepted."

$normalizedBand = ConvertTo-CompensationSalaryBand -Value ([PSCustomObject]@{ id = "canonical-shape"; group = "as"; subGroup = "4"; level = "1"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" })
Assert-Equal -Expected "AS" -Actual $normalizedBand.group -Message "Salary-band Group must contain letters only."
Assert-Equal -Expected "04" -Actual $normalizedBand.subGroup -Message "Salary-band Sub-group must contain two digits."
Assert-Equal -Expected "01" -Actual $normalizedBand.level -Message "Salary-band Level must contain two digits."
foreach ($invalidBand in @(
    [PSCustomObject]@{ id = "decorated-group"; group = "AS-03"; subGroup = "04"; level = "01"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" },
    [PSCustomObject]@{ id = "decorated-subgroup"; group = "AS"; subGroup = "SG-4"; level = "01"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" },
    [PSCustomObject]@{ id = "three-digit-level"; group = "AS"; subGroup = "04"; level = "123"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" }
)) {
    Assert-ThrowsArgumentException -Action { ConvertTo-CompensationSalaryBand -Value $invalidBand } -Message "Ambiguous salary classifications must be rejected instead of silently rewritten."
}

$resolved = Resolve-CompensationSalaryBand -SalaryGrid $template -Group " cr " -SubGroup "04" -Level "1" -AsOfDate ([DateTime]"2026-08-27")
Assert-Equal -Expected "cr-04-01-2026" -Actual $resolved.id -Message "Exact classification did not resolve the CR-04 first echelon rate."
Assert-Equal -Expected 5727100 -Actual $resolved.annualSalaryCents -Message "Resolved annual salary changed."
Assert-Equal -Expected $null -Actual (Resolve-CompensationSalaryBand -SalaryGrid $template -Group "CR" -SubGroup "05" -Level "1" -AsOfDate ([DateTime]"2026-08-27")) -Message "Different Sub-group must not receive a fallback rate."
Assert-Equal -Expected $null -Actual (Resolve-CompensationSalaryBand -SalaryGrid $template -Group "CR" -SubGroup "04" -Level "" -AsOfDate ([DateTime]"2026-08-27")) -Message "Missing Level must not receive a fallback rate."

$effectiveDocument = [PSCustomObject]@{
    schemaVersion = 1
    currency = "CAD"
    bands = @(
        [PSCustomObject]@{ id = "cr-04-01-h1"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01"; effectiveTo = "2026-06-30" },
        [PSCustomObject]@{ id = "cr-04-01-h2"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 5900000; effectiveFrom = "2026-07-01" }
    )
}
$effectiveValidation = Test-CompensationSalaryGridDocument -Value $effectiveDocument
Assert-Equal -Expected $true -Actual ([bool]$effectiveValidation.isValid) -Message "Non-overlapping effective salary periods should be valid."
Assert-Equal -Expected 5727100 -Actual (Resolve-CompensationSalaryBand -SalaryGrid $effectiveDocument -Group "CR" -SubGroup "04" -Level "1" -AsOfDate ([DateTime]"2026-06-30")).annualSalaryCents -Message "The first effective period did not resolve on its last day."
Assert-Equal -Expected 5900000 -Actual (Resolve-CompensationSalaryBand -SalaryGrid $effectiveDocument -Group "CR" -SubGroup "04" -Level "1" -AsOfDate ([DateTime]"2026-07-01")).annualSalaryCents -Message "The replacement effective period did not resolve on its first day."

$overlappingDocument = [PSCustomObject]@{
    schemaVersion = 1
    currency = "CAD"
    bands = @(
        [PSCustomObject]@{ id = "cr-04-01-overlap-a"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" },
        [PSCustomObject]@{ id = "cr-04-01-overlap-b"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 5900000; effectiveFrom = "2026-06-01" }
    )
}
$overlapValidation = Test-CompensationSalaryGridDocument -Value $overlappingDocument
Assert-Equal -Expected $false -Actual ([bool]$overlapValidation.isValid) -Message "Overlapping rates for an identical classification must be rejected."
Assert-True -Condition (@($overlapValidation.errors | Where-Object { [string]$_ -match "overlap" }).Count -gt 0) -Message "Overlapping bands did not produce a clear validation error."

$duplicateIdDocument = [PSCustomObject]@{
    schemaVersion = 1
    currency = "CAD"
    bands = @(
        [PSCustomObject]@{ id = "duplicate-id"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" },
        [PSCustomObject]@{ id = "DUPLICATE-ID"; group = "CR"; subGroup = "04"; level = "2"; annualSalaryCents = 5873800; effectiveFrom = "2026-01-01" }
    )
}
$duplicateIdValidation = Test-CompensationSalaryGridDocument -Value $duplicateIdDocument
Assert-Equal -Expected $false -Actual ([bool]$duplicateIdValidation.isValid) -Message "Duplicate salary band ids must be rejected case-insensitively."
Assert-True -Condition (@($duplicateIdValidation.errors | Where-Object { [string]$_ -match "duplicated" }).Count -gt 0) -Message "Duplicate salary band ids did not produce a clear validation error."

$invalidBandDocument = [PSCustomObject]@{
    schemaVersion = 1
    currency = "CAD"
    bands = @(
        [PSCustomObject]@{ id = "invalid-band"; group = "CR"; subGroup = "*"; level = "1"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" }
    )
}
$invalidBandValidation = Test-CompensationSalaryGridDocument -Value $invalidBandDocument
Assert-Equal -Expected $false -Actual ([bool]$invalidBandValidation.isValid) -Message "Wildcard Sub-group must be rejected until an explicit policy exists."

Remove-Module -Name "Saphir.CompensationGrid" -Force -ErrorAction SilentlyContinue
Write-Host "Compensation grid module tests passed: pure validation, seeded bands, exact matching, and effective dates."
