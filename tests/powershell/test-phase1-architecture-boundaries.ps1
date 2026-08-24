$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.Routing.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.Routing.psm1"

$expectedFunctions = @(
    "Get-AdminRouteScriptPaths",
    "Resolve-AdminTopLevelRouteScript",
    "Resolve-EmployeeRouteScript",
    "Resolve-ProjectRouteScript",
    "Resolve-ProjectStatsRouteScript"
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
    if ($expectedItems.Count -ne $actualItems.Count) {
        throw ("{0} Expected {1} item(s), found {2}." -f $Message, $expectedItems.Count, $actualItems.Count)
    }

    for ($index = 0; $index -lt $expectedItems.Count; $index++) {
        if ([string]$expectedItems[$index] -cne [string]$actualItems[$index]) {
            throw ("{0} Difference at index {1}: expected '{2}', found '{3}'." -f $Message, $index, $expectedItems[$index], $actualItems[$index])
        }
    }
}

function Get-CaseInsensitiveDuplicates {
    param([AllowEmptyCollection()][object[]]$Values)

    return @(
        @($Values) |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Group-Object |
            Where-Object { $_.Count -gt 1 } |
            ForEach-Object { [string]$_.Name }
    )
}

function Invoke-RoutingProbe {
    return [PSCustomObject]@{
        Frontend = & "Saphir.Routing\Resolve-AdminTopLevelRouteScript" -Method "GET" -Path "/scripts/AppShell.js"
        Employee = & "Saphir.Routing\Resolve-EmployeeRouteScript" -Method "POST" -Path "/employee/approval/000000001"
        Project  = & "Saphir.Routing\Resolve-ProjectRouteScript" -Method "POST" -Path "/projects/ABC-1/restore"
        Stats    = & "Saphir.Routing\Resolve-ProjectStatsRouteScript" -Method "GET" -Path "/stats/analytics-export"
        Unknown  = & "Saphir.Routing\Resolve-AdminTopLevelRouteScript" -Method "GET" -Path "/not-a-route"
    }
}

Assert-True -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Message "The Saphir.Routing manifest is missing."
Assert-True -Condition (Test-Path -LiteralPath $modulePath -PathType Leaf) -Message "The Saphir.Routing root module is missing."

# Inspect the raw manifest as data so wildcard or accidental implicit exports
# cannot be hidden by Import-Module's resolved command table.
$rawManifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.Routing.psm1" -Actual ([string]$rawManifest.RootModule) -Message "The routing RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$rawManifest.PowerShellVersion) -Message "The routing module must remain loadable by Windows PowerShell 5.1."

$declaredFunctions = @($rawManifest.FunctionsToExport | ForEach-Object { [string]$_ })
Assert-SequenceEqual -Expected $expectedFunctions -Actual $declaredFunctions -Message "The routing manifest export contract changed."
Assert-True -Condition ((Get-CaseInsensitiveDuplicates -Values $declaredFunctions).Count -eq 0) -Message "The routing manifest contains duplicate function exports."
Assert-True -Condition (-not ($declaredFunctions | Where-Object { $_ -match '[*?\[]' })) -Message "The routing manifest must not use wildcard function exports."

foreach ($emptyExportKey in @("CmdletsToExport", "VariablesToExport", "AliasesToExport")) {
    Assert-True -Condition ($rawManifest.ContainsKey($emptyExportKey)) -Message ("The routing manifest must explicitly define {0}." -f $emptyExportKey)
    Assert-True -Condition (@($rawManifest[$emptyExportKey]).Count -eq 0) -Message ("The routing module must not export {0}." -f $emptyExportKey)
}

$validatedManifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Assert-Equal -Expected "1.0.0" -Actual ([string]$validatedManifest.Version) -Message "The initial routing module version changed unexpectedly."

# Parse the actual PowerShell AST instead of scanning comments or string
# literals. Pure modules must not reach into the request loop's dynamic scope.
$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $modulePath,
    [ref]$moduleTokens,
    [ref]$moduleParseErrors
)
Assert-True -Condition (@($moduleParseErrors).Count -eq 0) -Message ("The routing module has PowerShell parser errors: {0}" -f ((@($moduleParseErrors) | ForEach-Object { $_.Message }) -join "; "))

$forbiddenCallerVariables = @("request", "response", "currentuser", "sharedfolder", "scriptdir")
$implicitVariableReferences = @(
    $moduleAst.FindAll({
        param($node)
        if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) {
            return $false
        }

        $variableName = ([string]$node.VariablePath.UserPath).ToLowerInvariant()
        if ($variableName.Contains(":")) {
            $variableName = $variableName.Substring($variableName.LastIndexOf(":") + 1)
        }
        return ($forbiddenCallerVariables -contains $variableName)
    }, $true)
)
Assert-True -Condition ($implicitVariableReferences.Count -eq 0) -Message ("The routing module depends on caller-scope variable(s): {0}" -f ((@($implicitVariableReferences) | ForEach-Object { $_.Extent.Text } | Select-Object -Unique) -join ", "))

$dynamicVariableLookups = @(
    $moduleAst.FindAll({
        param($node)
        if (-not ($node -is [System.Management.Automation.Language.CommandAst])) {
            return $false
        }
        $commandName = [string]$node.GetCommandName()
        return ($commandName -ieq "Get-Variable" -or $commandName -ieq "gv")
    }, $true)
)
Assert-True -Condition ($dynamicVariableLookups.Count -eq 0) -Message "The routing module must not use Get-Variable to recover caller state."

