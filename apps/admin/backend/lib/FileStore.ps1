if (-not $script:TextFileCache) {
    $script:TextFileCache = @{}
}

if (-not $script:BinaryFileCache) {
    $script:BinaryFileCache = @{}
}

if (-not $script:FileMetadataCache) {
    $script:FileMetadataCache = @{}
}

if (-not $script:PreparedLockFolderPath) {
    $script:PreparedLockFolderPath = ""
}

if (-not $script:FileMetadataValidationIntervalMs) {
    $configuredMetadataCacheMs = 0
    $configuredMetadataCacheValue = [string]$env:SAPHIR_FILE_METADATA_CACHE_MS
    if ([string]::IsNullOrWhiteSpace($configuredMetadataCacheValue)) {
        $configuredMetadataCacheValue = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_FILE_METADATA_CACHE_MS"))
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredMetadataCacheValue)) {
        [int]::TryParse($configuredMetadataCacheValue, [ref]$configuredMetadataCacheMs) | Out-Null
    }

    $script:FileMetadataValidationIntervalMs = if ($configuredMetadataCacheMs -gt 0) { $configuredMetadataCacheMs } else { 30000 }
}

function Get-FileMetadataSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $nowUtc = (Get-Date).ToUniversalTime()
    $cacheEntry = $script:FileMetadataCache[$Path]
    if ($cacheEntry -and $cacheEntry.ValidatedAtUtc) {
        $cacheAgeMs = ($nowUtc - $cacheEntry.ValidatedAtUtc).TotalMilliseconds
        if ($cacheAgeMs -lt $script:FileMetadataValidationIntervalMs) {
            return $cacheEntry.Metadata
        }
    }

    # Get-Item both establishes existence and returns the metadata needed by
    # callers. A preceding Test-Path doubles the SMB round trips on every cold
    # validation.
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item -or [bool]$item.PSIsContainer) {
        $script:FileMetadataCache[$Path] = [PSCustomObject]@{
            ValidatedAtUtc = $nowUtc
            Metadata       = $null
        }
        return $null
    }

    $metadata = [PSCustomObject]@{
        Path           = $item.FullName
        LastWriteUtc   = $item.LastWriteTimeUtc
        LastWriteTicks = $item.LastWriteTimeUtc.Ticks
        Length         = $item.Length
    }
    $script:FileMetadataCache[$Path] = [PSCustomObject]@{
        ValidatedAtUtc = $nowUtc
        Metadata       = $metadata
    }

    return $metadata
}

function Clear-CachedFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:TextFileCache.ContainsKey($Path)) {
        $script:TextFileCache.Remove($Path) | Out-Null
    }

    if ($script:BinaryFileCache.ContainsKey($Path)) {
        $script:BinaryFileCache.Remove($Path) | Out-Null
    }

    if ($script:FileMetadataCache.ContainsKey($Path)) {
        $script:FileMetadataCache.Remove($Path) | Out-Null
    }
}

function Clear-FileMetadataValidationCache {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace([string]$Path)) {
        if ($script:FileMetadataCache.ContainsKey($Path)) {
            $script:FileMetadataCache.Remove($Path) | Out-Null
        }
        return
    }

    $script:FileMetadataCache = @{}
}

function Read-TextFileCached {
    param([Parameter(Mandatory = $true)][string]$Path)

    $metadata = Get-FileMetadataSnapshot -Path $Path
    if ($null -eq $metadata) {
        return $null
    }

    $cacheEntry = $script:TextFileCache[$Path]
    if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
        return [string]$cacheEntry.Content
    }

    $content = [System.IO.File]::ReadAllText($Path)
    $script:TextFileCache[$Path] = [PSCustomObject]@{
        LastWriteTicks = $metadata.LastWriteTicks
        Length         = $metadata.Length
        Content        = $content
    }

    return $content
}

function Read-FileBytesCached {
    param([Parameter(Mandatory = $true)][string]$Path)

    $metadata = Get-FileMetadataSnapshot -Path $Path
    if ($null -eq $metadata) {
        return $null
    }

    $cacheEntry = $script:BinaryFileCache[$Path]
    if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
        return $cacheEntry.Bytes
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $script:BinaryFileCache[$Path] = [PSCustomObject]@{
        LastWriteTicks = $metadata.LastWriteTicks
        Length         = $metadata.Length
        Bytes          = $bytes
    }

    return $bytes
}

function Get-LockFilePath {
    param([Parameter(Mandatory = $true)][string]$ResourcePath)

    # The lock directory is stable for the process lifetime. Preparing it once
    # removes an existence probe from every write transaction. Acquire retries
    # preparation if an administrator removes it while the server is running.
    if ([string]$script:PreparedLockFolderPath -ne [string]$lockFolder) {
        [System.IO.Directory]::CreateDirectory($lockFolder) | Out-Null
        $script:PreparedLockFolderPath = [string]$lockFolder
    }

    $resolvedResource = [System.IO.Path]::GetFullPath($ResourcePath)
    $resolvedRoot = [System.IO.Path]::GetFullPath($sharedFolder).TrimEnd([char[]]@([char]92, [char]47))
    $rootBoundary = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    # Every lock lives inside the shared data folder. Hash the stable relative
    # identity so R:\Data\users.json and \\server\share\Data\users.json use the
    # same lock file when both roots point to the same share.
    $lockIdentity = if ($resolvedResource.StartsWith($rootBoundary, $comparison)) {
        $resolvedResource.Substring($rootBoundary.Length)
    }
    else {
        $resolvedResource
    }
    $normalized = ($lockIdentity -replace "\\", "/").ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    $hash = ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ""
    return (Join-Path -Path $lockFolder -ChildPath ($hash + ".lock"))
}

