$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.ProjectCatalog.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.ProjectCatalog.psm1"
$commonHelpersPath = Join-Path -Path $backendRoot -ChildPath "lib/CommonHelpers.ps1"
$analyticsServicePath = Join-Path -Path $backendRoot -ChildPath "services/AnalyticsReportService.ps1"

$expectedFunctions = @(
    "Get-ProjectColorKeys",
    "Get-ProjectColorKeyFromText",
    "Get-DefaultProjectColorKey",
    "Test-ProjectColorKey",
    "Resolve-ProjectColorKey",
    "ConvertTo-CodeArray",
    "Get-ProjectAdminCodes",
    "Get-ProjectBackupAdminCodes",
    "Test-ProjectArchived",
    "ConvertTo-NormalizedProjectObject",
    "ConvertTo-ProjectArchiveScope",
    "Select-ProjectsByArchiveScope"
)

$facadeFunctions = @(
    "Get-ProjectColorKeys",
    "Get-DefaultProjectColorKey",
    "Test-ProjectColorKey",
    "Resolve-ProjectColorKey",
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

function Assert-JsonEqual {
    param(
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $expectedJson = ConvertTo-Json -InputObject $Expected -Depth 12 -Compress
    $actualJson = ConvertTo-Json -InputObject $Actual -Depth 12 -Compress
    Assert-Equal -Expected $expectedJson -Actual $actualJson -Message $Message
}

function Invoke-ProjectCatalogFunction {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Arguments = @{},
        [Parameter(Mandatory = $true)][bool]$UseFacade
    )

    if ($UseFacade) {
        return (& $Name @Arguments)
    }

    $qualifiedName = "Saphir.ProjectCatalog\{0}" -f $Name
    return (& $qualifiedName @Arguments)
}

function Assert-CatalogBehavior {
    param(
        [Parameter(Mandatory = $true)][bool]$UseFacade,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $palette = @(Invoke-ProjectCatalogFunction -Name "Get-ProjectColorKeys" -UseFacade $UseFacade)
    Assert-SequenceEqual -Expected @("blue", "green", "violet", "teal", "amber", "coral", "pink", "indigo", "graphite", "mint") -Actual $palette -Message "$Label changed the palette or its stable order."
    Assert-Equal -Expected "blue" -Actual (Invoke-ProjectCatalogFunction -Name "Get-DefaultProjectColorKey" -Arguments @{ ProjectCode = "" } -UseFacade $UseFacade) -Message "$Label changed the empty-code color."
    Assert-Equal -Expected "mint" -Actual (Invoke-ProjectCatalogFunction -Name "Get-DefaultProjectColorKey" -Arguments @{ ProjectCode = "P1" } -UseFacade $UseFacade) -Message "$Label changed the P1 color."
    Assert-Equal -Expected "mint" -Actual (Invoke-ProjectCatalogFunction -Name "Get-DefaultProjectColorKey" -Arguments @{ ProjectCode = " P1 " } -UseFacade $UseFacade) -Message "$Label no longer trims catalog project codes before hashing."
    Assert-Equal -Expected "indigo" -Actual (Invoke-ProjectCatalogFunction -Name "Get-DefaultProjectColorKey" -Arguments @{ ProjectCode = "LEGACY" } -UseFacade $UseFacade) -Message "$Label changed a legacy fallback color."
    Assert-Equal -Expected $true -Actual (Invoke-ProjectCatalogFunction -Name "Test-ProjectColorKey" -Arguments @{ ColorKey = " VIOLET " } -UseFacade $UseFacade) -Message "$Label rejected a supported color with legacy whitespace."
    Assert-Equal -Expected $false -Actual (Invoke-ProjectCatalogFunction -Name "Test-ProjectColorKey" -Arguments @{ ColorKey = "neon" } -UseFacade $UseFacade) -Message "$Label accepted an unsupported color."
    Assert-Equal -Expected "violet" -Actual (Invoke-ProjectCatalogFunction -Name "Resolve-ProjectColorKey" -Arguments @{ ColorKey = " VIOLET "; ProjectCode = "P1" } -UseFacade $UseFacade) -Message "$Label did not normalize a supported explicit color."
    Assert-Equal -Expected "mint" -Actual (Invoke-ProjectCatalogFunction -Name "Resolve-ProjectColorKey" -Arguments @{ ColorKey = "neon"; ProjectCode = "P1" } -UseFacade $UseFacade) -Message "$Label changed invalid-color fallback behavior."

    Assert-Equal -Expected 0 -Actual @(Invoke-ProjectCatalogFunction -Name "ConvertTo-CodeArray" -Arguments @{ Value = $null } -UseFacade $UseFacade).Count -Message "$Label did not preserve a null code collection."
    Assert-SequenceEqual -Expected @("A", "B", "C") -Actual @(Invoke-ProjectCatalogFunction -Name "ConvertTo-CodeArray" -Arguments @{ Value = " B ; A,A ,, C " } -UseFacade $UseFacade) -Message "$Label changed string splitting, trimming, uniqueness, or ordering."
    $mixedCodes = @(
        " 002 ",
        [PSCustomObject]@{ employeeCode = "001" },
        [PSCustomObject]@{ code = "003" },
        $null,
        42,
        "002"
    )
    Assert-SequenceEqual -Expected @("001", "002", "003", "42") -Actual @(Invoke-ProjectCatalogFunction -Name "ConvertTo-CodeArray" -Arguments @{ Value = $mixedCodes } -UseFacade $UseFacade) -Message "$Label changed mixed legacy code conversion."
    Assert-SequenceEqual -Expected @("009") -Actual @(Invoke-ProjectCatalogFunction -Name "ConvertTo-CodeArray" -Arguments @{ Value = (, [PSCustomObject]@{ employeeCode = " 009 " }) } -UseFacade $UseFacade) -Message "$Label did not preserve a singleton object collection."

    $adminPrecedence = [PSCustomObject]@{
        admins = @("primary")
        adminEmployeeCodes = @("older-array")
        adminEmployeeCode = "older-single"
        admin = "oldest"
    }
    Assert-SequenceEqual -Expected @("primary") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectAdminCodes" -Arguments @{ Project = $adminPrecedence } -UseFacade $UseFacade) -Message "$Label changed admin field precedence."
    $emptyModernAdmins = [PSCustomObject]@{ admins = @(); adminEmployeeCodes = @("must-not-fall-back") }
    Assert-Equal -Expected 0 -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectAdminCodes" -Arguments @{ Project = $emptyModernAdmins } -UseFacade $UseFacade).Count -Message "$Label fell back past an explicitly empty modern admin field."
    Assert-SequenceEqual -Expected @("legacy-a", "legacy-b") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectAdminCodes" -Arguments @{ Project = [PSCustomObject]@{ adminEmployeeCodes = "legacy-b;legacy-a" } } -UseFacade $UseFacade) -Message "$Label stopped reading legacy admin arrays."
    Assert-SequenceEqual -Expected @("single") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectAdminCodes" -Arguments @{ Project = [PSCustomObject]@{ adminEmployeeCode = "single" } } -UseFacade $UseFacade) -Message "$Label stopped reading a legacy single admin code."
    Assert-SequenceEqual -Expected @("oldest") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectAdminCodes" -Arguments @{ Project = [PSCustomObject]@{ admin = "oldest" } } -UseFacade $UseFacade) -Message "$Label stopped reading the oldest admin field."

    $backupPrecedence = [PSCustomObject]@{
        backupAdmins = @("backup-primary")
        backupAdminEmployeeCodes = @("backup-older-array")
        backupAdminEmployeeCode = "backup-older-single"
        backupAdmin = "backup-oldest"
    }
    Assert-SequenceEqual -Expected @("backup-primary") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectBackupAdminCodes" -Arguments @{ Project = $backupPrecedence } -UseFacade $UseFacade) -Message "$Label changed backup-admin field precedence."
    Assert-SequenceEqual -Expected @("backup-array") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectBackupAdminCodes" -Arguments @{ Project = [PSCustomObject]@{ backupAdminEmployeeCodes = @("backup-array") } } -UseFacade $UseFacade) -Message "$Label stopped reading legacy backup-admin arrays."
    Assert-SequenceEqual -Expected @("backup-single") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectBackupAdminCodes" -Arguments @{ Project = [PSCustomObject]@{ backupAdminEmployeeCode = "backup-single" } } -UseFacade $UseFacade) -Message "$Label stopped reading a legacy single backup-admin code."
    Assert-SequenceEqual -Expected @("backup-oldest") -Actual @(Invoke-ProjectCatalogFunction -Name "Get-ProjectBackupAdminCodes" -Arguments @{ Project = [PSCustomObject]@{ backupAdmin = "backup-oldest" } } -UseFacade $UseFacade) -Message "$Label stopped reading the oldest backup-admin field."

    foreach ($case in @(
        [PSCustomObject]@{ Value = $null; Expected = $false; Label = "null project" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{}; Expected = $false; Label = "missing property" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = $true }; Expected = $true; Label = "true boolean" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = $false }; Expected = $false; Label = "false boolean" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = [int]-1 }; Expected = $true; Label = "nonzero Int32" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = [long]-1 }; Expected = $false; Label = "non-one Int64 legacy text" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = " TRUE " }; Expected = $true; Label = "true text" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = "yes" }; Expected = $true; Label = "yes text" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = "1" }; Expected = $true; Label = "one text" },
        [PSCustomObject]@{ Value = [PSCustomObject]@{ archived = "2" }; Expected = $false; Label = "unsupported text" }
    )) {
        Assert-Equal -Expected $case.Expected -Actual (Invoke-ProjectCatalogFunction -Name "Test-ProjectArchived" -Arguments @{ Project = $case.Value } -UseFacade $UseFacade) -Message ("$Label changed archived conversion for {0}." -f $case.Label)
    }

    $legacyProject = [PSCustomObject][ordered]@{
        projectCode = " LEGACY "
        projectName = $null
        secteur = "Ancien secteur"
        adminEmployeeCodes = "002;001"
        backupAdminEmployeeCode = "003"
        archived = "yes"
        futureField = "preserve-me"
    }
    $legacyPropertyNamesBefore = @($legacyProject.PSObject.Properties.Name)
    $normalized = Invoke-ProjectCatalogFunction -Name "ConvertTo-NormalizedProjectObject" -Arguments @{ Project = $legacyProject } -UseFacade $UseFacade
    Assert-Equal -Expected " LEGACY " -Actual $normalized.projectCode -Message "$Label rewrote the stored project code."
    Assert-Equal -Expected "" -Actual $normalized.projectName -Message "$Label changed null-name normalization."
    Assert-Equal -Expected "Ancien secteur" -Actual $normalized.sector -Message "$Label stopped reading the French legacy sector field."
    Assert-SequenceEqual -Expected @("001", "002") -Actual @($normalized.admins) -Message "$Label changed normalized admins."
    Assert-SequenceEqual -Expected @("003") -Actual @($normalized.backupAdmins) -Message "$Label changed normalized backup admins."
    Assert-Equal -Expected $true -Actual ([bool]$normalized.archived) -Message "$Label changed normalized archive state."
    Assert-Equal -Expected "indigo" -Actual $normalized.colorKey -Message "$Label stopped trimming catalog codes for fallback color selection."
    Assert-Equal -Expected "preserve-me" -Actual $normalized.futureField -Message "$Label discarded an unknown future field."
    Assert-SequenceEqual -Expected $legacyPropertyNamesBefore -Actual @($legacyProject.PSObject.Properties.Name) -Message "$Label mutated the source object's property set."
    Assert-Equal -Expected $false -Actual ($legacyProject.PSObject.Properties.Name -contains "sector") -Message "$Label added normalized fields to the source object."
    Assert-Equal -Expected $false -Actual ($legacyProject.PSObject.Properties.Name -contains "colorKey") -Message "$Label added a fallback color to the source object."

    $canonicalSector = Invoke-ProjectCatalogFunction -Name "ConvertTo-NormalizedProjectObject" -Arguments @{ Project = [PSCustomObject]@{ projectCode = "COLOR"; projectName = "Colored"; sector = ""; secteur = "ignored"; colorKey = " VIOLET " } } -UseFacade $UseFacade
    Assert-Equal -Expected "" -Actual $canonicalSector.sector -Message "$Label no longer gives the canonical sector property precedence."
    Assert-Equal -Expected "violet" -Actual $canonicalSector.colorKey -Message "$Label changed persisted color normalization."
    Assert-Equal -Expected $null -Actual (Invoke-ProjectCatalogFunction -Name "ConvertTo-NormalizedProjectObject" -Arguments @{ Project = $null } -UseFacade $UseFacade) -Message "$Label no longer accepts a null project."

    Assert-Equal -Expected "active" -Actual (Invoke-ProjectCatalogFunction -Name "ConvertTo-ProjectArchiveScope" -Arguments @{ Scope = $null } -UseFacade $UseFacade) -Message "$Label changed null scope defaulting."
    Assert-Equal -Expected "active" -Actual (Invoke-ProjectCatalogFunction -Name "ConvertTo-ProjectArchiveScope" -Arguments @{ Scope = "  " } -UseFacade $UseFacade) -Message "$Label changed blank scope defaulting."
    Assert-Equal -Expected "archived" -Actual (Invoke-ProjectCatalogFunction -Name "ConvertTo-ProjectArchiveScope" -Arguments @{ Scope = " ARCHIVED " } -UseFacade $UseFacade) -Message "$Label changed scope normalization."
    $invalidScopeRejected = $false
    try {
        Invoke-ProjectCatalogFunction -Name "ConvertTo-ProjectArchiveScope" -Arguments @{ Scope = "deleted" } -UseFacade $UseFacade | Out-Null
    }
    catch [System.ArgumentException] {
        $invalidScopeRejected = $_.Exception.Message -eq "Project scope must be active, archived, or all."
    }
    Assert-True -Condition $invalidScopeRejected -Message "$Label changed invalid-scope rejection."

    $legacyActive = [PSCustomObject]@{ projectCode = "LEGACY" }
    $active = [PSCustomObject]@{ projectCode = "ACTIVE"; archived = $false }
    $archived = [PSCustomObject]@{ projectCode = "ARCHIVED"; archived = $true }
    $projects = @($legacyActive, $active, $archived)
    Assert-SequenceEqual -Expected @("LEGACY", "ACTIVE") -Actual @((Invoke-ProjectCatalogFunction -Name "Select-ProjectsByArchiveScope" -Arguments @{ Projects = $projects; Scope = "active" } -UseFacade $UseFacade) | ForEach-Object { $_.projectCode }) -Message "$Label changed active filtering or order."
    Assert-SequenceEqual -Expected @("ARCHIVED") -Actual @((Invoke-ProjectCatalogFunction -Name "Select-ProjectsByArchiveScope" -Arguments @{ Projects = $projects; Scope = "archived" } -UseFacade $UseFacade) | ForEach-Object { $_.projectCode }) -Message "$Label changed archived filtering."
    Assert-SequenceEqual -Expected @("LEGACY", "ACTIVE", "ARCHIVED") -Actual @((Invoke-ProjectCatalogFunction -Name "Select-ProjectsByArchiveScope" -Arguments @{ Projects = $projects; Scope = "all" } -UseFacade $UseFacade) | ForEach-Object { $_.projectCode }) -Message "$Label changed all-project filtering or order."
    Assert-SequenceEqual -Expected @("LEGACY") -Actual @((Invoke-ProjectCatalogFunction -Name "Select-ProjectsByArchiveScope" -Arguments @{ Projects = $legacyActive; Scope = "active" } -UseFacade $UseFacade) | ForEach-Object { $_.projectCode }) -Message "$Label did not preserve a scalar singleton project."
    $nullSelection = @(Invoke-ProjectCatalogFunction -Name "Select-ProjectsByArchiveScope" -Arguments @{ Projects = $null; Scope = "active" } -UseFacade $UseFacade)
    Assert-Equal -Expected 1 -Actual $nullSelection.Count -Message "$Label changed the historical null-selection shape."
    Assert-Equal -Expected $null -Actual $nullSelection[0] -Message "$Label changed the historical null selection value."
}

