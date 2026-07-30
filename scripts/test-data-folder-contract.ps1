[CmdletBinding()]
param(
    [string]$DataFolderPath = ""
)

$ErrorActionPreference = "Stop"
$supportedSchemaVersion = 1
$minimumSchemaVersion = 1

function Read-JsonStrict {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "JSON file is empty: $Path"
    }

    try {
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Invalid JSON in '$Path': $($_.Exception.Message)"
    }
}

function ConvertTo-RecordArray {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) {
        return @($Value)
    }
    if ($Value.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject") {
        # Compatibility with SAPHIR releases that stored a one-item collection
        # as a JSON object.
        return @($Value)
    }

    throw "Expected a JSON object or array of objects in '$Path'."
}

function Assert-UniqueTextProperty {
    param(
        [Parameter(Mandatory = $true)]$Records,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$AllowBlank = $false
    )

    $seen = @{}
    foreach ($record in @($Records)) {
        if ($null -eq $record -or -not ($record.PSObject.Properties.Name -contains $PropertyName)) {
            if ($AllowBlank) {
                continue
            }
            throw "Record in '$Path' is missing '$PropertyName'."
        }

        $value = ([string]$record.PSObject.Properties[$PropertyName].Value).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($AllowBlank) {
                continue
            }
            throw "Record in '$Path' has an empty '$PropertyName'."
        }

        $key = $value.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "Duplicate '$PropertyName' value '$value' in '$Path'."
        }
        $seen[$key] = $true
    }
}

$repoRoot = (Get-Item -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$resolvedDataFolder = if ([string]::IsNullOrWhiteSpace($DataFolderPath)) {
    Join-Path -Path $repoRoot -ChildPath "data"
}
elseif ([System.IO.Path]::IsPathRooted($DataFolderPath)) {
    [System.IO.Path]::GetFullPath($DataFolderPath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $DataFolderPath))
}

if (-not (Test-Path -LiteralPath $resolvedDataFolder -PathType Container)) {
    throw "Data folder was not found: $resolvedDataFolder"
}

