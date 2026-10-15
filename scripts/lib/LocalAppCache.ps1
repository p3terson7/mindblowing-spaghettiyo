$ErrorActionPreference = "Stop"

$script:saphirLocalAppCacheDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$applicationLayoutCommand = Get-Command -Name "Resolve-SaphirApplicationLayout" -CommandType Function -ErrorAction SilentlyContinue
if ($null -eq $applicationLayoutCommand) {
    $applicationLayoutLibrary = Join-Path -Path $script:saphirLocalAppCacheDirectory -ChildPath "ApplicationLayout.ps1"
    if (-not (Test-Path -LiteralPath $applicationLayoutLibrary -PathType Leaf)) {
        throw "The SAPHIR application-layout library is unavailable."
    }
    . $applicationLayoutLibrary
}

function Ensure-SaphirLocalDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-SaphirLocalAppRoot {
    $configuredCacheRoot = [string]$env:SAPHIR_APP_CACHE_ROOT
    if ([string]::IsNullOrWhiteSpace($configuredCacheRoot)) {
        $configuredCacheRoot = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_APP_CACHE_ROOT"))
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredCacheRoot)) {
        return [System.IO.Path]::GetFullPath($configuredCacheRoot)
    }

    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [string]$env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [string]$env:TEMP
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw "Unable to locate a writable local application-data folder."
    }

    return (Join-Path -Path $localAppData -ChildPath "SAPHIR")
}

function Write-SaphirJsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 6
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        Ensure-SaphirLocalDirectory -Path $parent
    }

    $temporaryPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $json = ConvertTo-Json -InputObject $Value -Depth $Depth
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8NoBom)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SaphirPathStringComparison {
    if ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }

    return [System.StringComparison]::Ordinal
}

function Test-SaphirReleaseId {
    param([string]$ReleaseId)

    if ([string]::IsNullOrWhiteSpace($ReleaseId) -or $ReleaseId -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$" -or $ReleaseId.EndsWith(".")) {
        return $false
    }

    $deviceName = $ReleaseId.Split(".")[0].ToUpperInvariant()
    return ($deviceName -notmatch "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$")
}

function Resolve-SaphirPackagePath {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [Parameter(Mandatory = $true)][string]$RelativePackagePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePackagePath) -or
        [System.IO.Path]::IsPathRooted($RelativePackagePath) -or
        $RelativePackagePath -match "(^|[\\/])\.\.([\\/]|$)" -or
        $RelativePackagePath -match "(^|[\\/])\.([\\/]|$)") {
        throw "The release manifest contains an unsafe package path."
    }

    $rootPath = [System.IO.Path]::GetFullPath($DistributionRoot)
    $candidatePath = [System.IO.Path]::GetFullPath((Join-Path -Path $rootPath -ChildPath $RelativePackagePath))
    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    $rootPrefix = $rootPath.TrimEnd([char[]]@([char]92, [char]47)) + $separator
    if (-not $candidatePath.StartsWith($rootPrefix, (Get-SaphirPathStringComparison))) {
        throw "The release package must remain inside the SAPHIR distribution folder."
    }

    return $candidatePath
}

function Read-SaphirReleaseManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$DistributionRoot
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "SAPHIR release information is missing: $ManifestPath"
    }

    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "SAPHIR release information is unreadable or incomplete. $($_.Exception.Message)"
    }

    if ($null -eq $manifest -or [int]$manifest.schemaVersion -ne 1) {
        throw "The SAPHIR release manifest uses an unsupported format."
    }

    $releaseId = [string]$manifest.releaseId
    if (-not (Test-SaphirReleaseId -ReleaseId $releaseId)) {
        throw "The SAPHIR release identifier is invalid."
    }

    $sha256 = ([string]$manifest.sha256).Trim().ToLowerInvariant()
    if ($sha256 -notmatch "^[a-f0-9]{64}$") {
        throw "The SAPHIR release checksum is invalid."
    }

    $packagePath = Resolve-SaphirPackagePath -DistributionRoot $DistributionRoot -RelativePackagePath ([string]$manifest.packagePath)
    $dataFolderPath = [string]$manifest.dataFolderPath
    if ([string]::IsNullOrWhiteSpace($dataFolderPath) -or -not [System.IO.Path]::IsPathRooted($dataFolderPath)) {
        throw "The SAPHIR release does not contain an absolute shared-data path."
    }
    if (-not (Test-Path -LiteralPath $dataFolderPath -PathType Container)) {
        throw "The shared SAPHIR data folder is unavailable: $dataFolderPath"
    }

    return [PSCustomObject]@{
        SchemaVersion  = 1
        ReleaseId      = $releaseId
        Sha256         = $sha256
        PackagePath    = $packagePath
        DataFolderPath = $dataFolderPath
        PublishedAtUtc = [string]$manifest.publishedAtUtc
    }
}

