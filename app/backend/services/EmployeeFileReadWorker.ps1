param([string]$Path, [string]$DataRoot, [string]$BackendRoot, $Metadata, [DateTime]$ValidatedAtUtc, [int]$RetryCount, [int]$RetryDelayMs, [bool]$Tracing)
$ErrorActionPreference = "Stop"
if (-not (Test-Path Function:\Read-TextFileCached)) {
    . (Join-Path $BackendRoot "lib/PerformanceTrace.ps1")
    $script:SaphirPerformanceEnabled = $Tracing
    . (Join-Path $BackendRoot "lib/FileStore.ps1")
}
# This runspace receives only path/scalar metadata, never users, permissions,
# normalized entries, parent hashtables, cache frames, or dependency registries.
$script:sharedFolder = $DataRoot
$script:SharedDataReadRetryCount = $RetryCount
$script:SharedDataRetryDelayMs = $RetryDelayMs
$script:TextFileCache = @{}; $script:BinaryFileCache = @{}; $script:FileMetadataCache = @{}
$script:HeldResourceLocks = @{}
if ($null -ne $Metadata) {
    $script:FileMetadataCache[$Path] = [PSCustomObject]@{ Metadata = $Metadata; ValidatedAtUtc = $ValidatedAtUtc }
}
$script:SaphirPerformanceRecord = if ($Tracing) { @{ operations = @{}; resources = @{}; functions = @{}; stack = (New-Object Collections.ArrayList) } } else { $null }
$failure = $null; $content = $null
try { $content = Read-TextFileCached -Path $Path }
catch { $failure = $_.Exception }
$entry = $script:FileMetadataCache[$Path]
return [PSCustomObject]@{
    path = $Path; content = $content; failure = $failure
    metadata = if ($entry) { $entry.Metadata } else { $null }
    validatedAtUtc = if ($entry) { $entry.ValidatedAtUtc } else { [DateTime]::MinValue }
    metrics = $script:SaphirPerformanceRecord
}
