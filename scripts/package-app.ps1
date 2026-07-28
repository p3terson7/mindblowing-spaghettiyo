param(
    [string]$OutputRoot = "",
    [string]$DataFolderPath = "",
    [string]$ReleaseId = "",
    [switch]$NoZip,
    [switch]$AllowLocalDataPath
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path

function Ensure-PackageDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Copy-PackageItem {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required package item is missing: $Source"
    }

    $destinationParent = Split-Path -Path $Destination -Parent
    if ($destinationParent) {
        Ensure-PackageDirectory -Path $destinationParent
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force -Recurse:$Recurse -ErrorAction Stop
}

function Write-PackagePlainTextGuide {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required package item is missing: $Source"
    }

    $destinationParent = Split-Path -Path $Destination -Parent
    if ($destinationParent) {
        Ensure-PackageDirectory -Path $destinationParent
    }

    $guideText = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)
    $guideText = $guideText -replace "(?m)^#{1,6}[ `t]+", ""
    $backtickCharacter = [string][char]96
    $guideText = $guideText.Replace("**", "").Replace($backtickCharacter, "")
    $guideText = $guideText -replace "(?m)^---[ `t]*$", ("=" * 60)
    # A BOM keeps French accents readable even in older Windows Notepad builds.
    [System.IO.File]::WriteAllText($Destination, $guideText, (New-Object System.Text.UTF8Encoding($true)))
}

function Convert-PackagePowerShellFilesToUtf8Bom {
    param([Parameter(Mandatory = $true)][string]$Root)

    $utf8WithoutBomStrict = New-Object System.Text.UTF8Encoding($false, $true)
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop | Where-Object { $_.Extension -in @(".ps1", ".psd1", ".psm1") })) {
        $contents = [System.IO.File]::ReadAllText($file.FullName, $utf8WithoutBomStrict)
        [System.IO.File]::WriteAllText($file.FullName, $contents, $utf8WithBom)
    }
}

function Get-PackagePathStringComparison {
    $windowsHost = $PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ($windowsHost) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }
    return [System.StringComparison]::Ordinal
}

function Test-PackagePathContains {
    param(
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )

    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([char[]]@([char]92, [char]47))
    $child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd([char[]]@([char]92, [char]47))
    $comparison = Get-PackagePathStringComparison
    if ($child.Equals($parent, $comparison)) {
        return $true
    }

    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    return $child.StartsWith(($parent + $separator), $comparison)
}

function Enter-PackagePublishLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ((Get-Date) -ge $deadline) {
                throw "Another SAPHIR release is currently being published. Wait for it to finish and try again."
            }
            Start-Sleep -Milliseconds 500
        }
    } while ($true)
}

