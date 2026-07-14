$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path
$publisherPath = Join-Path -Path $repoRoot -ChildPath "scripts/package-app.ps1"

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
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $caughtMessage = ""
    try {
        & $Action
    }
    catch {
        $caughtMessage = [string]$_.Exception.Message
    }

    if ([string]::IsNullOrWhiteSpace($caughtMessage) -or $caughtMessage -notmatch $MessagePattern) {
        throw "Assertion failed: $Message. Actual error: '$caughtMessage'."
    }
}

function Assert-Utf8Bom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True -Condition ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -Message $Message
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("geem-package-{0}" -f [Guid]::NewGuid().ToString("N"))
$dataFolder = Join-Path -Path $testRoot -ChildPath "shared data"
$outputRoot = Join-Path -Path $testRoot -ChildPath "output"
$expandedRelease = Join-Path -Path $testRoot -ChildPath "expanded"

try {
    New-Item -ItemType Directory -Path $dataFolder -Force | Out-Null
    $result = & $publisherPath -OutputRoot $outputRoot -DataFolderPath $dataFolder -ReleaseId "package-test-a" -NoZip -AllowLocalDataPath
    $distributionRoot = Join-Path -Path $outputRoot -ChildPath "GEEM-Distribution"
    $manifestPath = Join-Path -Path $distributionRoot -ChildPath "deployment/current.json"

    Assert-Equal -Expected $distributionRoot -Actual $result.DistributionFolder -Message "publisher must return the stable distribution folder"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "Launch GEEM.vbs") -PathType Leaf) -Message "distribution must contain the stable launcher"
    $packagedBatchLauncher = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Launch GEEM.bat"))
    $packagedSilentLauncher = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Launch GEEM.vbs"))
    Assert-True -Condition ($packagedBatchLauncher.IndexOf('launch-cached-app.ps1" -Force', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged batch launcher must restart a previous GEEM instance"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('scriptPath & " -Force"', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must restart a previous GEEM instance"
    $employeeGuidePath = Join-Path -Path $distributionRoot -ChildPath "GUIDE-DEMARRAGE-GEEM.txt"
    Assert-True -Condition (Test-Path -LiteralPath $employeeGuidePath -PathType Leaf) -Message "distribution must contain a guide that opens in Notepad"
    $employeeGuideText = Get-Content -LiteralPath $employeeGuidePath -Raw -Encoding UTF8
    Assert-True -Condition ($employeeGuideText -notmatch '(?m)^#|\*\*|`') -Message "packaged employee guide must be plain text rather than raw Markdown"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "apps"))) -Message "application source must not be expanded on the share"

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected "package-test-a" -Actual $manifest.releaseId -Message "manifest must point to the published release"
    Assert-Equal -Expected $dataFolder -Actual $manifest.dataFolderPath -Message "manifest must preserve the explicit data path"
    $releasePath = Join-Path -Path $distributionRoot -ChildPath ([string]$manifest.packagePath)
    $actualHash = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal -Expected ([string]$manifest.sha256) -Actual $actualHash -Message "manifest checksum must match the release ZIP"
    Assert-Utf8Bom -Path (Join-Path -Path $distributionRoot -ChildPath "scripts/launch-cached-app.ps1") -Message "shared PowerShell bootstrap must include a UTF-8 BOM for Windows PowerShell 5.1"

    Expand-Archive -LiteralPath $releasePath -DestinationPath $expandedRelease -Force
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "apps/admin/backend/services/RouteDispatchService.ps1") -PathType Leaf) -Message "runtime must include required untracked application files"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "docs/GC179.pdf") -PathType Leaf) -Message "runtime must include the GC179 template"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "data"))) -Message "runtime ZIP must exclude data"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "apps/employee"))) -Message "runtime ZIP must exclude the legacy employee application"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "scripts/test-local-app-cache.ps1"))) -Message "runtime ZIP must exclude tests and maintenance scripts"
    foreach ($powerShellFile in @(Get-ChildItem -LiteralPath $expandedRelease -Recurse -File | Where-Object { $_.Extension -in @(".ps1", ".psd1", ".psm1") })) {
        Assert-Utf8Bom -Path $powerShellFile.FullName -Message ("runtime PowerShell file must include a UTF-8 BOM: {0}" -f $powerShellFile.FullName)
    }

    $runtimeConfig = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "apps/admin/backend/admin-config.psd1")
    Assert-Equal -Expected $dataFolder -Actual $runtimeConfig.DataFolderPath -Message "cached runtime must use the shared data folder rather than local data"
    Assert-True -Condition (-not [bool]$runtimeConfig.EnableDemoSeed) -Message "employee releases must disable demo-data generation"
    Assert-True -Condition ([bool]$runtimeConfig.EnableGc179Import) -Message "employee releases must expose the GC179 import UI"

    & $publisherPath -OutputRoot $outputRoot -DataFolderPath $dataFolder -ReleaseId "package-test-b" -NoZip -AllowLocalDataPath | Out-Null
    $updatedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected "package-test-b" -Actual $updatedManifest.releaseId -Message "a later publish must update current.json last"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/releases/GEEM-package-test-a.zip") -PathType Leaf) -Message "the previous share release must remain available"

    Assert-Throws -Action { & $publisherPath -OutputRoot $outputRoot -DataFolderPath $dataFolder -ReleaseId "CON" -NoZip -AllowLocalDataPath | Out-Null } -MessagePattern "Windows-safe" -Message "publisher must reject Windows reserved release IDs"
    Assert-Throws -Action { & $publisherPath -OutputRoot $dataFolder -DataFolderPath $dataFolder -ReleaseId "overlap-test" -NoZip -AllowLocalDataPath | Out-Null } -MessagePattern "must be separate" -Message "publisher must reject overlapping data and distribution paths"

    Write-Host "Release package tests passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
