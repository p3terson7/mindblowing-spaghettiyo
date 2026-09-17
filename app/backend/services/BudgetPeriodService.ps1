$budgetPeriodsModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.BudgetPeriods.psd1"
Import-Module -Name $budgetPeriodsModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name budgetPeriodsModuleManifest -ErrorAction SilentlyContinue

function Clear-BudgetPeriodRuntimeCache {
    if (-not [string]::IsNullOrWhiteSpace([string]$budgetPeriodsFile)) {
        Clear-CachedFileContent -Path $budgetPeriodsFile
    }
}

function Get-BudgetPeriodConfiguration {
    $raw = Read-TextFileCached -Path $budgetPeriodsFile
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        throw (New-Object System.IO.InvalidDataException("The shared budget-period configuration is empty."))
    }

    try {
        $document = $raw | ConvertFrom-Json -ErrorAction Stop
        return (Saphir.BudgetPeriods\ConvertTo-SaphirBudgetPeriodConfiguration -Value $document)
    }
    catch {
        throw (New-Object System.IO.InvalidDataException("The shared budget-period configuration is invalid.", $_.Exception))
    }
}

function Set-BudgetPeriodConfiguration {
    param(
        [AllowNull()][string]$CycleLabel,
        [Parameter(Mandatory = $true)]$Periods
    )

    $candidate = [PSCustomObject][ordered]@{
        schemaVersion = 1
        cycleLabel    = [string]$CycleLabel
        periods       = @($Periods)
    }
    $normalized = Saphir.BudgetPeriods\ConvertTo-SaphirBudgetPeriodConfiguration -Value $candidate

    $lockHandle = Acquire-ResourceLock -ResourcePath $budgetPeriodsFile
    try {
        $stored = [PSCustomObject][ordered]@{
            schemaVersion = [int]$normalized.schemaVersion
            cycleLabel    = [string]$normalized.cycleLabel
            periods       = @($normalized.periods | ForEach-Object {
                [PSCustomObject][ordered]@{
                    id        = [string]$_.id
                    startDate = [string]$_.startDate
                    endDate   = [string]$_.endDate
                }
            })
        }
        Write-JsonAtomic -Path $budgetPeriodsFile -Value $stored -Depth 8
        Clear-BudgetPeriodRuntimeCache
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $normalized
}