function Resolve-PackageNetworkPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedItem = Get-Item -LiteralPath $Path -ErrorAction Stop
    $resolvedPath = [string]$resolvedItem.FullName
    if ($resolvedPath.StartsWith("\\")) {
        return [PSCustomObject]@{
            Path          = $resolvedPath
            IsNetwork     = $true
            IsMappedDrive = $false
            ResolvedToUnc = $true
        }
    }

    $windowsHost = $PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ($windowsHost -and $resolvedPath -match "^([A-Za-z]):[\\/](.*)$") {
        $driveLetter = ([string]$matches[1]).ToUpperInvariant()
        $relativePath = ([string]$matches[2]).TrimStart([char[]]@([char]92, [char]47))
        $drive = Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
        $networkRoot = if ($null -ne $drive -and $drive.PSObject.Properties.Name -contains "DisplayRoot") {
            [string]$drive.DisplayRoot
        }
        else {
            ""
        }
        if ([string]::IsNullOrWhiteSpace($networkRoot) -and $null -ne $drive) {
            $networkRoot = [string]$drive.Root
        }
        if ([string]::IsNullOrWhiteSpace($networkRoot) -or -not $networkRoot.StartsWith("\\")) {
            try {
                $logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $driveLetter) -ErrorAction Stop
                $networkRoot = [string]$logicalDisk.ProviderName
            }
            catch {
                $networkRoot = ""
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($networkRoot) -and $networkRoot.StartsWith("\\")) {
            $networkRoot = $networkRoot.TrimEnd([char[]]@([char]92, [char]47))
            $networkPath = if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $networkRoot
            }
            else {
                $networkRoot + "\" + ($relativePath -replace "/", "\")
            }
            return [PSCustomObject]@{
                Path          = $networkPath
                IsNetwork     = $true
                IsMappedDrive = $true
                ResolvedToUnc = $true
            }
        }

        try {
            $driveInfo = New-Object -TypeName System.IO.DriveInfo -ArgumentList (("{0}:\" -f $driveLetter))
            if ($driveInfo.DriveType -eq [System.IO.DriveType]::Network) {
                return [PSCustomObject]@{
                    Path          = $resolvedPath
                    IsNetwork     = $true
                    IsMappedDrive = $true
                    ResolvedToUnc = $false
                }
            }
        }
        catch {
            # The normal local-path validation below will report the failure.
        }
    }

    return [PSCustomObject]@{
        Path          = $resolvedPath
        IsNetwork     = $false
        IsMappedDrive = $false
        ResolvedToUnc = $false
    }
}

function Resolve-PackageDataFolderPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowLocal
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "DataFolderPath is required. Use a shared UNC path or a mapped network drive such as R:\SAPHIR-Data."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The configured SAPHIR data folder does not exist or is unavailable: $Path"
    }

    $pathInfo = Resolve-PackageNetworkPath -Path $Path
    $resolvedPath = [string]$pathInfo.Path
    if ([bool]$pathInfo.IsMappedDrive -and -not [bool]$pathInfo.ResolvedToUnc) {
        Write-Warning ("Windows identifies '{0}' as a network drive, but its UNC provider path could not be read. SAPHIR will store '{1}' in the release. Every employee must therefore have the same drive letter mapped before launching SAPHIR." -f $Path, $resolvedPath)
    }

    if (-not [bool]$pathInfo.IsNetwork -and -not $AllowLocal) {
        throw "Production releases require a shared UNC path or a mapped network drive such as R:\SAPHIR-Data. Windows reports this path as a local drive."
    }

    return $resolvedPath
}

function Write-PackageJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $temporaryPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $json = ConvertTo-Json -InputObject $Value -Depth 6
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

