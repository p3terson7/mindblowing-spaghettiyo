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

if (-not $script:SharedDataReadRetryCount) {
    $script:SharedDataReadRetryCount = 3
}

if (-not $script:SharedDataRetryDelayMs) {
    $script:SharedDataRetryDelayMs = 75
}

function New-SharedDataUnavailableException {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Path,
        $InnerException = $null
    )

    $detail = if ($null -ne $InnerException -and -not [string]::IsNullOrWhiteSpace([string]$InnerException.Message)) {
        ": " + [string]$InnerException.Message
    }
    else {
        ""
    }
    $message = "Shared data operation '$Operation' failed for '$Path'$detail"
    $exception = if ($null -ne $InnerException) {
        New-Object System.IO.IOException($message, $InnerException)
    }
    else {
        New-Object System.IO.IOException($message)
    }
    $exception.Data["SaphirHttpStatusCode"] = 503
    $exception.Data["SaphirSharedDataOperation"] = $Operation
    return $exception
}

function Test-PathNotFoundError {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return $false
    }

    $exception = $ErrorRecord.Exception
    if ($exception -is [System.IO.FileNotFoundException] -or
        $exception -is [System.IO.DirectoryNotFoundException] -or
        $exception -is [System.Management.Automation.ItemNotFoundException]) {
        return $true
    }

    return ($null -ne $ErrorRecord.CategoryInfo -and
        [string]$ErrorRecord.CategoryInfo.Category -eq "ObjectNotFound")
}

function Start-SharedDataRetryDelay {
    param([int]$Attempt)

    $multiplier = [Math]::Max(1, $Attempt)
    Start-Sleep -Milliseconds ($script:SharedDataRetryDelayMs * $multiplier)
}

function Get-FileItemWithRetry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lastError = $null
    for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
        try {
            return (Get-Item -LiteralPath $Path -ErrorAction Stop)
        }
        catch {
            $lastError = $_
            if (Test-PathNotFoundError -ErrorRecord $_) {
                # A missing target is trustworthy only when its parent remains
                # reachable. On SMB, an unavailable share is often surfaced as
                # PathNotFound even though the business file still exists.
                $parentPath = Split-Path -Path $Path -Parent
                try {
                    $parentItem = Get-Item -LiteralPath $parentPath -ErrorAction Stop
                    if ($null -ne $parentItem -and [bool]$parentItem.PSIsContainer) {
                        if ($attempt -lt $script:SharedDataReadRetryCount) {
                            Start-SharedDataRetryDelay -Attempt $attempt
                            continue
                        }
                        return $null
                    }
                }
                catch {
                    $lastError = $_
                }
            }

            if ($attempt -lt $script:SharedDataReadRetryCount) {
                Start-SharedDataRetryDelay -Attempt $attempt
                continue
            }
        }
    }

    throw (New-SharedDataUnavailableException -Operation "read metadata" -Path $Path -InnerException $lastError.Exception)
}

function Test-SaphirFileExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-FileItemWithRetry -Path $Path
    return ($null -ne $item -and -not [bool]$item.PSIsContainer)
}

function Test-SaphirDirectoryExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-FileItemWithRetry -Path $Path
    return ($null -ne $item -and [bool]$item.PSIsContainer)
}

function Get-SaphirChildFilesWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Filter
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
        try {
            return @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -ErrorAction Stop)
        }
        catch {
            $lastError = $_
            if ($attempt -lt $script:SharedDataReadRetryCount) {
                Start-SharedDataRetryDelay -Attempt $attempt
            }
        }
    }

    throw (New-SharedDataUnavailableException -Operation "enumerate folder" -Path $Path -InnerException $lastError.Exception)
}

function Read-TextFileWithRetry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lastError = $null
    for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
        try {
            return [System.IO.File]::ReadAllText($Path)
        }
        catch {
            $lastError = $_
            if ($attempt -lt $script:SharedDataReadRetryCount) {
                Start-SharedDataRetryDelay -Attempt $attempt
            }
        }
    }

    throw (New-SharedDataUnavailableException -Operation "read file" -Path $Path -InnerException $lastError.Exception)
}

function Read-FileBytesWithRetry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lastError = $null
    for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
        try {
            return [System.IO.File]::ReadAllBytes($Path)
        }
        catch {
            $lastError = $_
            if ($attempt -lt $script:SharedDataReadRetryCount) {
                Start-SharedDataRetryDelay -Attempt $attempt
            }
        }
    }

    throw (New-SharedDataUnavailableException -Operation "read file" -Path $Path -InnerException $lastError.Exception)
}