function Acquire-ResourceLock {
    param(
        [Parameter(Mandatory = $true)][string]$ResourcePath,
        [int]$TimeoutMs = 30000,
        [int]$StaleLockMs = 120000
    )

    $lockPath = Get-LockFilePath -ResourcePath $ResourcePath
    $start = Get-Date

    while ($true) {
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
            $writer.WriteLine("host=$env:COMPUTERNAME")
            $writer.WriteLine("pid=$PID")
            $writer.WriteLine("utc=" + (Get-Date).ToUniversalTime().ToString("o"))
            $writer.Flush()

            # The lock only serializes writers; it does not make this process's
            # metadata/text cache current. Always discard any pre-lock snapshot
            # before a read-modify-write transaction starts.
            Clear-CachedFileContent -Path $ResourcePath

            return [PSCustomObject]@{
                Path   = $lockPath
                Stream = $stream
                Writer = $writer
            }
        }
        catch [System.IO.DirectoryNotFoundException] {
            $script:PreparedLockFolderPath = ""
            [System.IO.Directory]::CreateDirectory($lockFolder) | Out-Null
            $script:PreparedLockFolderPath = [string]$lockFolder

            if (((Get-Date) - $start).TotalMilliseconds -ge $TimeoutMs) {
                throw "Timed out acquiring lock for resource: $ResourcePath"
            }
        }
        catch [System.IO.IOException] {
            try {
                # Get-Item replaces the former Test-Path + Get-Item pair. Lock
                # contention is precisely where repeated network probes hurt
                # most.
                $lockItem = Get-Item -LiteralPath $lockPath -ErrorAction SilentlyContinue
                if ($null -ne $lockItem) {
                    $ageMs = ((Get-Date).ToUniversalTime() - $lockItem.LastWriteTimeUtc).TotalMilliseconds
                    if ($ageMs -gt $StaleLockMs) {
                        # Age alone cannot prove abandonment: a slow network
                        # write may legitimately hold the lock longer than the
                        # stale threshold. Only reclaim it after obtaining an
                        # exclusive probe handle, which fails while a live
                        # writer still owns the file.
                        $probeStream = $null
                        try {
                            $probeStream = [System.IO.File]::Open(
                                $lockPath,
                                [System.IO.FileMode]::Open,
                                [System.IO.FileAccess]::ReadWrite,
                                [System.IO.FileShare]::None
                            )
                        }
                        finally {
                            if ($null -ne $probeStream) {
                                $probeStream.Dispose()
                            }
                        }
                        Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            catch {
                # The existing lock is still held or another contender
                # completed the cleanup first.
            }

            if (((Get-Date) - $start).TotalMilliseconds -ge $TimeoutMs) {
                throw "Timed out acquiring lock for resource: $ResourcePath"
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Release-ResourceLock {
    param($LockHandle)

    if ($null -eq $LockHandle) { return }

    try {
        if ($LockHandle.Writer) { $LockHandle.Writer.Dispose() }
    }
    catch { }

    try {
        if ($LockHandle.Stream) { $LockHandle.Stream.Dispose() }
    }
    catch { }

    try {
        if ($LockHandle.Path) {
            # Remove-Item with SilentlyContinue is already safe if another
            # contender completed cleanup first; Test-Path was an extra SMB
            # round trip on every successful transaction.
            Remove-Item -LiteralPath $LockHandle.Path -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

function Write-TextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -Path $parent)) {
        New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null
    }

    $tempPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $tempNeedsCleanup = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, $utf8NoBom)

        try {
            # File.Replace itself establishes whether the destination exists.
            # Avoid a separate Test-Path before every commit.
            [System.IO.File]::Replace($tempPath, $Path, $null, $true)
        }
        catch {
            # New files and network filesystems without File.Replace support
            # use the same terminating fallback.
            Move-Item -Path $tempPath -Destination $Path -Force -ErrorAction Stop
        }

        $tempNeedsCleanup = $false
        Clear-CachedFileContent -Path $Path
    }
    finally {
        if ($tempNeedsCleanup) {
            # Only failed commits can still own the temporary path. Avoid both
            # an existence probe and a pointless delete on successful writes.
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 6
    )

    if ($Value -is [string]) {
        $json = [string]$Value
    }
    elseif ($null -eq $Value) {
        $json = "null"
    }
    else {
        # -InputObject preserves the collection itself. Piping a one-item
        # collection enumerates it first and incorrectly stores a JSON object
        # instead of a one-element JSON array.
        $json = ConvertTo-Json -InputObject $Value -Depth $Depth
        if ([string]::IsNullOrWhiteSpace([string]$json) -and ($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
            $json = "[]"
        }
    }

    Write-TextAtomic -Path $Path -Content $json
}

function Write-JsonArrayAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Items = @(),
        [int]$Depth = 6
    )

    # Function output and Where-Object pipelines unwrap zero/one-item
    # collections in PowerShell. Re-establish the storage contract here.
    Write-JsonAtomic -Path $Path -Value @($Items) -Depth $Depth
}

function Read-JsonArrayFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Read-TextFileCached already performs the metadata/existence lookup.
    # Repeating Test-Path here added another shared-drive operation.
    $raw = Read-TextFileCached -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "null") {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $parseError = $_.Exception
        throw (New-Object System.IO.InvalidDataException(
            ("Persistent JSON file is invalid and was left unchanged: {0}" -f $Path),
            $parseError
        ))
    }

    if ($null -eq $parsed) {
        return @()
    }

    if (-not ($parsed -is [System.Collections.IEnumerable]) -or ($parsed -is [string])) {
        return @($parsed)
    }
    return @($parsed)
}
