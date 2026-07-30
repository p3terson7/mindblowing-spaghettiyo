$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "Assertion failed: $Message Expected '$Expected', got '$Actual'."
    }
}

function Ensure-TestDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-TestFileSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $snapshot = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction Stop)) {
        $relativePath = $file.FullName.Substring($Root.Length).TrimStart([char[]]@([char]92, [char]47))
        $snapshot[$relativePath] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
    }
    return $snapshot
}

function Assert-TestFileSnapshotsEqual {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-Equal -Expected $Expected.Count -Actual $Actual.Count -Message "$Message File count changed."
    foreach ($relativePath in $Expected.Keys) {
        Assert-True -Condition $Actual.ContainsKey($relativePath) -Message "$Message File '$relativePath' disappeared."
        Assert-Equal -Expected $Expected[$relativePath] -Actual $Actual[$relativePath] -Message "$Message File '$relativePath' changed."
    }
}

function Write-TestAdminConfig {
    param(
        [Parameter(Mandatory = $true)][string]$BackendPath,
        [Parameter(Mandatory = $true)][string]$DataFolderPath
    )

    $safeDataFolderPath = $DataFolderPath.Replace("'", "''")
    $content = @"
@{
    ListenerPrefix = "http://localhost:8081/"
    DataFolderPath = '$safeDataFolderPath'
    EnableDemoSeed = `$false
    EnableGc179Import = `$true
}
"@
    [System.IO.File]::WriteAllText(
        (Join-Path -Path $BackendPath -ChildPath "admin-config.psd1"),
        $content,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Invoke-TestAdminContext {
    param([Parameter(Mandatory = $true)][string]$BackendPath)

    & {
        param([string]$FixtureBackendPath)

        $scriptDir = $FixtureBackendPath
        . (Join-Path -Path $FixtureBackendPath -ChildPath "lib/AdminContext.ps1")
    } $BackendPath
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-schema-integration-{0}" -f [Guid]::NewGuid().ToString("N"))
$fixtureBackend = Join-Path -Path $testRoot -ChildPath "fixture/apps/admin/backend"
$fixtureLib = Join-Path -Path $fixtureBackend -ChildPath "lib"
$fixtureServices = Join-Path -Path $fixtureBackend -ChildPath "services"
$legacyFolder = Join-Path -Path $testRoot -ChildPath "legacy-data"
$futureFolder = Join-Path -Path $testRoot -ChildPath "future-data"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    Ensure-TestDirectory -Path $fixtureLib
    Ensure-TestDirectory -Path $fixtureServices
    Ensure-TestDirectory -Path $legacyFolder
    Ensure-TestDirectory -Path $futureFolder

    Copy-Item `
        -LiteralPath (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/AdminContext.ps1") `
        -Destination (Join-Path -Path $fixtureLib -ChildPath "AdminContext.ps1") `
        -Force
    Copy-Item `
        -LiteralPath (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1") `
        -Destination (Join-Path -Path $fixtureLib -ChildPath "FileStore.ps1") `
        -Force
    Copy-Item `
        -LiteralPath (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/DataSchemaService.ps1") `
        -Destination (Join-Path -Path $fixtureServices -ChildPath "DataSchemaService.ps1") `
        -Force

    $legacyProjectsPath = Join-Path -Path $legacyFolder -ChildPath "projects.json"
    $legacyEmployeePath = Join-Path -Path $legacyFolder -ChildPath "000321928_data.json"
    $legacyProjectsText = "[`r`n  {`"projectCode`":`"LEGACY`",`"projectName`":`"Do not rewrite`",`"futureField`":42}`r`n]`r`n"
    $legacyEmployeeText = "{`r`n  `"entryId`": `"only-entry`",`r`n  `"projectCode`": `"LEGACY`"`r`n}`r`n"
    [System.IO.File]::WriteAllText($legacyProjectsPath, $legacyProjectsText, $utf8NoBom)
    [System.IO.File]::WriteAllText($legacyEmployeePath, $legacyEmployeeText, $utf8NoBom)
    $legacyBusinessBefore = @{
        "projects.json" = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($legacyProjectsPath))
        "000321928_data.json" = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($legacyEmployeePath))
    }

    Write-TestAdminConfig -BackendPath $fixtureBackend -DataFolderPath $legacyFolder
    Invoke-TestAdminContext -BackendPath $fixtureBackend

    $schemaPath = Join-Path -Path $legacyFolder -ChildPath "data-schema.json"
    Assert-True -Condition (Test-Path -LiteralPath $schemaPath -PathType Leaf) -Message "legacy startup did not create data-schema.json"
    $schema = [System.IO.File]::ReadAllText($schemaPath) | ConvertFrom-Json -ErrorAction Stop
    Assert-Equal -Expected "SAPHIR" -Actual ([string]$schema.format) -Message "legacy adoption wrote the wrong data format"
    Assert-Equal -Expected 1 -Actual ([int]$schema.schemaVersion) -Message "legacy adoption did not select schema 1"
    Assert-Equal `
        -Expected $legacyBusinessBefore["projects.json"] `
        -Actual ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($legacyProjectsPath))) `
        -Message "legacy adoption rewrote projects.json"
    Assert-Equal `
        -Expected $legacyBusinessBefore["000321928_data.json"] `
        -Actual ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($legacyEmployeePath))) `
        -Message "legacy adoption rewrote the employee file"

    $adoptedSnapshot = Get-TestFileSnapshot -Root $legacyFolder
    Invoke-TestAdminContext -BackendPath $fixtureBackend
    $secondStartupSnapshot = Get-TestFileSnapshot -Root $legacyFolder
    Assert-TestFileSnapshotsEqual `
        -Expected $adoptedSnapshot `
        -Actual $secondStartupSnapshot `
        -Message "reopening an adopted legacy folder was not idempotent."

    $futureSchemaText = "{`r`n  `"format`": `"SAPHIR`",`r`n  `"schemaVersion`": 2,`r`n  `"minimumReaderVersion`": 2`r`n}`r`n"
    $futureEmployeePath = Join-Path -Path $futureFolder -ChildPath "000111222_data.json"
    [System.IO.File]::WriteAllText((Join-Path -Path $futureFolder -ChildPath "data-schema.json"), $futureSchemaText, $utf8NoBom)
    [System.IO.File]::WriteAllText($futureEmployeePath, "[{`"entryId`":`"future-entry`",`"futureField`":true}]", $utf8NoBom)
    $futureSnapshotBefore = Get-TestFileSnapshot -Root $futureFolder

    Write-TestAdminConfig -BackendPath $fixtureBackend -DataFolderPath $futureFolder
    $futureSchemaError = ""
    try {
        Invoke-TestAdminContext -BackendPath $fixtureBackend
    }
    catch {
        $futureSchemaError = [string]$_.Exception.Message
    }

    Assert-True -Condition ($futureSchemaError -match "supports only schema 1") -Message "AdminContext did not fail closed on a future data schema"
    $futureSnapshotAfter = Get-TestFileSnapshot -Root $futureFolder
    Assert-TestFileSnapshotsEqual `
        -Expected $futureSnapshotBefore `
        -Actual $futureSnapshotAfter `
        -Message "future-schema refusal modified the data folder."
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $futureFolder -ChildPath ".locks"))) -Message "future-schema refusal mutated the folder before compatibility was established"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $futureFolder -ChildPath "history.json"))) -Message "future-schema refusal initialized baseline business files"

    $futureContractError = ""
    try {
        & (Join-Path -Path $repoRoot -ChildPath "scripts/test-data-folder-contract.ps1") -DataFolderPath $futureFolder | Out-Null
    }
    catch {
        $futureContractError = [string]$_.Exception.Message
    }
    Assert-True -Condition ($futureContractError -match "supports only schema 1") -Message "the read-only preflight disagreed with the backend about a future schema"
    $futureSnapshotAfterContract = Get-TestFileSnapshot -Root $futureFolder
    Assert-TestFileSnapshotsEqual `
        -Expected $futureSnapshotBefore `
        -Actual $futureSnapshotAfterContract `
        -Message "future-schema preflight modified the data folder."

    $invalidMinimumSchemaPath = Join-Path -Path $futureFolder -ChildPath "data-schema.json"
    [System.IO.File]::WriteAllText(
        $invalidMinimumSchemaPath,
        '{"format":"SAPHIR","schemaVersion":1,"minimumReaderVersion":0}',
        $utf8NoBom
    )
    $script:TextFileCache = @{}
    $script:BinaryFileCache = @{}
    $script:FileMetadataCache = @{}
    Write-TestAdminConfig -BackendPath $fixtureBackend -DataFolderPath $futureFolder
    $invalidMinimumError = ""
    try {
        Invoke-TestAdminContext -BackendPath $fixtureBackend
    }
    catch {
        $invalidMinimumError = [string]$_.Exception.Message
    }
    Assert-True -Condition ($invalidMinimumError -match "minimum reader version is invalid") -Message "invalid minimum-reader metadata was accepted"

    Write-Host "Data schema integration tests passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