function Rethrow-SaphirHttpStatusException {
    param($Exception)

    if ($null -ne $Exception -and
        $null -ne $Exception.Data -and
        $Exception.Data.Contains("SaphirHttpStatusCode")) {
        throw $Exception
    }
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

    # A failed SMB probe must never be cached as a missing file. The retrying
    # lookup confirms that the parent is reachable before returning null.
    $item = Get-FileItemWithRetry -Path $Path
    if ($null -eq $item -or [bool]$item.PSIsContainer) {
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

    $lastError = $null
    for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
        $metadata = Get-FileMetadataSnapshot -Path $Path
        if ($null -eq $metadata) {
            return $null
        }

        $cacheEntry = $script:TextFileCache[$Path]
        if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
            return [string]$cacheEntry.Content
        }

        try {
            $content = Read-TextFileWithRetry -Path $Path
            $script:TextFileCache[$Path] = [PSCustomObject]@{
                LastWriteTicks = $metadata.LastWriteTicks
                Length         = $metadata.Length
                Content        = $content
            }
            return $content
        }
        catch {
            $lastError = $_
            Clear-CachedFileContent -Path $Path
            if ($attempt -lt $script:SharedDataReadRetryCount) {
                Start-SharedDataRetryDelay -Attempt $attempt
            }
        }
    }

    throw (New-SharedDataUnavailableException -Operation "read file" -Path $Path -InnerException $lastError.Exception)
}

function Read-FileBytesCached {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lastError = $null
    for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
        $metadata = Get-FileMetadataSnapshot -Path $Path
        if ($null -eq $metadata) {
            return $null
        }

        $cacheEntry = $script:BinaryFileCache[$Path]
        if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
            return $cacheEntry.Bytes
        }

        try {
            $bytes = Read-FileBytesWithRetry -Path $Path
            $script:BinaryFileCache[$Path] = [PSCustomObject]@{
                LastWriteTicks = $metadata.LastWriteTicks
                Length         = $metadata.Length
                Bytes          = $bytes
            }
            return $bytes
        }
        catch {
            $lastError = $_
            Clear-CachedFileContent -Path $Path
            if ($attempt -lt $script:SharedDataReadRetryCount) {
                Start-SharedDataRetryDelay -Attempt $attempt
            }
        }
    }

    throw (New-SharedDataUnavailableException -Operation "read file" -Path $Path -InnerException $lastError.Exception)
}

