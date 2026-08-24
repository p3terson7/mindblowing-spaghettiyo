[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

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
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "Assertion failed: $Message Expected '$Expected', got '$Actual'."
    }
}

function Read-JsonPreservingRootArray {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Fixture JSON file is empty: $Path"
    }

    # ConvertFrom-Json unwraps a one-item root array in Windows PowerShell 5.1.
    # Nesting the fixture under a temporary property preserves both [] and [x].
    $wrapped = ("{{`"fixtureValue`":{0}}}" -f $raw) | ConvertFrom-Json -ErrorAction Stop
    return $wrapped.fixtureValue
}

function Get-FolderSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = (Get-Item -LiteralPath $Root -ErrorAction Stop).FullName
    $snapshot = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -ErrorAction Stop | Sort-Object FullName)) {
        $relativePath = $file.FullName.Substring($resolvedRoot.Length).TrimStart([char[]]@([char]92, [char]47))
        $snapshot[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $snapshot
}

function Assert-FolderSnapshotsEqual {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-Equal -Expected $Expected.Count -Actual $Actual.Count -Message "$Message File count changed."
    foreach ($relativePath in @($Expected.Keys)) {
        Assert-True -Condition $Actual.ContainsKey($relativePath) -Message "$Message '$relativePath' disappeared."
        Assert-Equal -Expected $Expected[$relativePath] -Actual $Actual[$relativePath] -Message "$Message '$relativePath' changed."
    }
}

function Assert-JsonArrayRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $raw = [System.IO.File]::ReadAllText($Path)
    Assert-True -Condition $raw.TrimStart().StartsWith("[") -Message $Message
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$fixtureRoot = Join-Path -Path $repoRoot -ChildPath "tests/fixtures/data-contract/reference-v1"
$productionDataRoot = Join-Path -Path $repoRoot -ChildPath "data"
$tempBase = [System.IO.Path]::GetTempPath()
$testRoot = Join-Path -Path $tempBase -ChildPath ("saphir-data-contract-fixtures-{0}" -f [Guid]::NewGuid().ToString("N"))
$testDataRoot = Join-Path -Path $testRoot -ChildPath "data"

Assert-True -Condition (Test-Path -LiteralPath $fixtureRoot -PathType Container) -Message "The reference DATA fixture is missing."
Assert-True -Condition (-not [string]::Equals($fixtureRoot, $productionDataRoot, [StringComparison]::OrdinalIgnoreCase)) -Message "The fixture must not point to the production DATA folder."
Assert-True -Condition $testRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -Message "The isolated test directory must be under the operating-system temp folder."
Assert-True -Condition (-not [string]::Equals($testDataRoot, $productionDataRoot, [StringComparison]::OrdinalIgnoreCase)) -Message "The test copy must not point to the production DATA folder."

$fixtureBefore = Get-FolderSnapshot -Root $fixtureRoot

try {
    New-Item -ItemType Directory -Path $testDataRoot -Force | Out-Null
    foreach ($fixtureItem in @(Get-ChildItem -LiteralPath $fixtureRoot -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $fixtureItem.FullName -Destination $testDataRoot -Recurse -Force
    }

    $employeeFiles = @(Get-ChildItem -LiteralPath $testDataRoot -Filter "*_data.json" -File -ErrorAction Stop | Sort-Object Name)
    Assert-Equal -Expected 5 -Actual $employeeFiles.Count -Message "The fixture must contain all five employee cardinality/compatibility scenarios."

    $zeroPath = Join-Path -Path $testDataRoot -ChildPath "000000100_data.json"
    Assert-JsonArrayRoot -Path $zeroPath -Message "The zero-entry fixture must use a JSON array root."
    Assert-Equal -Expected 0 -Actual @(Read-JsonPreservingRootArray -Path $zeroPath).Count -Message "The zero-entry employee is not empty."

    $onePath = Join-Path -Path $testDataRoot -ChildPath "000000101_data.json"
    Assert-JsonArrayRoot -Path $onePath -Message "The one-entry fixture must preserve an explicit JSON array root."
    $oneEntries = @(Read-JsonPreservingRootArray -Path $onePath)
    Assert-Equal -Expected 1 -Actual $oneEntries.Count -Message "The one-entry array fixture has the wrong cardinality."
    Assert-Equal -Expected "fixture-array-singleton-001" -Actual ([string]$oneEntries[0].entryId) -Message "The one-entry fixture lost its stable entry ID."

    $multiplePath = Join-Path -Path $testDataRoot -ChildPath "000000102_data.json"
    Assert-JsonArrayRoot -Path $multiplePath -Message "The multiple-entry fixture must use a JSON array root."
    $multipleEntries = @(Read-JsonPreservingRootArray -Path $multiplePath)
    Assert-Equal -Expected 3 -Actual $multipleEntries.Count -Message "The multiple-entry fixture has the wrong cardinality."
    Assert-Equal -Expected 3 -Actual @($multipleEntries | ForEach-Object { [string]$_.entryId } | Select-Object -Unique).Count -Message "The multiple-entry fixture IDs are not unique."

    $activePath = Join-Path -Path $testDataRoot -ChildPath "000000103_data.json"
    Assert-JsonArrayRoot -Path $activePath -Message "The active-entry fixture must use a JSON array root."
    $activeEntries = @(Read-JsonPreservingRootArray -Path $activePath)
    Assert-Equal -Expected 1 -Actual $activeEntries.Count -Message "The active-entry fixture has the wrong cardinality."
    Assert-True -Condition ($null -eq $activeEntries[0].punchOut) -Message "The active-entry fixture unexpectedly has a punch-out."
    Assert-True -Condition ($null -eq $activeEntries[0].overtime) -Message "The active-entry fixture unexpectedly has a completed duration."

    $legacyPath = Join-Path -Path $testDataRoot -ChildPath "000321928_data.json"
    $legacyText = [System.IO.File]::ReadAllText($legacyPath)
    Assert-True -Condition $legacyText.TrimStart().StartsWith("{") -Message "The legacy singleton fixture must retain its JSON object root."
    $legacyEntry = Read-JsonPreservingRootArray -Path $legacyPath
    foreach ($newerOptionalProperty in @("entryType", "exactPunchIn", "exactPunchOut", "workComment", "diverseReason", "diverseSummary")) {
        Assert-True -Condition (-not ($legacyEntry.PSObject.Properties.Name -contains $newerOptionalProperty)) -Message "The legacy fixture unexpectedly contains newer field '$newerOptionalProperty'."
    }

    . (Join-Path -Path $repoRoot -ChildPath "app/backend/services/EntryService.ps1")
    $normalizedLegacyEntry = Convert-ToNormalizedEntryObject -Entry $legacyEntry
    Assert-Equal -Expected "overtime" -Actual ([string]$normalizedLegacyEntry.entryType) -Message "A legacy entry without entryType no longer defaults to overtime."
    Assert-Equal -Expected ([string]$legacyEntry.punchIn) -Actual ([string]$normalizedLegacyEntry.exactPunchIn) -Message "Legacy exact punch-in fallback changed."
    Assert-Equal -Expected ([string]$legacyEntry.punchOut) -Actual ([string]$normalizedLegacyEntry.exactPunchOut) -Message "Legacy exact punch-out fallback changed."
    Assert-Equal -Expected "" -Actual ([string]$normalizedLegacyEntry.workComment) -Message "A missing legacy workComment no longer defaults to an empty string."

    $projects = @(Read-JsonPreservingRootArray -Path (Join-Path -Path $testDataRoot -ChildPath "projects.json"))
    Assert-Equal -Expected 2 -Actual $projects.Count -Message "The project fixture must contain one active and one archived project."
    $activeProject = @($projects | Where-Object { [string]$_.projectCode -eq "P-ACT" })[0]
    $archivedProject = @($projects | Where-Object { [string]$_.projectCode -eq "P-ARC" })[0]
    Assert-True -Condition ($null -ne $activeProject -and -not [bool]$activeProject.archived) -Message "The active project fixture is missing or archived."
    Assert-True -Condition ($null -ne $archivedProject -and [bool]$archivedProject.archived) -Message "The archived project fixture is missing or active."

    $testCopyBeforeContract = Get-FolderSnapshot -Root $testDataRoot
    $contractOutput = @(& (Join-Path -Path $scriptRoot -ChildPath "test-data-folder-contract.ps1") -DataFolderPath $testDataRoot)
    $contract = (($contractOutput -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop)
    Assert-True -Condition ([string]$contract.status -like "compatible*") -Message "The production DATA preflight rejected the reference fixture."
    Assert-Equal -Expected 2 -Actual ([int]$contract.projectCount) -Message "The production DATA preflight counted projects incorrectly."
    Assert-Equal -Expected 5 -Actual ([int]$contract.employeeFileCount) -Message "The production DATA preflight counted employee files incorrectly."
    Assert-Equal -Expected 6 -Actual ([int]$contract.entryCount) -Message "The production DATA preflight counted fixture entries incorrectly."
    Assert-True -Condition ([int]$contract.legacySingletonFiles -ge 1) -Message "The production DATA preflight did not recognize legacy singleton compatibility."

    $testCopyAfterContract = Get-FolderSnapshot -Root $testDataRoot
    Assert-FolderSnapshotsEqual -Expected $testCopyBeforeContract -Actual $testCopyAfterContract -Message "The read-only DATA preflight modified its temporary fixture copy."

    $fixtureAfter = Get-FolderSnapshot -Root $fixtureRoot
    Assert-FolderSnapshotsEqual -Expected $fixtureBefore -Actual $fixtureAfter -Message "The immutable repository fixture was modified."

    Write-Host "DATA contract fixture tests passed: zero, one, many, active, legacy, active-project, and archived-project scenarios are valid."
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
