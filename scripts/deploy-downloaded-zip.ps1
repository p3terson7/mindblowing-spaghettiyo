#requires -Version 5.1
<#
.SYNOPSIS
Publish a downloaded SAPHIR GitHub ZIP. Standalone: safe to copy to Desktop.
.EXAMPLE
.\deploy-downloaded-zip.ps1 -WhatIf
.EXAMPLE
.\deploy-downloaded-zip.ps1 -ZipPath 'C:\Downloads\SAPHIR.zip'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ZipPath = '',
    [string]$OutputRoot = '',
    [string]$DataFolderPath = '',
    [string]$ReleaseId = '',
    [switch]$AllowLocalDataPath
)

# EDIT THESE SETTINGS ONCE. OutputRoot is the PARENT of SAPHIR-Distribution,
# not SAPHIR-Distribution itself. Leave DATA outside that distribution folder.
$Configuration = @{
    DownloadsFolder = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
    ZipPattern = 'mindblowing-spaghettiyo-codex-windows-launcher*.zip'
    OutputRoot = ''       # Example: 'R:\SAPHIR\deployed'
    DataFolderPath = ''   # Example: 'R:\SAPHIR\DATA' (or a shared UNC path)
}

$ErrorActionPreference = 'Stop'
if (-not $OutputRoot) { $OutputRoot = $Configuration.OutputRoot }
if (-not $DataFolderPath) { $DataFolderPath = $Configuration.DataFolderPath }
if (-not $OutputRoot -or -not $DataFolderPath) {
    throw 'First edit OutputRoot and DataFolderPath in the Configuration section at the top of this script.'
}
if (-not [IO.Path]::IsPathRooted($OutputRoot) -or -not [IO.Path]::IsPathRooted($DataFolderPath)) {
    throw 'Deployment and DATA paths must be absolute paths, not paths relative to Desktop.'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$DataFolderPath = [IO.Path]::GetFullPath($DataFolderPath)
if ([IO.Path]::GetFileName($OutputRoot.TrimEnd([char[]]@('/', '\'))) -ieq 'SAPHIR-Distribution') {
    throw 'OutputRoot must be the parent folder of SAPHIR-Distribution, not SAPHIR-Distribution itself.'
}
if (-not [IO.Directory]::Exists($DataFolderPath)) { throw "DATA folder is missing or unavailable: $DataFolderPath" }

function Test-DeployPathInside([string]$Parent, [string]$Child) {
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@('/', '\'))
    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd([char[]]@('/', '\'))
    return $childPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $childPath.StartsWith($parentPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
$distribution = Join-Path $OutputRoot 'SAPHIR-Distribution'
if ((Test-DeployPathInside $distribution $DataFolderPath) -or (Test-DeployPathInside $DataFolderPath $distribution)) {
    throw 'DATA and SAPHIR-Distribution must be separate folders; neither may contain the other.'
}

if (-not $ZipPath) {
    $downloads = $Configuration.DownloadsFolder
    if (-not [IO.Directory]::Exists($downloads)) { throw "Downloads folder is unavailable: $downloads" }
    $zipCandidates = @(Get-ChildItem -LiteralPath $downloads -File -Filter $Configuration.ZipPattern -ErrorAction Stop | Sort-Object LastWriteTimeUtc -Descending)
    if ($zipCandidates.Count -eq 0) { throw "No completed ZIP matches '$($Configuration.ZipPattern)' in $downloads. Download it first or supply -ZipPath." }
    $ZipPath = $zipCandidates[0].FullName
}
$ZipPath = (Resolve-Path -LiteralPath $ZipPath -ErrorAction Stop).ProviderPath
if (-not [IO.File]::Exists($ZipPath) -or [IO.Path]::GetExtension($ZipPath) -ine '.zip') { throw 'ZipPath must identify an existing downloaded .zip file.' }
if (-not $ReleaseId) { $ReleaseId = 'desktop-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) }
if ($ReleaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or $ReleaseId.EndsWith('.') -or $ReleaseId.Split('.')[0] -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
    throw 'ReleaseId must be a Windows-safe release name.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-DeployZipName([string]$Name) {
    $normalized = $Name.Replace('\', '/')
    if (-not $normalized -or $normalized.StartsWith('/') -or $normalized -match '[:<>"|?*\x00-\x1f]') { throw "Unsafe ZIP path: $Name" }
    foreach ($part in $normalized.TrimEnd('/').Split('/')) {
        if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part -ne $part.TrimEnd([char[]]@('.', ' ')) -or
            $part.Split('.')[0] -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw "Unsafe ZIP path: $Name" }
    }
    return $normalized
}

$staging = $null; $archive = $null; $archiveStream = $null; $finished = $false
try {
    # Keep the download open read-only until extraction is complete, preventing
    # a Windows writer from changing the selected ZIP while it is being read.
    $archiveStream = [IO.FileStream]::new($ZipPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $zipHash = [BitConverter]::ToString($sha.ComputeHash($archiveStream)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $archiveStream.Position = 0
    $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $true)
    if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt 30000) { throw 'ZIP is empty or has too many entries.' }
    $members = @{}; $uncompressedBytes = [long]0
    foreach ($entry in $archive.Entries) {
        $name = Get-DeployZipName $entry.FullName
        $key = $name.TrimEnd('/')
        if ($members.ContainsKey($key)) { throw "Duplicate/case-ambiguous ZIP path: $name" }
        if ((($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) { throw "ZIP links are not allowed: $name" }
        $uncompressedBytes += $entry.Length
        if ($entry.Length -gt 268435456 -or $uncompressedBytes -gt 1073741824) { throw 'ZIP exceeds the extraction size limit (256 MiB/file, 1 GiB total).' }
        $members[$key] = [PSCustomObject]@{ name = $name; entry = $entry }
    }
    # GitHub adds one repository folder. Also accept an already flattened ZIP.
    # Never guess among two repositories or run the first script we encounter.
    $roots = @(foreach ($key in $members.Keys) {
        if ($key -eq 'scripts/package-app.ps1') { '' }
        elseif ($key.EndsWith('/scripts/package-app.ps1', [StringComparison]::OrdinalIgnoreCase)) {
            $key.Substring(0, $key.Length - 'scripts/package-app.ps1'.Length)
        }
    })
    if ($roots.Count -ne 1) { throw 'ZIP must contain exactly one SAPHIR repository with scripts/package-app.ps1.' }
    $prefix = [string]$roots[0]
    foreach ($required in @('scripts/package-app.ps1', 'app/backend/saphir-server.ps1', 'app/frontend/index.html', 'deploy/bootstrap/Launch SAPHIR.vbs')) {
        if (-not $members.ContainsKey($prefix + $required) -or $members[$prefix + $required].name.EndsWith('/')) { throw "ZIP is not a complete current SAPHIR checkout; missing $required." }
    }
    foreach ($member in $members.Values) {
        if ($prefix -and $member.name.TrimEnd('/') -ne $prefix.TrimEnd('/') -and
            -not $member.name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'ZIP contains files outside its SAPHIR repository folder.' }
    }

    Write-Host "Source ZIP : $ZipPath"
    Write-Host "SHA-256    : $zipHash"
    Write-Host "Publish to : $distribution"
    Write-Host "DATA       : $DataFolderPath (not modified)"
    Write-Host "Release    : $ReleaseId"
    if (-not $PSCmdlet.ShouldProcess($distribution, "Publish FULL SAPHIR release $ReleaseId from the displayed ZIP")) {
        $finished = $true
        return [PSCustomObject]@{ Published = $false; SourceZip = $ZipPath; SourceSha256 = $zipHash; DistributionFolder = $distribution }
    }

    $staging = Join-Path ([IO.Path]::GetTempPath()) ('saphir-desktop-deploy-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $sourceRoot = Join-Path $staging 'source'
    [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    Write-Host 'Extracting locally (GitHub metadata and repository DATA are excluded)...'
    foreach ($member in $members.Values) {
        $relative = $member.name.Substring([Math]::Min($prefix.Length, $member.name.Length))
        if (-not $relative) { continue }
        $first = $relative.Split('/')[0]
        if ($first -in @('.github', '.git', '.gitignore', '.gitattributes', 'data')) { continue }
        $destination = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
        if (-not (Test-DeployPathInside $sourceRoot $destination)) { throw 'ZIP entry escaped the staging folder.' }
        if ($member.name.EndsWith('/')) { [IO.Directory]::CreateDirectory($destination) | Out-Null; continue }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        $fileStream = [IO.FileStream]::new($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $entryStream = $null
        try {
            $entryStream = $member.entry.Open(); $buffer = New-Object byte[] 65536; $written = [long]0
            while (($readCount = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $written += $readCount
                if ($written -gt $member.entry.Length -or $written -gt 268435456) { throw 'ZIP entry expanded beyond its declared size/limit.' }
                $fileStream.Write($buffer, 0, $readCount)
            }
            if ($written -ne $member.entry.Length) { throw 'ZIP entry is incomplete; deployment stopped.' }
        }
        finally { if ($entryStream) { $entryStream.Dispose() }; $fileStream.Dispose() }
    }
    $archive.Dispose(); $archive = $null
    $archiveStream.Dispose(); $archiveStream = $null

    # Use the downloaded version's publisher, not a second deployment engine.
    # NoZip omits only the redundant outer distribution ZIP; the application
    # release ZIP, launchers and current.json are always published normally.
    Write-Host 'Building and publishing the full release...'
    $arguments = @{ OutputRoot = $OutputRoot; DataFolderPath = $DataFolderPath; ReleaseId = $ReleaseId; NoZip = $true }
    if ($AllowLocalDataPath) { $arguments.AllowLocalDataPath = $true }
    $result = & (Join-Path $sourceRoot 'scripts/package-app.ps1') @arguments
    if (-not $result.ReleasePackage -or [string]$result.ReleaseId -cne $ReleaseId) { throw 'Publisher did not return the expected full release result.' }
    $manifestPath = Join-Path $result.DistributionFolder 'deployment/current.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.releaseId -cne $ReleaseId -or [string]$manifest.sha256 -cne [string]$result.ReleaseSha256 -or
        -not [IO.File]::Exists($result.ReleasePackage)) { throw 'Published release pointer verification failed. Inspect current.json before retrying.' }
    $finished = $true
    Write-Host "Published successfully: $ReleaseId"
    Write-Host "Employees keep using: $($result.DistributionFolder)"
    Write-Host 'No DATA migration was run. Restart SAPHIR normally to pick up the new release.'
    [PSCustomObject]@{ Published = $true; ReleaseId = $ReleaseId; SourceZip = $ZipPath; SourceSha256 = $zipHash; DistributionFolder = $result.DistributionFolder; ReleasePackage = $result.ReleasePackage; DataFolder = $result.DataFolder }
}
catch {
    Write-Warning 'Deployment did not finish. The download and DATA were not deleted or migrated. Check the error and the existing current.json before retrying.'
    throw
}
finally {
    if ($archive) { $archive.Dispose() }
    if ($archiveStream) { $archiveStream.Dispose() }
    if ($staging) {
        if ($finished) {
            # The only recursively removed directory is our exact GUID-owned
            # local staging folder, never Downloads, DATA or the shared root.
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        else { Write-Warning "Local staging retained for troubleshooting: $staging" }
    }
}