# Repeated imports must expose one stable API and one stable catalog. Importing
# with -Force exercises the reload path used by compatibility scripts and tests.
Remove-Module -Name "Saphir.Routing" -Force -ErrorAction SilentlyContinue
$firstModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
$firstExports = @($firstModule.ExportedCommands.Keys | Sort-Object)
Assert-SequenceEqual -Expected @($expectedFunctions | Sort-Object) -Actual $firstExports -Message "The first import exposed unexpected commands."
$firstCatalog = @(& "Saphir.Routing\Get-AdminRouteScriptPaths")
$firstProbe = Invoke-RoutingProbe

$secondModule = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
$secondExports = @($secondModule.ExportedCommands.Keys | Sort-Object)
$secondCatalog = @(& "Saphir.Routing\Get-AdminRouteScriptPaths")
$secondProbe = Invoke-RoutingProbe

Assert-SequenceEqual -Expected $firstExports -Actual $secondExports -Message "Repeated routing imports changed the public commands."
Assert-SequenceEqual -Expected $firstCatalog -Actual $secondCatalog -Message "Repeated routing imports changed the route catalog."
Assert-Equal -Expected ($firstProbe | ConvertTo-Json -Compress) -Actual ($secondProbe | ConvertTo-Json -Compress) -Message "Repeated routing imports changed routing decisions."
Assert-True -Condition (@(Get-Module -Name "Saphir.Routing").Count -eq 1) -Message "Repeated imports left more than one Saphir.Routing module loaded."

Assert-True -Condition ($firstCatalog.Count -eq 34) -Message ("The routing catalog must contain the 34 current route scripts; found {0}." -f $firstCatalog.Count)
$catalogDuplicates = @(Get-CaseInsensitiveDuplicates -Values $firstCatalog)
Assert-True -Condition ($catalogDuplicates.Count -eq 0) -Message ("The routing catalog contains duplicate path(s): {0}" -f ($catalogDuplicates -join ", "))

$backendRootFullPath = [System.IO.Path]::GetFullPath($backendRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$backendRootPrefix = $backendRootFullPath + [System.IO.Path]::DirectorySeparatorChar
foreach ($relativeRoutePath in $firstCatalog) {
    $routePath = [string]$relativeRoutePath
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($routePath)) -Message "The routing catalog contains an empty path."
    Assert-True -Condition (-not [System.IO.Path]::IsPathRooted($routePath)) -Message ("The routing catalog path must be relative: {0}" -f $routePath)
    Assert-True -Condition ($routePath -match '^routes[/\\].+\.ps1$') -Message ("The routing catalog path is outside the routes convention: {0}" -f $routePath)

    $resolvedRoutePath = [System.IO.Path]::GetFullPath((Join-Path -Path $backendRoot -ChildPath $routePath))
    Assert-True -Condition ($resolvedRoutePath.StartsWith($backendRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) -Message ("The routing catalog escapes the backend root: {0}" -f $routePath)
    Assert-True -Condition (Test-Path -LiteralPath $resolvedRoutePath -PathType Leaf) -Message ("The routing catalog references a missing file: {0}" -f $routePath)
}

$discoveredRoutePaths = @(
    Get-ChildItem -LiteralPath (Join-Path -Path $backendRoot -ChildPath "routes") -Recurse -File -Filter "*.ps1" |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($backendRootFullPath.Length + 1)
            $relativePath.Replace([System.IO.Path]::DirectorySeparatorChar, "/")
        } |
        Sort-Object
)
$catalogPathsSorted = @($firstCatalog | ForEach-Object { ([string]$_).Replace("\", "/") } | Sort-Object)
Assert-SequenceEqual -Expected $discoveredRoutePaths -Actual $catalogPathsSorted -Message "The routing catalog and the route files on disk differ."

# Node's parser provides a robust syntax guard for complete application files.
# Vendor bundles are third-party artifacts and are intentionally excluded.
$nodeCommand = Get-Command -Name "node" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
Assert-True -Condition ($null -ne $nodeCommand) -Message "Node.js is required to validate frontend JavaScript syntax."
$nodeExecutable = [string]$nodeCommand.Source
if ([string]::IsNullOrWhiteSpace($nodeExecutable)) {
    $nodeExecutable = [string]$nodeCommand.Path
}

$frontendScriptRoot = Join-Path -Path $repoRoot -ChildPath "app/frontend/scripts"
$javascriptFiles = @(Get-ChildItem -LiteralPath $frontendScriptRoot -Recurse -File -Filter "*.js" | Sort-Object FullName)
Assert-True -Condition ($javascriptFiles.Count -gt 0) -Message "No frontend application JavaScript files were found."
foreach ($javascriptFile in $javascriptFiles) {
    $syntaxOutput = @(& $nodeExecutable --check $javascriptFile.FullName 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("Frontend JavaScript syntax validation failed for {0}: {1}" -f $javascriptFile.FullName, ($syntaxOutput -join [Environment]::NewLine))
    }
}

Remove-Module -Name "Saphir.Routing" -Force -ErrorAction SilentlyContinue
Write-Host ("Phase 1 architecture boundary tests passed: {0} exports, {1} routes, {2} frontend scripts." -f $expectedFunctions.Count, $firstCatalog.Count, $javascriptFiles.Count)