function Get-SaphirRequiredReleaseFiles {
    return @(
        "docs/GC179.pdf",
        "scripts/launch-app.ps1",
        "scripts/lib/RuntimeLayout.ps1",
        "scripts/lib/ServerControl.ps1"
    )
}

function Test-SaphirReleaseFiles {
    param([Parameter(Mandatory = $true)][string]$ReleasePath)

    $applicationLayout = Resolve-SaphirApplicationLayout -ApplicationRoot $ReleasePath
    if ($null -eq $applicationLayout) {
        return $false
    }

    foreach ($relativePath in Get-SaphirRequiredReleaseFiles) {
        $candidatePath = Join-Path -Path $ReleasePath -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return $false
        }
    }

    if (Test-Path -LiteralPath (Join-Path -Path $ReleasePath -ChildPath "data")) {
        return $false
    }

    # Legacy releases carry a self-contained RuntimeLayout that knows their old
    # paths. Canonical releases load the shared resolver at runtime, so require
    # it only for the new topology to keep existing AppData caches valid.
    if ([string]$applicationLayout.Kind -eq "Canonical" -and
        -not (Test-Path -LiteralPath (Join-Path -Path $ReleasePath -ChildPath "scripts/lib/ApplicationLayout.ps1") -PathType Leaf)) {
        return $false
    }

    return $true
}