function Publish-PackageFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required package item is missing: $Source"
    }

    $destinationParent = Split-Path -Path $Destination -Parent
    if ($destinationParent) {
        Ensure-PackageDirectory -Path $destinationParent
    }

    # The temporary file lives beside its destination so the final rename stays
    # on the same share/volume and employees never read a partially copied file.
    $temporaryPath = Join-Path -Path $destinationParent -ChildPath (".{0}.{1}.publishing" -f ([System.IO.Path]::GetFileName($Destination)), [Guid]::NewGuid().ToString("N"))
    try {
        Copy-Item -LiteralPath $Source -Destination $temporaryPath -Force -ErrorAction Stop
        Move-Item -LiteralPath $temporaryPath -Destination $Destination -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-PackageReleaseId {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$" -or
        $Value.EndsWith(".")) {
        return $false
    }

    $deviceName = $Value.Split(".")[0].ToUpperInvariant()
    return ($deviceName -notmatch "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$")
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path -Path $repoRoot -ChildPath "dist"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
Ensure-PackageDirectory -Path $OutputRoot
$outputPathInfo = Resolve-PackageNetworkPath -Path $OutputRoot
if ([bool]$outputPathInfo.IsNetwork -and [bool]$outputPathInfo.ResolvedToUnc) {
    $OutputRoot = [string]$outputPathInfo.Path
}

if ([string]::IsNullOrWhiteSpace($ReleaseId)) {
    $ReleaseId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
}
if (-not (Test-PackageReleaseId -Value $ReleaseId)) {
    throw "ReleaseId must be a Windows-safe name containing only letters, numbers, periods, underscores, and hyphens."
}

$resolvedDataFolderPath = Resolve-PackageDataFolderPath -Path $DataFolderPath -AllowLocal:$AllowLocalDataPath
$distributionRoot = Join-Path -Path $OutputRoot -ChildPath "SAPHIR-Distribution"
$deploymentRoot = Join-Path -Path $distributionRoot -ChildPath "deployment"
$releasesRoot = Join-Path -Path $deploymentRoot -ChildPath "releases"

if ((Test-PackagePathContains -ParentPath $distributionRoot -ChildPath $resolvedDataFolderPath) -or
    (Test-PackagePathContains -ParentPath $resolvedDataFolderPath -ChildPath $distributionRoot)) {
    throw "The SAPHIR distribution folder and shared data folder must be separate and must not contain one another."
}

$buildRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-build-{0}" -f [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path -Path $buildRoot -ChildPath "runtime"
$bootstrapRoot = Join-Path -Path $buildRoot -ChildPath "bootstrap"
$temporaryReleaseZip = Join-Path -Path $buildRoot -ChildPath ("SAPHIR-{0}.zip" -f $ReleaseId)
$publishLock = Enter-PackagePublishLock -Path (Join-Path -Path $OutputRoot -ChildPath ".SAPHIR-Distribution.publish.lock")

try {
    Ensure-PackageDirectory -Path $distributionRoot
    Ensure-PackageDirectory -Path $deploymentRoot
    Ensure-PackageDirectory -Path $releasesRoot

    # Stage every share-side file first. Nothing visible to employees is changed
    # until the release ZIP has also been built and validated successfully.
    Ensure-PackageDirectory -Path $bootstrapRoot
    Ensure-PackageDirectory -Path (Join-Path -Path $bootstrapRoot -ChildPath "scripts/lib")
    foreach ($launcherName in @("Launch SAPHIR.bat", "Launch SAPHIR.vbs", "SAPHIR Launcher.vbs", "Stop SAPHIR.bat", "Stop SAPHIR.vbs", "Install SAPHIR Shortcut.vbs", "SAPHIR.ico")) {
        Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath $launcherName) -Destination (Join-Path -Path $bootstrapRoot -ChildPath $launcherName)
    }
    Write-PackagePlainTextGuide -Source (Join-Path -Path $repoRoot -ChildPath "docs/EMPLOYEE-QUICK-START.md") -Destination (Join-Path -Path $bootstrapRoot -ChildPath "GUIDE-DEMARRAGE-SAPHIR.txt")
    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "scripts/launch-cached-app.ps1") -Destination (Join-Path -Path $bootstrapRoot -ChildPath "scripts/launch-cached-app.ps1")
    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "scripts/saphir-launcher.ps1") -Destination (Join-Path -Path $bootstrapRoot -ChildPath "scripts/saphir-launcher.ps1")
    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "scripts/stop-all.ps1") -Destination (Join-Path -Path $bootstrapRoot -ChildPath "scripts/stop-all.ps1")
    foreach ($libraryName in @("LauncherControl.ps1", "LocalAppCache.ps1", "RuntimeLayout.ps1", "ServerControl.ps1")) {
        Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath ("scripts/lib/{0}" -f $libraryName)) -Destination (Join-Path -Path $bootstrapRoot -ChildPath ("scripts/lib/{0}" -f $libraryName))
    }
    Convert-PackagePowerShellFilesToUtf8Bom -Root $bootstrapRoot

    Ensure-PackageDirectory -Path $runtimeRoot
    Ensure-PackageDirectory -Path (Join-Path -Path $runtimeRoot -ChildPath "apps")
    Ensure-PackageDirectory -Path (Join-Path -Path $runtimeRoot -ChildPath "docs")
    Ensure-PackageDirectory -Path (Join-Path -Path $runtimeRoot -ChildPath "scripts/lib")

    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "apps/admin") -Destination (Join-Path -Path $runtimeRoot -ChildPath "apps/admin") -Recurse
    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "docs/GC179.pdf") -Destination (Join-Path -Path $runtimeRoot -ChildPath "docs/GC179.pdf")
    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "scripts/launch-app.ps1") -Destination (Join-Path -Path $runtimeRoot -ChildPath "scripts/launch-app.ps1")
    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "scripts/lib/RuntimeLayout.ps1") -Destination (Join-Path -Path $runtimeRoot -ChildPath "scripts/lib/RuntimeLayout.ps1")
    Copy-PackageItem -Source (Join-Path -Path $repoRoot -ChildPath "scripts/lib/ServerControl.ps1") -Destination (Join-Path -Path $runtimeRoot -ChildPath "scripts/lib/ServerControl.ps1")

    Get-ChildItem -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq ".DS_Store" } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $backendReadme = Join-Path -Path $runtimeRoot -ChildPath "apps/admin/backend/README.md"
    if (Test-Path -LiteralPath $backendReadme) {
        Remove-Item -LiteralPath $backendReadme -Force
    }

    $safeDataFolderPath = $resolvedDataFolderPath.Replace("'", "''")
    $runtimeConfig = @"