$filesBefore = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $resolvedDataFolder -File -ErrorAction Stop)) {
    $filesBefore[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

$warnings = New-Object System.Collections.ArrayList
$projectsPath = Join-Path -Path $resolvedDataFolder -ChildPath "projects.json"
$usersPath = Join-Path -Path $resolvedDataFolder -ChildPath "users.json"
$sessionsPath = Join-Path -Path $resolvedDataFolder -ChildPath "sessions.json"
$mappingPath = Join-Path -Path $resolvedDataFolder -ChildPath "employeeNames.json"
$schemaPath = Join-Path -Path $resolvedDataFolder -ChildPath "data-schema.json"

$projects = @()
if (Test-Path -LiteralPath $projectsPath -PathType Leaf) {
    $projects = @(ConvertTo-RecordArray -Value (Read-JsonStrict -Path $projectsPath) -Path $projectsPath)
    Assert-UniqueTextProperty -Records $projects -PropertyName "projectCode" -Path $projectsPath
}

$users = @()
if (Test-Path -LiteralPath $usersPath -PathType Leaf) {
    $users = @(ConvertTo-RecordArray -Value (Read-JsonStrict -Path $usersPath) -Path $usersPath)
    Assert-UniqueTextProperty -Records $users -PropertyName "username" -Path $usersPath
}

$sessions = @()
if (Test-Path -LiteralPath $sessionsPath -PathType Leaf) {
    $sessions = @(ConvertTo-RecordArray -Value (Read-JsonStrict -Path $sessionsPath) -Path $sessionsPath)
    Assert-UniqueTextProperty -Records $sessions -PropertyName "tokenHash" -Path $sessionsPath -AllowBlank:$true
}

if (Test-Path -LiteralPath $mappingPath -PathType Leaf) {
    $mapping = Read-JsonStrict -Path $mappingPath
    if ($null -eq $mapping -or
        -not ($mapping.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject")) {
        throw "Employee-name mapping must be a JSON object: $mappingPath"
    }
}

foreach ($collectionName in @("history.json", "overtimeCodes.json", "paymentOptions.json", "reasonCodes.json")) {
    $collectionPath = Join-Path -Path $resolvedDataFolder -ChildPath $collectionName
    if (Test-Path -LiteralPath $collectionPath -PathType Leaf) {
        [void]@(ConvertTo-RecordArray -Value (Read-JsonStrict -Path $collectionPath) -Path $collectionPath)
    }
}

if (Test-Path -LiteralPath $schemaPath -PathType Leaf) {
    $schema = Read-JsonStrict -Path $schemaPath
    $schemaVersion = 0
    if ($null -eq $schema -or
        [string]$schema.format -ne "SAPHIR" -or
        -not [int]::TryParse([string]$schema.schemaVersion, [ref]$schemaVersion) -or
        $schemaVersion -lt $minimumSchemaVersion) {
        throw "Invalid SAPHIR data-schema metadata: $schemaPath"
    }

    $minimumReaderVersion = $minimumSchemaVersion
    if ($schema.PSObject.Properties.Name -contains "minimumReaderVersion" -and
        (-not [int]::TryParse([string]$schema.minimumReaderVersion, [ref]$minimumReaderVersion) -or
        $minimumReaderVersion -lt $minimumSchemaVersion)) {
        throw "Invalid SAPHIR minimum reader version in: $schemaPath"
    }
    if ($schemaVersion -gt $supportedSchemaVersion -or
        $minimumReaderVersion -gt $supportedSchemaVersion) {
        throw "This data folder uses SAPHIR schema $schemaVersion, but this application supports only schema $supportedSchemaVersion. The folder was not modified."
    }
}
else {
    [void]$warnings.Add("No data-schema.json is present yet; the current release will adopt this legacy folder as schema 1.")
}

$projectCodeSet = @{}
foreach ($project in $projects) {
    $projectCodeSet[([string]$project.projectCode).Trim().ToLowerInvariant()] = $true
}

$entryCount = 0
$legacySingletonFiles = 0
$orphanProjectReferences = New-Object System.Collections.ArrayList
$employeeFiles = @(Get-ChildItem -LiteralPath $resolvedDataFolder -Filter "*_data.json" -File -ErrorAction Stop | Sort-Object Name)
foreach ($employeeFile in $employeeFiles) {
    if ($employeeFile.Name -notmatch "^\d+_data\.json$") {
        throw "Employee data filename is not safe/canonical: $($employeeFile.Name)"
    }

    $parsed = Read-JsonStrict -Path $employeeFile.FullName
    if ($parsed -isnot [System.Array] -and $parsed -isnot [System.Collections.IList] -and $null -ne $parsed) {
        $legacySingletonFiles++
    }
    $entries = @(ConvertTo-RecordArray -Value $parsed -Path $employeeFile.FullName)
    Assert-UniqueTextProperty -Records $entries -PropertyName "entryId" -Path $employeeFile.FullName -AllowBlank:$true

    foreach ($entry in $entries) {
        $entryCount++
        $entryType = if ($entry.PSObject.Properties.Name -contains "entryType") { ([string]$entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }
        $projectCode = if ($entry.PSObject.Properties.Name -contains "projectCode") { ([string]$entry.projectCode).Trim() } else { "" }
        if ($entryType -ne "diverse" -and
            -not [string]::IsNullOrWhiteSpace($projectCode) -and
            -not $projectCodeSet.ContainsKey($projectCode.ToLowerInvariant())) {
            [void]$orphanProjectReferences.Add(("{0}:{1}" -f $employeeFile.Name, $projectCode))
        }
    }
}

if ($legacySingletonFiles -gt 0) {
    [void]$warnings.Add("$legacySingletonFiles employee file(s) use the legacy one-object root. They are supported and will become arrays on their next successful write.")
}
if ($orphanProjectReferences.Count -gt 0) {
    [void]$warnings.Add(("{0} entry reference(s) use project codes missing from projects.json: {1}" -f
        $orphanProjectReferences.Count,
        (@($orphanProjectReferences.ToArray()) -join ", ")))
}

$temporaryArtifacts = @(Get-ChildItem -LiteralPath $resolvedDataFolder -File -ErrorAction Stop | Where-Object { $_.Name -match "\.tmp\." })
if ($temporaryArtifacts.Count -gt 0) {
    [void]$warnings.Add("$($temporaryArtifacts.Count) abandoned temporary file(s) were found. They are ignored by SAPHIR but should be reviewed before cleanup.")
}

$filesAfter = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $resolvedDataFolder -File -ErrorAction Stop)) {
    $filesAfter[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}
if ($filesBefore.Count -ne $filesAfter.Count) {
    throw "The read-only contract test unexpectedly changed the number of files."
}
foreach ($path in $filesBefore.Keys) {
    if (-not $filesAfter.ContainsKey($path) -or $filesAfter[$path] -ne $filesBefore[$path]) {
        throw "The read-only contract test unexpectedly modified '$path'."
    }
}

$result = [PSCustomObject]@{
    status               = if ($warnings.Count -gt 0) { "compatible-with-warnings" } else { "compatible" }
    dataFolder           = $resolvedDataFolder
    projectCount         = $projects.Count
    userCount            = $users.Count
    sessionCount         = $sessions.Count
    employeeFileCount    = $employeeFiles.Count
    entryCount           = $entryCount
    legacySingletonFiles = $legacySingletonFiles
    warnings             = @($warnings.ToArray())
}

$result | ConvertTo-Json -Depth 6
