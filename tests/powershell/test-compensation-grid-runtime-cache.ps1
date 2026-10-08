$ErrorActionPreference = "Stop"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("saphir-grid-cache-{0}" -f [Guid]::NewGuid().ToString("N"))
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    . (Join-Path $repoRoot "app/backend/lib/FileStore.ps1")
    . (Join-Path $repoRoot "app/backend/services/CompensationGridService.ps1")
    $script:compensationGridFile = Join-Path $fixtureRoot "grid.json"
    $raw = Get-Content (Join-Path $repoRoot "app/backend/defaults/compensation-grid.v1.json") -Raw
    [System.IO.File]::WriteAllText($script:compensationGridFile, $raw)
    $first = Get-CompensationGrid
    $again = Get-CompensationGrid
    Assert-True ([object]::ReferenceEquals($first, $again)) "Unchanged grid content must reuse its validated document."
    $firstIndex = Get-CompensationSalaryBandIndex -SalaryGrid $first
    $againIndex = Get-CompensationSalaryBandIndex -SalaryGrid $again
    Assert-True ([object]::ReferenceEquals($firstIndex, $againIndex)) "Unchanged salary grids must reuse their index."
    $firstKey = Get-CompensationGridCacheKey
    $external = $raw | ConvertFrom-Json
    $external.bands[0].annualSalaryCents += 10000
    [System.IO.File]::WriteAllText($script:compensationGridFile, ($external | ConvertTo-Json -Depth 12))
    Clear-CachedFileContent -Path $script:compensationGridFile
    $newKey = Get-CompensationGridCacheKey
    Assert-True ($firstKey -cne $newKey) "The source key must detect grid changes after a coalesced file-cache invalidation."
    $updated = Get-CompensationGrid
    $updatedIndex = Get-CompensationSalaryBandIndex -SalaryGrid $updated
    Assert-True (-not [object]::ReferenceEquals($firstIndex, $updatedIndex)) "A modified grid must invalidate its salary index."
    $band = $external.bands[0]
    $resolved = Saphir.CompensationGrid\Resolve-CompensationSalaryBand -SalaryBandIndex $updatedIndex -Group $band.group -SubGroup $band.subGroup -Level $band.level -AsOfDate ([DateTime]$band.effectiveFrom)
    Assert-True ($resolved.annualSalaryCents -eq $band.annualSalaryCents) "The refreshed index returned the old salary."
    $script:EmployeeMonetaryEntryCache = @{ synthetic = $true }
    Clear-CompensationGridRuntimeCache
    Assert-True ($script:EmployeeMonetaryEntryCache.Count -eq 0) "A grid save must immediately invalidate derived amounts."
    Assert-True ($null -eq $script:CompensationGridRuntimeCache -and $null -eq $script:CompensationSalaryBandIndexCache -and $null -eq $script:CompensationGridSourceCache) "Explicit grid invalidation left a stale runtime dependency."
    Write-Host "Compensation-grid runtime cache passed: validated documents, index reuse, content keys and exact updated rates."
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
