param([switch]$Isolated)
$ErrorActionPreference = "Stop"
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw "Cold metadata subprocess failed." }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("cold-metadata-" + [Guid]::NewGuid().ToString("N"))
function Assert-Metadata($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $fixture -Create -EmployeeCount 12
    $paths = @(1..12 | ForEach-Object { Join-Path $fixture ("{0:000000000}_data.json" -f (710000 + $_)) })
    $script:FileMetadataCache = @{}
    $script:Enumerations = 0
    $originalEnumeration = ${function:Get-SaphirChildFilesWithRetry}
    function Get-SaphirChildFilesWithRetry { param($Path, $Filter) $script:Enumerations++; & $originalEnumeration -Path $Path -Filter $Filter }
    Prime-EmployeeFileMetadata -Paths $paths
    Assert-Metadata ($script:Enumerations -eq 1 -and $script:FileMetadataCache.Count -eq 12) "Cold metadata was not batched once."
    foreach ($path in $paths) {
        $metadata = Get-FileMetadataSnapshot $path
        Assert-Metadata ($metadata.Length -eq ([IO.FileInfo]::new($path)).Length -and $metadata.ObservedAtUtc) "Batched stamp differs from actual file metadata."
    }
    $observed = $script:FileMetadataCache[$paths[0]].Metadata.ObservedAtUtc
    Prime-EmployeeFileMetadata -Paths $paths
    Assert-Metadata ($script:Enumerations -eq 1 -and $script:FileMetadataCache[$paths[0]].Metadata.ObservedAtUtc -eq $observed) "Warm stamps were extended/re-enumerated."
    Clear-CachedFileContent $paths[0]
    Prime-EmployeeFileMetadata -Paths @($paths[0])
    Assert-Metadata ($script:Enumerations -eq 1) "Single employee change enumerated the entire folder."

    # Missing files are not inferred from a possibly stale directory listing.
    [IO.File]::Move($paths[0], ($paths[0] + ".saved"))
    $script:FileMetadataCache = @{}
    Prime-EmployeeFileMetadata -Paths $paths
    Assert-Metadata (-not $script:FileMetadataCache.ContainsKey($paths[0]) -and $null -eq (Get-FileMetadataSnapshot $paths[0])) "Listing cached an unconfirmed missing file."
    [IO.File]::Move(($paths[0] + ".saved"), $paths[0])
    $script:FileMetadataCache = @{}
    Prime-EmployeeFileMetadata -Paths $paths

    # A loaded source younger than its original 30s boundary need not be probed
    # again by global reconciliation. Failed probes must not extend this proof.
    $manager = Get-UserByUsername "audit-super"
    Get-DashboardBootstrapModel -CurrentUser $manager | Out-Null
    $script:OriginalMetadataProbe = ${function:Get-FileItemWithRetry}
    $script:EmployeeProbes = 0
    function Get-FileItemWithRetry { param($Path) if ($Path -like "*_data.json") { $script:EmployeeProbes++ }; & $script:OriginalMetadataProbe -Path $Path }
    $script:ReadModelReconciledUtc = [DateTime]::UtcNow.AddMinutes(-1)
    Invoke-ReadModelSourceReconciliation
    Assert-Metadata ($script:EmployeeProbes -eq 0) "Reconciliation redundantly probed recently observed employee metadata."
    $entry = $script:FileMetadataCache[$paths[0]]
    $entry.Metadata.ObservedAtUtc = [DateTime]::UtcNow.AddMinutes(-1)
    $entry.ValidatedAtUtc = [DateTime]::UtcNow
    $script:ReadModelReconciledUtc = [DateTime]::UtcNow.AddMinutes(-1)
    Invoke-ReadModelSourceReconciliation
    Assert-Metadata ($script:EmployeeProbes -eq 1) "Renewed fallback TTL suppressed a necessary successful probe."
    Assert-Metadata ($script:FileMetadataCache[$paths[0]].Metadata.ObservedAtUtc -gt $observed) "Reconciliation did not transfer its successful observation to FileStore."
    Write-Host "Cold metadata passed: bounded scan, real stamps, no warm renewal, single-change fast path, missing-file fallback, successful-observation boundary and reuse."
} finally { if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
