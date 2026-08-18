$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
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
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "SAPHIR Launcher.vbs") -PathType Leaf) -Message "distribution must contain the graphical launcher entry point"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "Install SAPHIR Shortcut.vbs") -PathType Leaf) -Message "distribution must contain the desktop-shortcut installer"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "SAPHIR.ico") -PathType Leaf) -Message "distribution must contain the SAPHIR Windows icon"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "scripts/saphir-launcher.ps1") -PathType Leaf) -Message "distribution must contain the graphical launcher interface"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "scripts/lib/LauncherControl.ps1") -PathType Leaf) -Message "distribution must contain the launcher controller"
    $packagedBatchLauncher = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Launch SAPHIR.bat"))
    $packagedSilentLauncher = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Launch SAPHIR.vbs"))
    $packagedGraphicalLauncher = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "SAPHIR Launcher.vbs"))
    $packagedLauncherInterface = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "scripts/saphir-launcher.ps1"))
    $packagedShortcutInstaller = [System.IO.File]::ReadAllText((Join-Path -Path $distributionRoot -ChildPath "Install SAPHIR Shortcut.vbs"))
    Assert-True -Condition ($packagedBatchLauncher.IndexOf('launch-cached-app.ps1"', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged batch launcher must call the cached application bootstrap"
    Assert-True -Condition ($packagedBatchLauncher.IndexOf('launch-cached-app.ps1" -Force', [System.StringComparison]::Ordinal) -lt 0) -Message "packaged batch launcher must allow a healthy current version to remain warm"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('& scriptPath, 0, True', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must call the cached application bootstrap"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('scriptPath & " -Force"', [System.StringComparison]::Ordinal) -lt 0) -Message "packaged silent launcher must allow a healthy current version to remain warm"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('GetResponseHeader("X-SAPHIR-App")', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must verify and reopen a warm SAPHIR instance before starting PowerShell"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('GetResponseHeader("X-SAPHIR-Instance")', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must match the running instance token before reopening SAPHIR"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('StrComp(expectedCanonicalServerPath, metadataServerPath, vbTextCompare) = 0 Or StrComp(expectedLegacyServerPath, metadataServerPath, vbTextCompare) = 0', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged silent launcher must bind the warm process to either the canonical release or an explicitly supported legacy cached release"
    Assert-True -Condition ($packagedSilentLauncher.IndexOf('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe', [System.StringComparison]::Ordinal) -ge 0) -Message "packaged launcher must avoid a PATH search on restricted workstations"
    Assert-True -Condition ($packagedGraphicalLauncher.IndexOf('distribution-root.txt', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "local graphical launcher must remember how to reach the current shared distribution"
    Assert-True -Condition ($packagedGraphicalLauncher.IndexOf('fso.FileExists(sharedLauncherPath)', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -Message "local graphical launcher must not synchronously probe the network share before opening its window"
    Assert-True -Condition ($packagedGraphicalLauncher.IndexOf('-STA', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "graphical launcher must start Windows PowerShell in STA mode for WPF"
    Assert-True -Condition ($packagedGraphicalLauncher.IndexOf('-DistributionRoot', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "graphical launcher must pass the persisted distribution location to its interface"
    Assert-True -Condition ($packagedLauncherInterface.IndexOf('LauncherControl.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "graphical launcher interface must use the testable launcher controller"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('SAPHIR.lnk', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must create the stable SAPHIR desktop link"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('fso.BuildPath(localRoot, "launcher")', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must keep its launcher bundle in local AppData"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('localLauncherVersionsRoot', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must stage immutable versioned launcher bundles"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('fso.MoveFolder stagingRoot, bundleRoot', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must activate a validated bundle with one same-volume rename"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('distribution-root.txt', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "shortcut installer must persist the shared distribution location"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('CreateTextFile(distributionRootFilePath, True, True)', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must preserve accented distribution paths in a Unicode file"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('shortcut.Arguments = Chr(34) & localLauncherEntryPath & Chr(34)', [System.StringComparison]::Ordinal) -ge 0) -Message "desktop shortcut must target the locally installed launcher"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('sourceLauncherScriptPath, localLauncherScriptPath', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must copy the launcher interface locally"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('sourceLauncherControlPath, localLauncherControlPath', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must copy the launcher controller locally"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('sourceApplicationLayoutPath, localApplicationLayoutPath', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must copy the canonical/legacy application-layout resolver locally"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('sourceCachedLaunchPath, localCachedLaunchPath', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must copy the cached application starter for network-outage fallback"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('sourceLocalCachePath, localLocalCachePath', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must copy local-cache support for network-outage fallback"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('sourceServerControlPath, localServerControlPath', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must copy service-control support locally"
    $shortcutSavePosition = $packagedShortcutInstaller.IndexOf('shortcut.Save', [System.StringComparison]::Ordinal)
    $failedReleaseResetPosition = $packagedShortcutInstaller.IndexOf('failedReleasePath = fso.BuildPath(localRoot, "failed.json")', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($failedReleaseResetPosition -gt $shortcutSavePosition) -Message "shortcut installer must only unlock a failed release after the new local bundle and shortcut are active"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('If fso.FileExists(localApplicationLayoutPath) And fso.FileExists(failedReleasePath) Then', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must only unlock a failed release when its installed bundle contains the canonical/legacy resolver"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('fso.DeleteFile markerPath, True', [System.StringComparison]::Ordinal) -ge 0) -Message "reinstalling the compatible launcher must allow the current manifest release to be retried"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('"Version du lanceur : " & bundleId', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer confirmation must identify the installed launcher bundle"
    Assert-True -Condition ($packagedShortcutInstaller.IndexOf('localIconPath & ",0"', [System.StringComparison]::Ordinal) -ge 0) -Message "shortcut installer must use the locally cached icon"
    Assert-True -Condition ([regex]::IsMatch($publisherSource, '"SAPHIR Launcher\.vbs",\s*"Install SAPHIR Shortcut\.vbs"')) -Message "publisher must expose the graphical entry point before the installer that requires it"
    $employeeGuidePath = Join-Path -Path $distributionRoot -ChildPath "GUIDE-DEMARRAGE-SAPHIR.txt"
    Assert-True -Condition (Test-Path -LiteralPath $employeeGuidePath -PathType Leaf) -Message "distribution must contain a guide that opens in Notepad"
    $employeeGuideText = Get-Content -LiteralPath $employeeGuidePath -Raw -Encoding UTF8
    Assert-True -Condition ($employeeGuideText -notmatch '(?m)^#|\*\*|`') -Message "packaged employee guide must be plain text rather than raw Markdown"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "apps"))) -Message "application source must not be expanded on the share"

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected "package-test-a" -Actual $manifest.releaseId -Message "manifest must point to the published release"
    Assert-Equal -Expected "deployment/releases/SAPHIR-package-test-a.zip" -Actual ([string]$manifest.packagePath) -Message "manifest must target the exact immutable release ZIP rather than relying on releases-folder discovery"
    Assert-Equal -Expected $dataFolder -Actual $manifest.dataFolderPath -Message "manifest must preserve the explicit data path"
    $releasePath = Join-Path -Path $distributionRoot -ChildPath ([string]$manifest.packagePath)
    Assert-Equal -Expected $releasePath -Actual ([string]$result.ReleasePackage) -Message "publisher result and current.json must identify the same release ZIP"
    $actualHash = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal -Expected ([string]$manifest.sha256) -Actual $actualHash -Message "manifest checksum must match the release ZIP"
    foreach ($bootstrapScript in @("launch-cached-app.ps1", "saphir-launcher.ps1", "stop-all.ps1")) {
        Assert-Utf8Bom -Path (Join-Path -Path $distributionRoot -ChildPath ("scripts/{0}" -f $bootstrapScript)) -Message ("shared PowerShell bootstrap script must include a UTF-8 BOM for Windows PowerShell 5.1: {0}" -f $bootstrapScript)
    }
    foreach ($bootstrapLibrary in @("ApplicationLayout.ps1", "LauncherControl.ps1", "LocalAppCache.ps1", "RuntimeLayout.ps1", "ServerControl.ps1")) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $distributionRoot -ChildPath ("scripts/lib/{0}" -f $bootstrapLibrary)) -PathType Leaf) -Message ("distribution must contain bootstrap library {0}" -f $bootstrapLibrary)
        Assert-Utf8Bom -Path (Join-Path -Path $distributionRoot -ChildPath ("scripts/lib/{0}" -f $bootstrapLibrary)) -Message ("shared PowerShell bootstrap library must include a UTF-8 BOM for Windows PowerShell 5.1: {0}" -f $bootstrapLibrary)
    }

    Expand-Archive -LiteralPath $releasePath -DestinationPath $expandedRelease -Force
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/lib/ControlService.ps1") -PathType Leaf) -Message "runtime must include guarded backend service control"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/services/RouteDispatchService.ps1") -PathType Leaf) -Message "runtime must include required untracked application files"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.Routing.psd1") -PathType Leaf) -Message "runtime must include the routing module manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.Routing.psm1") -PathType Leaf) -Message "runtime must include the pure routing module"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.EntryIdentity.psd1") -PathType Leaf) -Message "runtime must include the entry identity module manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.EntryIdentity.psm1") -PathType Leaf) -Message "runtime must include the pure entry identity module"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.EntryState.psd1") -PathType Leaf) -Message "runtime must include the entry state module manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.EntryState.psm1") -PathType Leaf) -Message "runtime must include the pure entry state module"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.Gc179Profile.psd1") -PathType Leaf) -Message "runtime must include the GC179 profile module manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.Gc179Profile.psm1") -PathType Leaf) -Message "runtime must include the pure GC179 profile module"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.ProjectCatalog.psd1") -PathType Leaf) -Message "runtime must include the project catalog module manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.ProjectCatalog.psm1") -PathType Leaf) -Message "runtime must include the pure project catalog module"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.UserAccessProfile.psd1") -PathType Leaf) -Message "runtime must include the user access profile module manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/modules/Saphir.UserAccessProfile.psm1") -PathType Leaf) -Message "runtime must include the pure user access profile module"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/services/DataSchemaService.ps1") -PathType Leaf) -Message "runtime must include the data schema guard"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/frontend/assets/saphir-logo.png") -PathType Leaf) -Message "runtime UI must include the optimized SAPHIR logo"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "docs/GC179.pdf") -PathType Leaf) -Message "runtime must include the GC179 template"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "data"))) -Message "runtime ZIP must exclude data"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "apps"))) -Message "new runtime ZIPs must contain only the canonical app tree"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "apps/employee"))) -Message "runtime ZIP must exclude the legacy employee application"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "scripts/saphir-launcher.ps1"))) -Message "runtime ZIP must keep the graphical launcher in the stable bootstrap rather than each app release"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "scripts/lib/LauncherControl.ps1"))) -Message "runtime ZIP must keep launcher control code in the stable bootstrap"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "tests"))) -Message "runtime ZIP must exclude the complete test suite"
    foreach ($powerShellFile in @(Get-ChildItem -LiteralPath $expandedRelease -Recurse -File | Where-Object { $_.Extension -in @(".ps1", ".psd1", ".psm1") })) {
        Assert-Utf8Bom -Path $powerShellFile.FullName -Message ("runtime PowerShell file must include a UTF-8 BOM: {0}" -f $powerShellFile.FullName)
    }

    $runtimeConfig = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $expandedRelease -ChildPath "app/backend/saphir-config.psd1")
    Assert-Equal -Expected $dataFolder -Actual $runtimeConfig.DataFolderPath -Message "cached runtime must use the shared data folder rather than local data"
    Assert-True -Condition (-not [bool]$runtimeConfig.EnableDemoSeed) -Message "employee releases must disable demo-data generation"
    Assert-True -Condition ([bool]$runtimeConfig.EnableGc179Import) -Message "employee releases must expose the GC179 import UI"

    . (Join-Path -Path $expandedRelease -ChildPath "scripts/lib/ApplicationLayout.ps1")
    $expandedApplicationLayout = Resolve-SaphirApplicationLayout -ApplicationRoot $expandedRelease
    Assert-True -Condition ($null -ne $expandedApplicationLayout) -Message "the packaged canonical runtime must be discoverable by the transition-capable application-layout resolver"
    Assert-Equal -Expected "Canonical" -Actual ([string]$expandedApplicationLayout.Kind) -Message "the packaged runtime must resolve to the canonical app layout"

    # Model the real one-time transition: the share can still expose an old
    # installer/bootstrap while current.json continues to identify the working
    # pre-transition release. BootstrapOnly must replace those launcher files
    # without altering either the release pointer or any immutable ZIP.
    $distributionInstallerPath = Join-Path -Path $distributionRoot -ChildPath "Install SAPHIR Shortcut.vbs"
    $distributionLayoutResolverPath = Join-Path -Path $distributionRoot -ChildPath "scripts/lib/ApplicationLayout.ps1"
    Set-Content -LiteralPath $distributionInstallerPath -Value "' legacy transition fixture" -Encoding ASCII
    Remove-Item -LiteralPath $distributionLayoutResolverPath -Force

    $manifestBeforeBootstrapOnly = [System.IO.File]::ReadAllBytes($manifestPath)
    $releaseNamesBeforeBootstrapOnly = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/releases") -File |
            Sort-Object Name |
            ForEach-Object { $_.Name }
    )
    $releaseHashesBeforeBootstrapOnly = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/releases") -File |
            Sort-Object Name |
            ForEach-Object { "{0}={1}" -f $_.Name, ((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) }
    )
    $bootstrapOnlyResult = & $publisherPath -OutputRoot $outputRoot -BootstrapOnly -NoZip
    Assert-True -Condition ([bool]$bootstrapOnlyResult.BootstrapOnly) -Message "bootstrap-only publication must identify its non-release result"
    Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$bootstrapOnlyResult.ReleasePackage)) -Message "bootstrap-only publication must not create an application release"
    Assert-True `
        -Condition ([Convert]::ToBase64String($manifestBeforeBootstrapOnly) -eq [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestPath))) `
        -Message "bootstrap-only publication must not rewrite current.json"
    $releaseNamesAfterBootstrapOnly = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/releases") -File |
            Sort-Object Name |
            ForEach-Object { $_.Name }
    )
    Assert-Equal `
        -Expected ($releaseNamesBeforeBootstrapOnly -join "|") `
        -Actual ($releaseNamesAfterBootstrapOnly -join "|") `
        -Message "bootstrap-only publication must not add, remove, or replace release ZIPs"
    $releaseHashesAfterBootstrapOnly = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $distributionRoot -ChildPath "deployment/releases") -File |
            Sort-Object Name |
            ForEach-Object { "{0}={1}" -f $_.Name, ((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) }
    )
    Assert-Equal `
        -Expected ($releaseHashesBeforeBootstrapOnly -join "|") `
        -Actual ($releaseHashesAfterBootstrapOnly -join "|") `
        -Message "bootstrap-only publication must leave every existing release ZIP byte-for-byte unchanged"
    Assert-True -Condition (Test-Path -LiteralPath $distributionLayoutResolverPath -PathType Leaf) -Message "bootstrap-only publication must publish the topology compatibility resolver"
    $bootstrapOnlyInstaller = [System.IO.File]::ReadAllText($distributionInstallerPath)
    Assert-True -Condition ($bootstrapOnlyInstaller.IndexOf('sourceApplicationLayoutPath', [System.StringComparison]::Ordinal) -ge 0) -Message "bootstrap-only publication must replace the historical installer with the canonical/legacy transition installer"
    Assert-True -Condition ($bootstrapOnlyInstaller.IndexOf('fso.DeleteFile markerPath, True', [System.StringComparison]::Ordinal) -ge 0) -Message "bootstrap-only publication must expose the installer retry contract that clears a stale failed-release marker"

    & $publisherPath -OutputRoot $outputRoot -DataFolderPath $dataFolder -ReleaseId "package-test-b" -NoZip -AllowLocalDataPath | Out-Null
    $updatedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected "package-test-b" -Actual $updatedManifest.releaseId -Message "a later publish must update current.json last"
    Assert-Equal -Expected "deployment/releases/SAPHIR-package-test-b.zip" -Actual ([string]$updatedManifest.packagePath) -Message "the updated manifest must target the newly published canonical ZIP"
    $updatedReleasePath = Join-Path -Path $distributionRoot -ChildPath ([string]$updatedManifest.packagePath)
    Assert-True -Condition (Test-Path -LiteralPath $updatedReleasePath -PathType Leaf) -Message "current.json must never point to a release ZIP that is absent from the distribution"
    Assert-Equal -Expected ([string]$updatedManifest.sha256) -Actual ((Get-FileHash -LiteralPath $updatedReleasePath -Algorithm SHA256).Hash.ToLowerInvariant()) -Message "the updated manifest checksum must match its targeted canonical ZIP"
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
