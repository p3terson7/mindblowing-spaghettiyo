$compensationGridModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.CompensationGrid.psd1"
Import-Module -Name $compensationGridModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name compensationGridModuleManifest -ErrorAction SilentlyContinue

function Clear-CompensationGridRuntimeCache {
    # FileStore owns the content and metadata caches. A compensation update is
    # immediately visible in this process, while SyncService propagates the
    # same invalidation to the other workstations.
    if (-not [string]::IsNullOrWhiteSpace([string]$compensationGridFile)) {
        Clear-CachedFileContent -Path $compensationGridFile
    }
    $script:CompensationGridRuntimeCache = $null
    $script:CompensationSalaryBandIndexCache = $null
    $script:CompensationGridSourceCache = $null
    $script:EmployeeMonetaryEntryCache = @{}
}

function Read-CompensationGridDocumentFromDisk {
    if ([string]::IsNullOrWhiteSpace([string]$compensationGridFile)) {
        throw "The shared compensation grid path is not configured."
    }

    $raw = Read-TextFileCached -Path $compensationGridFile
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        throw (New-Object System.IO.InvalidDataException("The shared compensation grid is empty."))
    }

    if ($script:CompensationGridRuntimeCache -and $script:CompensationGridRuntimeCache.Raw -ceq $raw) {
        return $script:CompensationGridRuntimeCache.Document
    }

    try {
        $document = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw (New-Object System.IO.InvalidDataException("The shared compensation grid is invalid JSON.", $_.Exception))
    }

    try {
        $normalized = Saphir.CompensationGrid\ConvertTo-CompensationSalaryGridDocument -Value $document
        $script:CompensationGridRuntimeCache = [PSCustomObject]@{ Raw = $raw; Document = $normalized }
        $script:CompensationSalaryBandIndexCache = $null
        return $normalized
    }
    catch {
        throw (New-Object System.IO.InvalidDataException("The shared compensation grid is invalid.", $_.Exception))
    }
}

function Get-CompensationGrid {
    return (Read-CompensationGridDocumentFromDisk)
}

function Get-CompensationGridCacheKey {
    # FileStore caches bytes/metadata. Hash only changed content, so coalesced
    # sync notifications can safely preserve estimates when the grid is intact.
    $raw = Read-TextFileCached -Path $compensationGridFile
    if ($script:CompensationGridSourceCache -and $script:CompensationGridSourceCache.Raw -ceq $raw) {
        return $script:CompensationGridSourceCache.Key
    }
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = [System.BitConverter]::ToString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$raw)))
    } finally { $hash.Dispose() }
    $script:CompensationGridSourceCache = [PSCustomObject]@{ Raw = $raw; Key = $key }
    return $key
}

function Get-CompensationSalaryBandIndex {
    param([Parameter(Mandatory = $true)]$SalaryGrid)

    if ($script:CompensationSalaryBandIndexCache -and [object]::ReferenceEquals($script:CompensationSalaryBandIndexCache.Document, $SalaryGrid)) {
        return $script:CompensationSalaryBandIndexCache.Index
    }
    $index = Saphir.CompensationGrid\New-CompensationSalaryBandIndex -SalaryGrid $SalaryGrid
    $script:CompensationSalaryBandIndexCache = [PSCustomObject]@{ Document = $SalaryGrid; Index = $index }
    return $index
}

function Set-CompensationGrid {
    param(
        [Parameter(Mandatory = $true)]$Bands
    )

    # The API accepts just the editable bands. Schema/currency stay owned by
    # the application so a browser cannot downgrade the document or switch a
    # salary grid to another currency accidentally.
    $candidate = [PSCustomObject][ordered]@{
        schemaVersion = 1
        currency      = "CAD"
        bands         = @($Bands)
    }
    $normalized = Saphir.CompensationGrid\ConvertTo-CompensationSalaryGridDocument -Value $candidate

    $lockHandle = Acquire-ResourceLock -ResourcePath $compensationGridFile
    try {
        Write-JsonAtomic -Path $compensationGridFile -Value $normalized -Depth 12
        Clear-CompensationGridRuntimeCache
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $normalized
}

function Resolve-CompensationBandForClassification {
    param(
        [AllowNull()][string]$Group,
        [AllowNull()][string]$SubGroup,
        [AllowNull()][string]$Level,
        [Parameter(Mandatory = $true)][DateTime]$AsOfDate
    )

    # The caller supplies the current classification from the shared employee
    # profile. Salary amounts remain in the editable grid.
    return (Saphir.CompensationGrid\Resolve-CompensationSalaryBand `
        -SalaryGrid (Get-CompensationGrid) `
        -Group $Group `
        -SubGroup $SubGroup `
        -Level $Level `
        -AsOfDate $AsOfDate)
}