function Assert-SaphirZipEntriesSafe {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $destinationPath = [System.IO.Path]::GetFullPath($DestinationRoot)
    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    $destinationPrefix = $destinationPath.TrimEnd([char[]]@([char]92, [char]47)) + $separator
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($entryName)) {
                continue
            }
            if ($entryName.StartsWith("/") -or $entryName.StartsWith("\") -or $entryName.Contains(":")) {
                throw "The SAPHIR release ZIP contains an unsafe file path."
            }

            $entryPath = [System.IO.Path]::GetFullPath((Join-Path -Path $destinationPath -ChildPath $entryName))
            if (-not $entryPath.StartsWith($destinationPrefix, (Get-SaphirPathStringComparison)) -and
                -not $entryPath.Equals($destinationPath, (Get-SaphirPathStringComparison))) {
                throw "The SAPHIR release ZIP contains an unsafe file path."
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Read-SaphirInstalledReleaseMarker {
    param([Parameter(Mandatory = $true)][string]$ReleasePath)

    $markerPath = Join-Path -Path $ReleasePath -ChildPath ".saphir-release.json"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Test-SaphirCachedRelease {
    param(
        [Parameter(Mandatory = $true)][string]$ReleasePath,
        [Parameter(Mandatory = $true)]$Manifest
    )

    if (-not (Test-Path -LiteralPath $ReleasePath -PathType Container) -or -not (Test-SaphirReleaseFiles -ReleasePath $ReleasePath)) {
        return $false
    }

    $marker = Read-SaphirInstalledReleaseMarker -ReleasePath $ReleasePath
    if ($null -eq $marker) {
        return $false
    }

    return ([string]$marker.releaseId -eq [string]$Manifest.ReleaseId -and
        ([string]$marker.sha256).ToLowerInvariant() -eq [string]$Manifest.Sha256 -and
        [string]$marker.dataFolderPath -eq [string]$Manifest.DataFolderPath)
}

function Install-SaphirCachedRelease {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [switch]$ForceReinstall
    )

    $versionsRoot = Join-Path -Path $CacheRoot -ChildPath "versions"
    $downloadsRoot = Join-Path -Path $CacheRoot -ChildPath "downloads"
    Ensure-SaphirLocalDirectory -Path $versionsRoot
    Ensure-SaphirLocalDirectory -Path $downloadsRoot

    $releasePath = Join-Path -Path $versionsRoot -ChildPath ([string]$Manifest.ReleaseId)
    if (-not $ForceReinstall -and (Test-SaphirCachedRelease -ReleasePath $releasePath -Manifest $Manifest)) {
        return [PSCustomObject]@{
            ReleaseId      = [string]$Manifest.ReleaseId
            ReleasePath    = $releasePath
            LaunchScript   = Join-Path -Path $releasePath -ChildPath "scripts/launch-app.ps1"
            DataFolderPath = [string]$Manifest.DataFolderPath
            Sha256         = [string]$Manifest.Sha256
            Installed      = $false
        }
    }

    if (Test-Path -LiteralPath $releasePath) {
        $existingMarker = Read-SaphirInstalledReleaseMarker -ReleasePath $releasePath
        if ($null -ne $existingMarker -and [string]$existingMarker.releaseId -eq [string]$Manifest.ReleaseId) {
            $sameHash = ([string]$existingMarker.sha256).ToLowerInvariant() -eq [string]$Manifest.Sha256
            $sameDataFolder = [string]$existingMarker.dataFolderPath -eq [string]$Manifest.DataFolderPath
            if (-not $sameHash -or -not $sameDataFolder) {
                throw "Release '$($Manifest.ReleaseId)' was already installed with different immutable settings. Publish a new release identifier."
            }
        }
    }
    if (-not (Test-Path -LiteralPath $Manifest.PackagePath -PathType Leaf)) {
        throw "The SAPHIR release package is unavailable: $($Manifest.PackagePath)"
    }
    $operationId = [Guid]::NewGuid().ToString("N")
    $downloadPath = Join-Path -Path $downloadsRoot -ChildPath ("{0}.{1}.zip" -f $Manifest.ReleaseId, $operationId)
    $stagingPath = Join-Path -Path $versionsRoot -ChildPath (".{0}.{1}.staging" -f $Manifest.ReleaseId, $operationId)
    $replacementPath = Join-Path -Path $versionsRoot -ChildPath (".{0}.{1}.replaced" -f $Manifest.ReleaseId, $operationId)
    $replacementCommitted = $false

    try {
        Write-Host "Downloading SAPHIR release $($Manifest.ReleaseId) to this computer..."
        Copy-Item -LiteralPath $Manifest.PackagePath -Destination $downloadPath -Force -ErrorAction Stop

        $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne [string]$Manifest.Sha256) {
            throw "The downloaded SAPHIR release did not pass its integrity check."
        }

        Assert-SaphirZipEntriesSafe -ZipPath $downloadPath -DestinationRoot $stagingPath
        Ensure-SaphirLocalDirectory -Path $stagingPath
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $stagingPath -Force -ErrorAction Stop
        if (-not (Test-SaphirReleaseFiles -ReleasePath $stagingPath)) {
            throw "The downloaded SAPHIR release is incomplete or contains an unexpected data folder."
        }

        Write-SaphirJsonFileAtomic -Path (Join-Path -Path $stagingPath -ChildPath ".saphir-release.json") -Value ([ordered]@{
            schemaVersion = 1
            releaseId     = [string]$Manifest.ReleaseId
            sha256        = [string]$Manifest.Sha256
            dataFolderPath = [string]$Manifest.DataFolderPath
            installedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        })

        if (Test-Path -LiteralPath $releasePath) {
            Move-Item -LiteralPath $releasePath -Destination $replacementPath -ErrorAction Stop
        }

        try {
            Move-Item -LiteralPath $stagingPath -Destination $releasePath -ErrorAction Stop
            $replacementCommitted = $true
        }
        catch {
            if ((Test-Path -LiteralPath $replacementPath -PathType Container) -and
                -not (Test-Path -LiteralPath $releasePath)) {
                Move-Item -LiteralPath $replacementPath -Destination $releasePath -ErrorAction SilentlyContinue
            }
            throw
        }
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stagingPath) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($replacementCommitted -and (Test-Path -LiteralPath $replacementPath)) {
            Remove-Item -LiteralPath $replacementPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{
        ReleaseId      = [string]$Manifest.ReleaseId
        ReleasePath    = $releasePath
        LaunchScript   = Join-Path -Path $releasePath -ChildPath "scripts/launch-app.ps1"
        DataFolderPath = [string]$Manifest.DataFolderPath
        Sha256         = [string]$Manifest.Sha256
        Installed      = $true
    }
}

function Resolve-SaphirCachedRelease {
    param(
        [Parameter(Mandatory = $true)][string]$DistributionRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$CacheRoot = "",
        [switch]$ForceReinstall
    )

    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = Get-SaphirLocalAppRoot
    }
    Ensure-SaphirLocalDirectory -Path $CacheRoot

    $manifest = Read-SaphirReleaseManifest -ManifestPath $ManifestPath -DistributionRoot $DistributionRoot
    return (Install-SaphirCachedRelease -Manifest $manifest -CacheRoot $CacheRoot -ForceReinstall:$ForceReinstall)
}

function Get-SaphirActiveRelease {
    param([Parameter(Mandatory = $true)][string]$CacheRoot)

    $activePath = Join-Path -Path $CacheRoot -ChildPath "active.json"
    if (-not (Test-Path -LiteralPath $activePath -PathType Leaf)) {
        return $null
    }

    try {
        $active = Get-Content -LiteralPath $activePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $releaseId = [string]$active.releaseId
        $activeHash = ([string]$active.sha256).ToLowerInvariant()
        if ([int]$active.schemaVersion -ne 1 -or -not (Test-SaphirReleaseId -ReleaseId $releaseId) -or $activeHash -notmatch "^[a-f0-9]{64}$") {
            return $null
        }

        $releasePath = Join-Path -Path (Join-Path -Path $CacheRoot -ChildPath "versions") -ChildPath $releaseId
        if (-not (Test-SaphirReleaseFiles -ReleasePath $releasePath)) {
            return $null
        }
        $installedMarker = Read-SaphirInstalledReleaseMarker -ReleasePath $releasePath
        if ($null -eq $installedMarker -or
            [string]$installedMarker.releaseId -ne $releaseId -or
            ([string]$installedMarker.sha256).ToLowerInvariant() -ne $activeHash) {
            return $null
        }

        return [PSCustomObject]@{
            ReleaseId    = $releaseId
            ReleasePath  = $releasePath
            LaunchScript = Join-Path -Path $releasePath -ChildPath "scripts/launch-app.ps1"
            Sha256       = $activeHash
        }
    }
    catch {
        return $null
    }
}

function Get-SaphirFailedRelease {
    param([Parameter(Mandatory = $true)][string]$CacheRoot)

    $failedPath = Join-Path -Path $CacheRoot -ChildPath "failed.json"
    if (-not (Test-Path -LiteralPath $failedPath -PathType Leaf)) {
        return $null
    }

    try {
        $failed = Get-Content -LiteralPath $failedPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $releaseId = [string]$failed.releaseId
        $sha256 = ([string]$failed.sha256).ToLowerInvariant()
        if ([int]$failed.schemaVersion -ne 1 -or
            -not (Test-SaphirReleaseId -ReleaseId $releaseId) -or
            $sha256 -notmatch "^[a-f0-9]{64}$") {
            return $null
        }

        return [PSCustomObject]@{
            ReleaseId = $releaseId
            Sha256    = $sha256
        }
    }
    catch {
        return $null
    }
}

function Set-SaphirFailedRelease {
    param(
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )

    Write-SaphirJsonFileAtomic -Path (Join-Path -Path $CacheRoot -ChildPath "failed.json") -Value ([ordered]@{
        schemaVersion = 1
        releaseId     = [string]$Manifest.ReleaseId
        sha256        = [string]$Manifest.Sha256
        failedAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
    })
}

function Remove-SaphirFailedRelease {
    param([Parameter(Mandatory = $true)][string]$CacheRoot)

    $failedPath = Join-Path -Path $CacheRoot -ChildPath "failed.json"
    if (Test-Path -LiteralPath $failedPath) {
        Remove-Item -LiteralPath $failedPath -Force -ErrorAction SilentlyContinue
    }
}

function Repair-SaphirInterruptedCacheOperations {
    param([Parameter(Mandatory = $true)][string]$CacheRoot)

    $versionsRoot = Join-Path -Path $CacheRoot -ChildPath "versions"
    $downloadsRoot = Join-Path -Path $CacheRoot -ChildPath "downloads"

    if (Test-Path -LiteralPath $versionsRoot -PathType Container) {
        foreach ($replacement in @(Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^\..+\.[a-f0-9]{32}\.replaced$" })) {
            $marker = Read-SaphirInstalledReleaseMarker -ReleasePath $replacement.FullName
            $releaseId = if ($null -ne $marker) { [string]$marker.releaseId } else { "" }
            if ([string]::IsNullOrWhiteSpace($releaseId) -and $replacement.Name -match "^\.(.+)\.[a-f0-9]{32}\.replaced$") {
                $releaseId = [string]$matches[1]
            }
            if (Test-SaphirReleaseId -ReleaseId $releaseId) {
                $releasePath = Join-Path -Path $versionsRoot -ChildPath $releaseId
                if (-not (Test-Path -LiteralPath $releasePath)) {
                    try {
                        Move-Item -LiteralPath $replacement.FullName -Destination $releasePath -ErrorAction Stop
                        continue
                    }
                    catch {
                        Write-Warning "Unable to restore interrupted SAPHIR release '$releaseId'."
                    }
                }
                elseif (Test-Path -LiteralPath $releasePath -PathType Container) {
                    Remove-Item -LiteralPath $replacement.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        foreach ($staging in @(Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^\..+\.[a-f0-9]{32}\.staging$" })) {
            Remove-Item -LiteralPath $staging.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $downloadsRoot -PathType Container) {
        Get-ChildItem -LiteralPath $downloadsRoot -File -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Set-SaphirActiveRelease {
    param(
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [Parameter(Mandatory = $true)]$Release
    )

    Write-SaphirJsonFileAtomic -Path (Join-Path -Path $CacheRoot -ChildPath "active.json") -Value ([ordered]@{
        schemaVersion = 1
        releaseId     = [string]$Release.ReleaseId
        sha256        = [string]$Release.Sha256
        activatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    })
}

function Remove-OldSaphirCachedReleases {
    param(
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [string[]]$KeepReleaseIds = @(),
        [int]$MaximumVersionCount = 2
    )

    $versionsRoot = Join-Path -Path $CacheRoot -ChildPath "versions"
    if (-not (Test-Path -LiteralPath $versionsRoot -PathType Container)) {
        return
    }

    $releaseDirectories = @(Get-ChildItem -LiteralPath $versionsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith(".") } |
        Sort-Object LastWriteTime -Descending)
    $selectedNames = @()
    foreach ($directory in $releaseDirectories) {
        if ($KeepReleaseIds -contains $directory.Name -and $selectedNames -notcontains $directory.Name) {
            $selectedNames += $directory.Name
        }
    }

    $remainingSlots = [math]::Max(0, ($MaximumVersionCount - $selectedNames.Count))
    foreach ($directory in $releaseDirectories) {
        if ($remainingSlots -le 0) {
            break
        }
        if ($selectedNames -notcontains $directory.Name) {
            $selectedNames += $directory.Name
            $remainingSlots--
        }
    }

    foreach ($directory in $releaseDirectories) {
        if ($selectedNames -contains $directory.Name) {
            continue
        }

        try {
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Unable to remove old local SAPHIR release '$($directory.Name)'."
        }
    }
}

function Enter-SaphirCacheMutex {
    param(
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [int]$TimeoutSeconds = 90
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($CacheRoot).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedRoot))
    }
    finally {
        $sha.Dispose()
    }
    $hashText = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").Substring(0, 20)
    $mutex = New-Object System.Threading.Mutex($false, ("SAPHIRAppCache-{0}" -f $hashText))

    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }

    if (-not $acquired) {
        $mutex.Dispose()
        throw "Another SAPHIR installation is still running. Wait a moment and try again."
    }

    return $mutex
}

function Exit-SaphirCacheMutex {
    param($Mutex)

    if ($null -eq $Mutex) {
        return
    }

    try {
        $Mutex.ReleaseMutex()
    }
    catch {
    }
    $Mutex.Dispose()
}