function Get-LockFilePath {
    param([Parameter(Mandatory = $true)][string]$ResourcePath)

    # The lock directory is stable for the process lifetime. Preparing it once
    # removes an existence probe from every write transaction. Acquire retries
    # preparation if an administrator removes it while the server is running.
    if ([string]$script:PreparedLockFolderPath -ne [string]$lockFolder) {
        try {
            [System.IO.Directory]::CreateDirectory($lockFolder) | Out-Null
            $script:PreparedLockFolderPath = [string]$lockFolder
        }
        catch {
            throw (New-SharedDataUnavailableException -Operation "prepare resource lock folder" -Path $ResourcePath -InnerException $_.Exception)
        }
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

function Test-AndRemoveOrphanedResourceLock {
    param([Parameter(Mandatory = $true)][string]$LockPath)

    $probeStream = $null
    try {
        # A live owner holds FileShare.None, so this succeeds only for a file
        # left behind by an older process. DeleteOnClose makes reclamation and
        # handle release one atomic filesystem operation: there is no gap in
        # which another process can create a replacement that we then delete.
        $probeStream = [System.IO.FileStream]::new(
            $LockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::DeleteOnClose
        )
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $probeStream) {
            $probeStream.Dispose()
        }
    }

    # DeleteOnClose is expected to remove the path as the probe closes. If a
    # filesystem delays or rejects that cleanup, let the caller use its normal
    # bounded wait rather than spinning forever on the same orphan.
    return (-not [System.IO.File]::Exists($LockPath))
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
            $stream = $null
            $writer = $null
            try {
                $stream = [System.IO.FileStream]::new(
                    $lockPath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None,
                    4096,
                    # The OS removes the directory entry as it closes this exact
                    # ownership handle. An old owner can therefore never delete a
                    # lock file created by the next contender.
                    [System.IO.FileOptions]::DeleteOnClose
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
            catch {
                # DeleteOnClose only runs when its stream is disposed. Do not
                # strand the lock if owner metadata or cache setup fails.
                try {
                    if ($null -ne $writer) { $writer.Dispose() }
                }
                catch { }
                try {
                    if ($null -ne $stream) { $stream.Dispose() }
                }
                catch { }
                throw
            }
        }
        catch [System.IO.DirectoryNotFoundException] {
            $script:PreparedLockFolderPath = ""
            try {
                [System.IO.Directory]::CreateDirectory($lockFolder) | Out-Null
                $script:PreparedLockFolderPath = [string]$lockFolder
            }
            catch {
                if (((Get-Date) - $start).TotalMilliseconds -ge $TimeoutMs) {
                    throw (New-SharedDataUnavailableException -Operation "prepare resource lock" -Path $ResourcePath -InnerException $_.Exception)
                }
            }

            if (((Get-Date) - $start).TotalMilliseconds -ge $TimeoutMs) {
                throw (New-SharedDataUnavailableException -Operation "acquire resource lock" -Path $ResourcePath)
            }
            Start-Sleep -Milliseconds 100
        }
        catch [System.IO.IOException] {
            # Do not wait for an age threshold. Exclusive open is definitive:
            # it fails while a live owner holds FileShare.None and succeeds for
            # an orphan whose cleanup was interrupted by SMB.
            if (Test-AndRemoveOrphanedResourceLock -LockPath $lockPath) {
                continue
            }

            if (((Get-Date) - $start).TotalMilliseconds -ge $TimeoutMs) {
                throw (New-SharedDataUnavailableException -Operation "acquire resource lock" -Path $ResourcePath -InnerException $_.Exception)
            }
            Start-Sleep -Milliseconds 100
        }
        catch {
            if (((Get-Date) - $start).TotalMilliseconds -ge $TimeoutMs) {
                throw (New-SharedDataUnavailableException -Operation "acquire resource lock" -Path $ResourcePath -InnerException $_.Exception)
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Release-ResourceLock {
    param($LockHandle)

    if ($null -eq $LockHandle) { return }

    try {
        # The writer owns the FileStream. Disposing it closes the exact handle
        # whose DeleteOnClose flag atomically removes the lock path.
        if ($LockHandle.Writer) { $LockHandle.Writer.Dispose() }
    }
    catch { }

    try {
        if ($LockHandle.Stream) { $LockHandle.Stream.Dispose() }
    }
    catch { }
}

function Write-TextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        try {
            # CreateDirectory is idempotent and avoids treating a transient
            # Test-Path false as proof that the shared folder is absent.
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        catch {
            throw (New-SharedDataUnavailableException -Operation "prepare write folder" -Path $Path -InnerException $_.Exception)
        }
    }

    $tempPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $tempNeedsCleanup = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        $tempWritten = $false
        $lastTempWriteError = $null
        for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
            try {
                [System.IO.File]::WriteAllText($tempPath, $Content, $utf8NoBom)
                $tempWritten = $true
                break
            }
            catch {
                $lastTempWriteError = $_
                if ($attempt -lt $script:SharedDataReadRetryCount) {
                    Start-SharedDataRetryDelay -Attempt $attempt
                }
            }
        }
        if (-not $tempWritten) {
            throw (New-SharedDataUnavailableException -Operation "write temporary file" -Path $Path -InnerException $lastTempWriteError.Exception)
        }

        try {
            # File.Replace itself establishes whether the destination exists.
            # Avoid a separate Test-Path before every commit.
            [System.IO.File]::Replace($tempPath, $Path, $null, $true)
        }
        catch {
            # New files and network filesystems without File.Replace support
            # use the same terminating fallback.
            try {
                Move-Item -Path $tempPath -Destination $Path -Force -ErrorAction Stop
            }
            catch {
                $commitError = $_
                $destinationMatches = $false
                try {
                    # A network client can receive an error after the server
                    # committed the rename. Verify that ambiguous outcome
                    # instead of repeating a non-idempotent destination write.
                    $destinationMatches = [System.IO.File]::ReadAllText($Path) -eq $Content
                }
                catch {
                    $destinationMatches = $false
                }

                if (-not $destinationMatches) {
                    throw (New-SharedDataUnavailableException -Operation "commit file" -Path $Path -InnerException $commitError.Exception)
                }
            }
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