@{
    ListenerPrefix = "http://localhost:8081/"
    DataFolderPath = '$safeDataFolderPath'
    EnableDemoSeed = `$false
    EnableGc179Import = `$true
}
"@
    Set-Content -LiteralPath (Join-Path -Path $runtimeRoot -ChildPath "apps/admin/backend/admin-config.psd1") -Value $runtimeConfig -Encoding UTF8
    Convert-PackagePowerShellFilesToUtf8Bom -Root $runtimeRoot

    foreach ($requiredRuntimeFile in @(
        "apps/admin/backend/admin-server.ps1",
        "apps/admin/backend/lib/ControlService.ps1",
        "apps/admin/backend/services/RouteDispatchService.ps1",
        "apps/admin/frontend/index.html",
        "docs/GC179.pdf",
        "scripts/launch-app.ps1",
        "scripts/lib/RuntimeLayout.ps1",
        "scripts/lib/ServerControl.ps1"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $runtimeRoot -ChildPath $requiredRuntimeFile) -PathType Leaf)) {
            throw "Runtime package validation failed; missing $requiredRuntimeFile"
        }
    }
    if (Test-Path -LiteralPath (Join-Path -Path $runtimeRoot -ChildPath "data")) {
        throw "Runtime package validation failed because a data folder was included."
    }

    Compress-Archive -Path (Join-Path -Path $runtimeRoot -ChildPath "*") -DestinationPath $temporaryReleaseZip -CompressionLevel Optimal -Force
    $releaseHash = (Get-FileHash -LiteralPath $temporaryReleaseZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $releaseFileName = "SAPHIR-{0}.zip" -f $ReleaseId
    $publishedReleasePath = Join-Path -Path $releasesRoot -ChildPath $releaseFileName

    if (Test-Path -LiteralPath $publishedReleasePath -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $publishedReleasePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -ne $releaseHash) {
            throw "Release '$ReleaseId' already exists with different contents. Use a new ReleaseId."
        }
    }
    else {
        $publishingPath = Join-Path -Path $releasesRoot -ChildPath (".{0}.{1}.publishing" -f $releaseFileName, [Guid]::NewGuid().ToString("N"))
        try {
            Copy-Item -LiteralPath $temporaryReleaseZip -Destination $publishingPath -Force -ErrorAction Stop
            $publishedCopyHash = (Get-FileHash -LiteralPath $publishingPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($publishedCopyHash -ne $releaseHash) {
                throw "The release ZIP changed while it was copied to the distribution folder."
            }
            Move-Item -LiteralPath $publishingPath -Destination $publishedReleasePath -ErrorAction Stop
        }
        finally {
            if (Test-Path -LiteralPath $publishingPath) {
                Remove-Item -LiteralPath $publishingPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Publish complete bootstrap files through same-directory temporary names.
    # Libraries go first and launchers last so a concurrent employee launch sees
    # either the old complete bootstrap or the new complete file contents.
    $bootstrapRelativePaths = @(
        "scripts/lib/RuntimeLayout.ps1",
        "scripts/lib/ServerControl.ps1",
        "scripts/lib/LocalAppCache.ps1",
        "scripts/lib/LauncherControl.ps1",
        "scripts/stop-all.ps1",
        "scripts/launch-cached-app.ps1",
        "scripts/saphir-launcher.ps1",
        "GUIDE-DEMARRAGE-SAPHIR.txt",
        "SAPHIR.ico",
        "SAPHIR Launcher.vbs",
        "Install SAPHIR Shortcut.vbs",
        "Stop SAPHIR.bat",
        "Stop SAPHIR.vbs",
        "Launch SAPHIR.bat",
        "Launch SAPHIR.vbs"
    )
    foreach ($relativePath in $bootstrapRelativePaths) {
        Publish-PackageFileAtomic -Source (Join-Path -Path $bootstrapRoot -ChildPath $relativePath) -Destination (Join-Path -Path $distributionRoot -ChildPath $relativePath)
    }

    # Publish the small pointer last. Employees either see the previous complete
    # release or this complete, checksummed release—never a half-copied update.
    $manifest = [ordered]@{
        schemaVersion  = 1
        releaseId      = $ReleaseId
        packagePath    = "deployment/releases/$releaseFileName"
        sha256         = $releaseHash
        dataFolderPath = $resolvedDataFolderPath
        publishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-PackageJsonAtomic -Path (Join-Path -Path $deploymentRoot -ChildPath "current.json") -Value $manifest

    # Keep the manifest's current release plus two server-side rollback choices,
    # even if an administrator intentionally republishes an older release ID.
    $oldReleases = @(Get-ChildItem -LiteralPath $releasesRoot -Filter "SAPHIR-*.zip" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $publishedReleasePath } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 2)
    foreach ($oldRelease in $oldReleases) {
        Remove-Item -LiteralPath $oldRelease.FullName -Force -ErrorAction SilentlyContinue
    }

    $outerZipPath = ""
    if (-not $NoZip) {
        $outerZipPath = Join-Path -Path $OutputRoot -ChildPath ("SAPHIR-Distribution-{0}.zip" -f $ReleaseId)
        try {
            if (Test-Path -LiteralPath $outerZipPath) {
                Remove-Item -LiteralPath $outerZipPath -Force
            }
            Compress-Archive -Path (Join-Path -Path $distributionRoot -ChildPath "*") -DestinationPath $outerZipPath -CompressionLevel Optimal -Force

            $oldDistributionZips = @(Get-ChildItem -LiteralPath $OutputRoot -Filter "SAPHIR-Distribution-*.zip" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $outerZipPath } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip 2)
            foreach ($oldDistributionZip in $oldDistributionZips) {
                Remove-Item -LiteralPath $oldDistributionZip.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Warning "The live SAPHIR release was published, but the optional distribution ZIP could not be created. $($_.Exception.Message)"
            $outerZipPath = ""
        }
    }

    [PSCustomObject]@{
        DistributionFolder = $distributionRoot
        ReleaseId          = $ReleaseId
        ReleasePackage     = $publishedReleasePath
        ReleaseSha256      = $releaseHash
        DistributionZip    = $outerZipPath
        DataFolder         = $resolvedDataFolderPath
    }
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $publishLock) {
        $publishLock.Dispose()
    }
}
