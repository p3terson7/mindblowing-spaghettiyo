$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path
. (Join-Path -Path $repoRoot -ChildPath "scripts/lib/LocalAppCache.ps1")

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

function Write-FixtureManifest {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [Parameter(Mandatory = $true)][string]$ReleaseId,
        [Parameter(Mandatory = $true)][string]$PackageRelativePath,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$DataFolderPath
    )

    $deploymentRoot = Join-Path -Path $DistributionRoot -ChildPath "deployment"
    if (-not (Test-Path -LiteralPath $deploymentRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $deploymentRoot -Force | Out-Null
    }

    $manifest = [ordered]@{
        schemaVersion  = 1
        releaseId      = $ReleaseId
        packagePath    = $PackageRelativePath
        sha256         = $Sha256
        dataFolderPath = $DataFolderPath
        publishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $json = ConvertTo-Json -InputObject $manifest -Depth 5
    [System.IO.File]::WriteAllText((Join-Path -Path $deploymentRoot -ChildPath "current.json"), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-FixtureRelease {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [Parameter(Mandatory = $true)][string]$ReleaseId,
        [Parameter(Mandatory = $true)][string]$DataFolderPath,
        [switch]$OmitGc179Template
    )

    $fixtureBuild = Join-Path -Path $DistributionRoot -ChildPath ("fixture-{0}" -f $ReleaseId)
    $releaseRoot = Join-Path -Path $fixtureBuild -ChildPath "runtime"
    $releasesRoot = Join-Path -Path $DistributionRoot -ChildPath "deployment/releases"
    New-Item -ItemType Directory -Path (Join-Path -Path $releaseRoot -ChildPath "apps/admin/backend") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $releaseRoot -ChildPath "apps/admin/backend/lib") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $releaseRoot -ChildPath "apps/admin/backend/services") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $releaseRoot -ChildPath "apps/admin/frontend") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $releaseRoot -ChildPath "docs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $releaseRoot -ChildPath "scripts/lib") -Force | Out-Null
    New-Item -ItemType Directory -Path $releasesRoot -Force | Out-Null

    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "apps/admin/backend/admin-server.ps1") -Value "# $ReleaseId" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "apps/admin/backend/admin-config.psd1") -Value "@{ DataFolderPath = '$($DataFolderPath.Replace("'", "''"))' }" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "apps/admin/backend/lib/ControlService.ps1") -Value "# control service" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "apps/admin/backend/services/RouteDispatchService.ps1") -Value "# route dispatch" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "apps/admin/frontend/index.html") -Value "<html>$ReleaseId</html>" -Encoding UTF8
    if (-not $OmitGc179Template) {
        Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "docs/GC179.pdf") -Value "fixture" -Encoding ASCII
    }
    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "scripts/launch-app.ps1") -Value "# launch $ReleaseId" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "scripts/lib/RuntimeLayout.ps1") -Value "# runtime" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $releaseRoot -ChildPath "scripts/lib/ServerControl.ps1") -Value "# server control" -Encoding UTF8

    $releaseFileName = "SAPHIR-{0}.zip" -f $ReleaseId
    $releasePath = Join-Path -Path $releasesRoot -ChildPath $releaseFileName
    Compress-Archive -Path (Join-Path -Path $releaseRoot -ChildPath "*") -DestinationPath $releasePath -Force
    $sha256 = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Remove-Item -LiteralPath $fixtureBuild -Recurse -Force

    Write-FixtureManifest -DistributionRoot $DistributionRoot -ReleaseId $ReleaseId -PackageRelativePath ("deployment/releases/{0}" -f $releaseFileName) -Sha256 $sha256 -DataFolderPath $DataFolderPath
    return [PSCustomObject]@{
        ReleaseId   = $ReleaseId
        ReleasePath = $releasePath
        Sha256      = $sha256
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir cache é {0}" -f [Guid]::NewGuid().ToString("N"))
$distributionRoot = Join-Path -Path $testRoot -ChildPath "network distribution"
$dataFolder = Join-Path -Path $testRoot -ChildPath "shared data"
$cacheRoot = Join-Path -Path $testRoot -ChildPath "local cache"
$manifestPath = Join-Path -Path $distributionRoot -ChildPath "deployment/current.json"
$originalCacheRoot = [string]$env:SAPHIR_APP_CACHE_ROOT

try {
    New-Item -ItemType Directory -Path $distributionRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $dataFolder -Force | Out-Null
    $env:SAPHIR_APP_CACHE_ROOT = $cacheRoot

    $releaseA = New-FixtureRelease -DistributionRoot $distributionRoot -ReleaseId "release-a" -DataFolderPath $dataFolder
    $coldResult = Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath
    Assert-True -Condition ([bool]$coldResult.Installed) -Message "cold resolution must install the release"
    Assert-True -Condition (Test-Path -LiteralPath $coldResult.LaunchScript -PathType Leaf) -Message "cold install must return a local launch script"
    Assert-True -Condition ([System.IO.Path]::GetFullPath($coldResult.LaunchScript).StartsWith([System.IO.Path]::GetFullPath($cacheRoot))) -Message "the launch script must be inside the local cache"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $coldResult.ReleasePath -ChildPath "data"))) -Message "a release must never contain data"

    Remove-Item -LiteralPath $releaseA.ReleasePath -Force
    $warmResult = Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath
    Assert-True -Condition (-not [bool]$warmResult.Installed) -Message "warm resolution must reuse the cached release without the ZIP"

    $cachedTemplatePath = Join-Path -Path $warmResult.ReleasePath -ChildPath "docs/GC179.pdf"
    Remove-Item -LiteralPath $cachedTemplatePath -Force
    Set-Content -LiteralPath $releaseA.ReleasePath -Value "corrupted network package" -Encoding ASCII
    Assert-Throws -Action { Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath | Out-Null } -MessagePattern "integrity check" -Message "repairing a damaged local release must still validate the network package"
    Assert-True -Condition (Test-Path -LiteralPath $warmResult.ReleasePath -PathType Container) -Message "a failed repair must preserve the existing local release directory"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $warmResult.ReleasePath -ChildPath "apps/admin/backend/admin-server.ps1") -PathType Leaf) -Message "a failed repair must preserve existing local files"
    Remove-Item -LiteralPath $releaseA.ReleasePath -Force
    Set-Content -LiteralPath $cachedTemplatePath -Value "fixture" -Encoding ASCII

    Write-FixtureManifest -DistributionRoot $distributionRoot -ReleaseId "release-a" -PackageRelativePath "deployment/releases/SAPHIR-release-a.zip" -Sha256 ("a" * 64) -DataFolderPath $dataFolder
    Assert-Throws -Action { Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath | Out-Null } -MessagePattern "different immutable settings" -Message "reusing a release ID with another hash must fail"
    Assert-True -Condition (Test-Path -LiteralPath $warmResult.ReleasePath -PathType Container) -Message "an immutable-manifest failure must preserve the cached release"

    $releaseB = New-FixtureRelease -DistributionRoot $distributionRoot -ReleaseId "release-b" -DataFolderPath $dataFolder
    $previousRelease = $warmResult
    Set-SaphirActiveRelease -CacheRoot $cacheRoot -Release $previousRelease
    $updateResult = Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath
    Assert-Equal -Expected "release-b" -Actual $updateResult.ReleaseId -Message "an update must install the new version"
    Assert-True -Condition (Test-Path -LiteralPath $previousRelease.ReleasePath -PathType Container) -Message "the previous version must remain available for rollback"
    Set-SaphirActiveRelease -CacheRoot $cacheRoot -Release $updateResult
    $activeRelease = Get-SaphirActiveRelease -CacheRoot $cacheRoot
    Assert-Equal -Expected "release-b" -Actual $activeRelease.ReleaseId -Message "the active pointer must update after a successful launch"

    $releaseC = New-FixtureRelease -DistributionRoot $distributionRoot -ReleaseId "release-c" -DataFolderPath $dataFolder
    Write-FixtureManifest -DistributionRoot $distributionRoot -ReleaseId "release-c" -PackageRelativePath "deployment/releases/SAPHIR-release-c.zip" -Sha256 ("b" * 64) -DataFolderPath $dataFolder
    Assert-Throws -Action { Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath | Out-Null } -MessagePattern "integrity check" -Message "a bad package hash must fail"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "versions/release-c"))) -Message "a bad hash must not create a final release"

    $releaseD = New-FixtureRelease -DistributionRoot $distributionRoot -ReleaseId "release-d" -DataFolderPath $dataFolder -OmitGc179Template
    Assert-Throws -Action { Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath | Out-Null } -MessagePattern "incomplete" -Message "a package missing a required runtime file must fail"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "versions/release-d"))) -Message "an incomplete package must not become active"

    Write-FixtureManifest -DistributionRoot $distributionRoot -ReleaseId "release-e" -PackageRelativePath "../outside.zip" -Sha256 ("c" * 64) -DataFolderPath $dataFolder
    Assert-Throws -Action { Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath | Out-Null } -MessagePattern "unsafe package path" -Message "path traversal in the manifest must fail"

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $unsafeZip = Join-Path -Path $testRoot -ChildPath "unsafe-release.zip"
    $unsafeArchive = [System.IO.Compression.ZipFile]::Open($unsafeZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        [void]$unsafeArchive.CreateEntry("../escaped.txt")
    }
    finally {
        $unsafeArchive.Dispose()
    }
    Assert-Throws -Action { Assert-SaphirZipEntriesSafe -ZipPath $unsafeZip -DestinationRoot (Join-Path -Path $testRoot -ChildPath "unsafe staging") } -MessagePattern "unsafe file path" -Message "path traversal inside a release ZIP must fail before extraction"

    Assert-True -Condition (-not (Test-SaphirReleaseId -ReleaseId "CON")) -Message "Windows reserved device names must not be valid release IDs"
    Assert-True -Condition (-not (Test-SaphirReleaseId -ReleaseId "release.")) -Message "release IDs ending in a period must be rejected"

    $missingDataFolder = Join-Path -Path $testRoot -ChildPath "missing data"
    Write-FixtureManifest -DistributionRoot $distributionRoot -ReleaseId "release-f" -PackageRelativePath "deployment/releases/missing.zip" -Sha256 ("d" * 64) -DataFolderPath $missingDataFolder
    Assert-Throws -Action { Resolve-SaphirCachedRelease -DistributionRoot $distributionRoot -ManifestPath $manifestPath | Out-Null } -MessagePattern "data folder is unavailable" -Message "an unavailable shared data folder must fail closed"

    $mutex = Enter-SaphirCacheMutex -CacheRoot $cacheRoot -TimeoutSeconds 2
    Assert-True -Condition ($null -ne $mutex) -Message "the local install mutex must be obtainable"
    Exit-SaphirCacheMutex -Mutex $mutex

    $downloadsRoot = Join-Path -Path $cacheRoot -ChildPath "downloads"
    $orphanDownload = Join-Path -Path $downloadsRoot -ChildPath "orphan.zip"
    Set-Content -LiteralPath $orphanDownload -Value "orphan" -Encoding ASCII
    $orphanStaging = Join-Path -Path $cacheRoot -ChildPath ("versions/.orphan.{0}.staging" -f [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $orphanStaging -Force | Out-Null
    Repair-SaphirInterruptedCacheOperations -CacheRoot $cacheRoot
    Assert-True -Condition (-not (Test-Path -LiteralPath $orphanDownload)) -Message "interrupted downloads must be removed on the next launch"
    Assert-True -Condition (-not (Test-Path -LiteralPath $orphanStaging)) -Message "interrupted staging directories must be removed on the next launch"

    $retentionCache = Join-Path -Path $testRoot -ChildPath "retention cache"
    $retentionVersions = Join-Path -Path $retentionCache -ChildPath "versions"
    New-Item -ItemType Directory -Path $retentionVersions -Force | Out-Null
    foreach ($name in @("newest-a", "newest-b", "keep-old-a", "keep-old-b")) {
        New-Item -ItemType Directory -Path (Join-Path -Path $retentionVersions -ChildPath $name) -Force | Out-Null
    }
    (Get-Item -LiteralPath (Join-Path -Path $retentionVersions -ChildPath "newest-a")).LastWriteTime = (Get-Date).AddMinutes(-1)
    (Get-Item -LiteralPath (Join-Path -Path $retentionVersions -ChildPath "newest-b")).LastWriteTime = (Get-Date).AddMinutes(-2)
    (Get-Item -LiteralPath (Join-Path -Path $retentionVersions -ChildPath "keep-old-a")).LastWriteTime = (Get-Date).AddMinutes(-3)
    (Get-Item -LiteralPath (Join-Path -Path $retentionVersions -ChildPath "keep-old-b")).LastWriteTime = (Get-Date).AddMinutes(-4)
    Remove-OldSaphirCachedReleases -CacheRoot $retentionCache -KeepReleaseIds @("keep-old-a", "keep-old-b") -MaximumVersionCount 2
    $retainedNames = @(Get-ChildItem -LiteralPath $retentionVersions -Directory | ForEach-Object { $_.Name } | Sort-Object)
    Assert-Equal -Expected "keep-old-a keep-old-b" -Actual ($retainedNames -join " ") -Message "protected releases must count toward the local retention maximum"

    $partialItems = @(Get-ChildItem -LiteralPath (Join-Path -Path $cacheRoot -ChildPath "versions") -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "\.staging$" })
    Assert-Equal -Expected 0 -Actual $partialItems.Count -Message "failed installs must not leave staging directories"

    Write-Host "Local application cache tests passed."
}
finally {
    $env:SAPHIR_APP_CACHE_ROOT = $originalCacheRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
