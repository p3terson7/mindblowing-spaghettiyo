$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path
$publisherPath = Join-Path -Path $repoRoot -ChildPath "scripts/package-app.ps1"
$publisherSource = [System.IO.File]::ReadAllText($publisherPath)

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

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-package-{0}" -f [Guid]::NewGuid().ToString("N"))
$dataFolder = Join-Path -Path $testRoot -ChildPath "shared data"
$outputRoot = Join-Path -Path $testRoot -ChildPath "output"
$expandedRelease = Join-Path -Path $testRoot -ChildPath "expanded"

try {
    Assert-True -Condition ($publisherSource.IndexOf('[string]$drive.DisplayRoot', [System.StringComparison]::Ordinal) -ge 0) -Message "publisher must inspect the UNC DisplayRoot of mapped PowerShell drives"
    Assert-True -Condition ($publisherSource.IndexOf('Win32_LogicalDisk', [System.StringComparison]::Ordinal) -ge 0) -Message "publisher must fall back to the Windows mapped-drive provider"
    Assert-True -Condition ($publisherSource.IndexOf('[System.IO.DriveType]::Network', [System.StringComparison]::Ordinal) -ge 0) -Message "publisher must accept a drive letter that Windows confirms is a network drive"

    New-Item -ItemType Directory -Path $dataFolder -Force | Out-Null
    $result = & $publisherPath -OutputRoot $outputRoot -DataFolderPath $dataFolder -ReleaseId "package-test-a" -NoZip -AllowLocalDataPath
    $distributionRoot = Join-Path -Path $outputRoot -ChildPath "SAPHIR-Distribution"
    $manifestPath = Join-Path -Path $distributionRoot -ChildPath "deployment/current.json"

    Assert-Equal -Expected $distributionRoot -Actual $result.DistributionFolder -Message "publisher must return the stable distribution folder"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "Launch SAPHIR.vbs") -PathType Leaf) -Message "distribution must contain the stable launcher"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "Install SAPHIR Shortcut.vbs") -PathType Leaf) -Message "distribution must contain the desktop-shortcut installer"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "SAPHIR.ico") -PathType Leaf) -Message "distribution must contain the SAPHIR Windows icon"
    $packagedBatchLauncher = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Launch SAPHIR.bat"))
    $packagedSilentLauncher = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Launch SAPHIR.vbs"))
    $packagedShortcutInstaller = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Install SAPHIR Shortcut.vbs"))
    Assert-True -Condition ($packagedBatchLauncher.IndexOf('launch-cached-app.ps1"', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged batch launcher must call the cached application bootstrap"
    Assert-True -Condition ($packagedBatchLauncher.IndexOf('launch-cached-app.ps1" -Force', [System.StringComparison]::Ordinal) -lt 0) -Message "packaged batch launcher must allow a healthy current version to remain warm"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('& scriptPath, 0, True', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must call the cached application bootstrap"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('scriptPath & " -Force"', [System.StringComparison]::Ordinal) -lt 0) -Message "packaged silent launcher must allow a healthy current version to remain warm"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('GetResponseHeader("X-SAPHIR-App")', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must verify and reopen a warm SAPHIR instance before starting PowerShell"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('GetResponseHeader("X-SAPHIR-Instance")', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must match the running instance token before reopening SAPHIR"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('StrComp(expectedServerPath, metadataServerPath, vbTextCompare) = 0', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must bind the warm process to the active cached release"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged launcher must avoid a PATH search on restricted workstations"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('SAPHIR.lnk', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must create the stable SAPHIR desktop link"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('localIconPath & ",0"', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must use the locally cached icon"
    $employeeGuidePath = Join-Path -Path $distributionRoot -ChildPath "GUIDE-DEMARRAGE-SAPHIR.txt"
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
    foreach ($bootstrapLibrary in @("LocalAppCache.ps1", "RuntimeLayout.ps1", "ServerControl.ps1")) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath ("scripts/lib/{0}" -f $bootstrapLibrary)) -PathType Leaf) -Message ("distribution must contain bootstrap library {0}" -f $bootstrapLibrary)
    }

    Expand-Archive -LiteralPath $releasePath -DestinationPath $expandedRelease -Force
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "apps/admin/backend/services/RouteDispatchService.ps1") -PathType Leaf) -Message "runtime must include required untracked application files"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "apps/admin/frontend/assets/saphir-logo.png") -PathType Leaf) -Message "runtime UI must include the optimized SAPHIR logo"
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
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/releases/SAPHIR-package-test-a.zip") -PathType Leaf) -Message "the previous share release must remain available"

    Assert-Throws -Action { & $publisherPath -OutputRoot $outputRoot -DataFolderPath $dataFolder -ReleaseId "CON" -NoZip -AllowLocalDataPath | Out-Null } -MessagePattern "Windows-safe" -Message "publisher must reject Windows reserved release IDs"
    Assert-Throws -Action { & $publisherPath -OutputRoot $dataFolder -DataFolderPath $dataFolder -ReleaseId "overlap-test" -NoZip -AllowLocalDataPath | Out-Null } -MessagePattern "must be separate" -Message "publisher must reject overlapping data and distribution paths"

    Write-Host "Release package tests passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
