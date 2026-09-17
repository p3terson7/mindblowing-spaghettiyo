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
}

function Read-CompensationGridDocumentFromDisk {
    if ([string]::IsNullOrWhiteSpace([string]$compensationGridFile)) {
        throw "The shared compensation grid path is not configured."
    }

    $raw = Read-TextFileCached -Path $compensationGridFile
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        throw (New-Object System.IO.InvalidDataException("The shared compensation grid is empty."))
    }

    try {
        $document = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw (New-Object System.IO.InvalidDataException("The shared compensation grid is invalid JSON.", $_.Exception))
    }

    try {
        return (Saphir.CompensationGrid\ConvertTo-CompensationSalaryGridDocument -Value $document)
    }
    catch {
        throw (New-Object System.IO.InvalidDataException("The shared compensation grid is invalid.", $_.Exception))
    }
}

function Get-CompensationGrid {
    return (Read-CompensationGridDocumentFromDisk)
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

    # This is intentionally not wired into time-entry calculations yet. The
    # annual-hours divisor and overtime multipliers have not been approved.
    # Callers must supply a trusted compensation classification rather than a
    # self-editable GC179 export profile.
    return (Saphir.CompensationGrid\Resolve-CompensationSalaryBand `
        -SalaryGrid (Get-CompensationGrid) `
        -Group $Group `
        -SubGroup $SubGroup `
        -Level $Level `
        -AsOfDate $AsOfDate)
}