foreach ($requiredPath in @($manifestPath, $modulePath, $commonHelpersPath, $analyticsServicePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("Required ProjectCatalog file is missing: {0}" -f $requiredPath)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.ProjectCatalog.psm1" -Actual ([string]$manifest.RootModule) -Message "The ProjectCatalog RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "ProjectCatalog must support Windows PowerShell 5.1."
Assert-SequenceEqual -Expected $expectedFunctions -Actual @($manifest.FunctionsToExport) -Message "The ProjectCatalog export contract changed."
foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($manifest.ContainsKey($emptyExportKey)) -Message ("The manifest must declare {0}." -f $emptyExportKey)
    Assert-Equal -Expected 0 -Actual @($manifest[$emptyExportKey]).Count -Message ("ProjectCatalog must not export {0}." -f $emptyExportKey)
}
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
Assert-Equal -Expected 0 -Actual @($moduleParseErrors).Count -Message "The ProjectCatalog module has parser errors."
$moduleFunctions = @($moduleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual @($moduleFunctions | Sort-Object) -Message "ProjectCatalog must contain exactly its public functions."

$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir", "projectsfile")
$implicitVariables = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
    $name = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
    if ($name.Contains(":")) { $name = $name.Substring($name.LastIndexOf(":") + 1) }
    return ($forbiddenCallerVariables -contains $name)
}, $true))
Assert-Equal -Expected 0 -Actual $implicitVariables.Count -Message "ProjectCatalog reads request, DATA, or caller-scope state."

