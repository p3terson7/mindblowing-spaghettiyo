if (-not $script:TextFileCache) {
    $script:TextFileCache = @{}
}

if (-not $script:BinaryFileCache) {
    $script:BinaryFileCache = @{}
}

function Get-FileMetadataSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $null
    }

    $item = Get-Item -Path $Path
    return [PSCustomObject]@{
        Path           = $item.FullName
        LastWriteUtc   = $item.LastWriteTimeUtc
        LastWriteTicks = $item.LastWriteTimeUtc.Ticks
        Length         = $item.Length
    }
}

function Clear-CachedFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:TextFileCache.ContainsKey($Path)) {
        $script:TextFileCache.Remove($Path) | Out-Null
    }

    if ($script:BinaryFileCache.ContainsKey($Path)) {
        $script:BinaryFileCache.Remove($Path) | Out-Null
    }
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

    if (-not (Test-Path -Path $lockFolder)) {
        New-Item -ItemType Directory -Path $lockFolder -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $normalized = $ResourcePath.ToLowerInvariant()
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

            return [PSCustomObject]@{
                Path   = $lockPath
                Stream = $stream
                Writer = $writer
            }
        }
        catch [System.IO.IOException] {
            if (Test-Path -Path $lockPath) {
                try {
                    $ageMs = ((Get-Date).ToUniversalTime() - (Get-Item -Path $lockPath).LastWriteTimeUtc).TotalMilliseconds
                    if ($ageMs -gt $StaleLockMs) {
                        Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    # Ignore lock cleanup race conditions.
                }
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
        if ($LockHandle.Path -and (Test-Path -Path $LockHandle.Path)) {
            Remove-Item -Path $LockHandle.Path -Force -ErrorAction SilentlyContinue
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
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    $tempPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, $Content, $utf8NoBom)

    if (Test-Path -Path $Path) {
        try {
            [System.IO.File]::Replace($tempPath, $Path, $null, $true)
        }
        catch {
            Move-Item -Path $tempPath -Destination $Path -Force
        }
    }
    else {
        Move-Item -Path $tempPath -Destination $Path -Force
    }

    Clear-CachedFileContent -Path $Path
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
        $json = $Value | ConvertTo-Json -Depth $Depth
        if ([string]::IsNullOrWhiteSpace([string]$json) -and ($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
            $json = "[]"
        }
    }

    Write-TextAtomic -Path $Path -Content $json
}

function Read-JsonArrayFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) { return @() }

    $raw = Get-Content -Path $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "null") {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        return @()
    }

    if ($null -eq $parsed) {
        return @()
    }

    if (-not ($parsed -is [System.Collections.IEnumerable]) -or ($parsed -is [string])) {
        return @($parsed)
    }
    return @($parsed)
}