$forbiddenCommands = @(
    "Get-Variable", "Get-Content", "Set-Content", "Add-Content", "Out-File",
    "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item",
    "Copy-Item", "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod", "Get-Date",
    "Read-JsonArrayFile", "Write-JsonAtomic", "Write-JsonArrayAtomic", "Acquire-ResourceLock"
)
$sideEffectCommands = @($moduleAst.FindAll({
    param($node)
    if (-not ($node -is [System.Management.Automation.Language.CommandAst])) { return $false }
    return ($forbiddenCommands -contains [string]$node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $sideEffectCommands.Count -Message "ProjectCatalog contains filesystem, network, clock, lock, or dynamic-scope commands."

Remove-Module -Name "Saphir.ProjectCatalog" -Force -ErrorAction SilentlyContinue
$firstModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
$firstExports = @($firstModule.ExportedCommands.Keys | Sort-Object)
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual $firstExports -Message "The first ProjectCatalog import exposed unexpected commands."
Assert-CatalogBehavior -UseFacade $false -Label "Pure module"
Assert-Equal -Expected "teal" -Actual (Saphir.ProjectCatalog\Get-ProjectColorKeyFromText -ProjectCodeText " P1 ") -Message "The raw color primitive trimmed analytics project text."
Assert-Equal -Expected "mint" -Actual (Saphir.ProjectCatalog\Get-ProjectColorKeyFromText -ProjectCodeText "P1") -Message "The raw color primitive changed its P1 golden value."

$secondModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
$secondExports = @($secondModule.ExportedCommands.Keys | Sort-Object)
Assert-SequenceEqual -Expected $firstExports -Actual $secondExports -Message "Repeated imports changed ProjectCatalog exports."
Assert-Equal -Expected 1 -Actual @(Get-Module -Name "Saphir.ProjectCatalog").Count -Message "Repeated imports left duplicate ProjectCatalog modules loaded."
Assert-CatalogBehavior -UseFacade $false -Label "Reimported pure module"

. $commonHelpersPath
Assert-CatalogBehavior -UseFacade $true -Label "CommonHelpers facade"
Assert-CatalogBehavior -UseFacade $false -Label "Module behind CommonHelpers"
foreach ($functionName in $facadeFunctions) {
    Assert-Equal -Expected "Function" -Actual ([string](Get-Command -Name $functionName -CommandType Function).CommandType) -Message ("CommonHelpers did not retain its {0} facade." -f $functionName)
}

# In server composition order, AnalyticsReportService must observe the already
# loaded module instead of force-importing it and replacing the historical
# global facade commands with module exports.
$moduleBeforeAnalytics = Get-Module -Name "Saphir.ProjectCatalog"
. $analyticsServicePath
$moduleAfterAnalytics = Get-Module -Name "Saphir.ProjectCatalog"
Assert-True -Condition ([object]::ReferenceEquals($moduleBeforeAnalytics, $moduleAfterAnalytics)) -Message "AnalyticsReportService reimported ProjectCatalog during normal server composition."
foreach ($functionName in $facadeFunctions) {
    Assert-Equal -Expected "Function" -Actual ([string](Get-Command -Name $functionName -CommandType Function).CommandType) -Message ("AnalyticsReportService replaced the CommonHelpers {0} facade." -f $functionName)
}
Assert-Equal -Expected "teal" -Actual (Get-AnalyticsReportProjectColorKey -ProjectCode " P1 " -ColorKey "unsupported") -Message "Analytics no longer preserves raw project-code whitespace hashing."
Assert-Equal -Expected "violet" -Actual (Get-AnalyticsReportProjectColorKey -ProjectCode " P1 " -ColorKey " VIOLET ") -Message "Analytics stopped normalizing a valid explicit color."

# The report service is also dot-sourced by focused tests. Validate that it can
# bootstrap the pure dependency by itself when CommonHelpers was not loaded.
Remove-Module -Name "Saphir.ProjectCatalog" -Force -ErrorAction SilentlyContinue
$standaloneResult = & {
    . $analyticsServicePath
    return [PSCustomObject]@{
        ModuleCount = @(Get-Module -Name "Saphir.ProjectCatalog").Count
        RawColor = Get-AnalyticsReportProjectColorKey -ProjectCode " P1 " -ColorKey "unsupported"
        ExplicitColor = Get-AnalyticsReportProjectColorKey -ProjectCode "P1" -ColorKey "mint"
    }
}
Assert-Equal -Expected 1 -Actual $standaloneResult.ModuleCount -Message "Standalone AnalyticsReportService did not load ProjectCatalog exactly once."
Assert-Equal -Expected "teal" -Actual $standaloneResult.RawColor -Message "Standalone AnalyticsReportService changed raw code hashing."
Assert-Equal -Expected "mint" -Actual $standaloneResult.ExplicitColor -Message "Standalone AnalyticsReportService changed explicit colors."

Remove-Module -Name "Saphir.ProjectCatalog" -Force -ErrorAction SilentlyContinue
Write-Host "Project catalog module tests passed: exact exports, pure behavior, legacy facade parity, and analytics load order."
