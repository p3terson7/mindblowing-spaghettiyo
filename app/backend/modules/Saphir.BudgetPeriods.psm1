function Get-BudgetPeriodObjectPropertyValue {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ([string]$key -ieq $Name) {
                return $Value[$key]
            }
        }
    }

    foreach ($property in @($Value.PSObject.Properties)) {
        if ([string]$property.Name -ieq $Name) {
            return $property.Value
        }
    }

    return $null
}

function Get-SaphirBudgetPeriodIds {
    return @("P1", "P2", "P3", "P4")
}

function ConvertTo-BudgetPeriodDate {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    $parsed = [DateTime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::None
    if (-not [DateTime]::TryParseExact($text, "yyyy-MM-dd", $culture, $styles, [ref]$parsed)) {
        throw [System.ArgumentException]::new(("{0} must use YYYY-MM-DD." -f $FieldName))
    }

    return $parsed.ToString("yyyy-MM-dd", $culture)
}

function ConvertTo-SaphirBudgetPeriodConfiguration {
    param([Parameter(Mandatory = $true)]$Value)

    $schemaVersion = ([string](Get-BudgetPeriodObjectPropertyValue -Value $Value -Name "schemaVersion")).Trim()
    if ($schemaVersion -ne "1") {
        throw [System.ArgumentException]::new("Budget-period schemaVersion must be 1.")
    }

    $cycleLabel = ([string](Get-BudgetPeriodObjectPropertyValue -Value $Value -Name "cycleLabel")).Trim()
    if ($cycleLabel.Length -gt 80) {
        throw [System.ArgumentException]::new("Budget cycle label cannot exceed 80 characters.")
    }

    $periodsRaw = Get-BudgetPeriodObjectPropertyValue -Value $Value -Name "periods"
    if ($null -eq $periodsRaw -or $periodsRaw -is [string] -or -not ($periodsRaw -is [System.Collections.IEnumerable])) {
        throw [System.ArgumentException]::new("Budget periods must be an array.")
    }

    $periodsById = @{}
    foreach ($periodValue in @($periodsRaw)) {
        $periodId = ([string](Get-BudgetPeriodObjectPropertyValue -Value $periodValue -Name "id")).Trim().ToUpperInvariant()
        if (-not (Get-SaphirBudgetPeriodIds | Where-Object { $_ -eq $periodId })) {
            throw [System.ArgumentException]::new(("Unsupported budget period '{0}'." -f $periodId))
        }
        if ($periodsById.ContainsKey($periodId)) {
            throw [System.ArgumentException]::new(("Budget period '{0}' is duplicated." -f $periodId))
        }

        $startDate = ConvertTo-BudgetPeriodDate -Value (Get-BudgetPeriodObjectPropertyValue -Value $periodValue -Name "startDate") -FieldName ("{0} startDate" -f $periodId)
        $endDate = ConvertTo-BudgetPeriodDate -Value (Get-BudgetPeriodObjectPropertyValue -Value $periodValue -Name "endDate") -FieldName ("{0} endDate" -f $periodId)
        if ([string]::IsNullOrWhiteSpace($startDate) -xor [string]::IsNullOrWhiteSpace($endDate)) {
            throw [System.ArgumentException]::new(("Budget period {0} requires both a start and end date." -f $periodId))
        }
        if ($startDate -and $endDate -and $endDate -lt $startDate) {
            throw [System.ArgumentException]::new(("Budget period {0} cannot end before it starts." -f $periodId))
        }

        $periodsById[$periodId] = [PSCustomObject][ordered]@{
            id        = $periodId
            startDate = $startDate
            endDate   = $endDate
            configured = [bool]($startDate -and $endDate)
        }
    }

    $normalizedPeriods = New-Object System.Collections.ArrayList
    foreach ($periodId in @(Get-SaphirBudgetPeriodIds)) {
        if (-not $periodsById.ContainsKey($periodId)) {
            throw [System.ArgumentException]::new(("Budget period {0} is required." -f $periodId))
        }
        [void]$normalizedPeriods.Add($periodsById[$periodId])
    }

    $configuredPeriods = @($normalizedPeriods.ToArray() | Where-Object { $_.configured })
    for ($index = 1; $index -lt $configuredPeriods.Count; $index++) {
        $previous = $configuredPeriods[$index - 1]
        $current = $configuredPeriods[$index]
        if ([string]$current.startDate -le [string]$previous.endDate) {
            throw [System.ArgumentException]::new(("Budget period {0} must start after {1} ends." -f [string]$current.id, [string]$previous.id))
        }
    }

    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        cycleLabel    = $cycleLabel
        periods       = @($normalizedPeriods.ToArray())
    }
}

function Get-SaphirConfiguredBudgetPeriods {
    param([Parameter(Mandatory = $true)]$Configuration)

    $normalized = ConvertTo-SaphirBudgetPeriodConfiguration -Value $Configuration
    return @($normalized.periods | Where-Object { $_.configured })
}

Export-ModuleMember -Function @(
    "Get-SaphirBudgetPeriodIds",
    "ConvertTo-SaphirBudgetPeriodConfiguration",
    "Get-SaphirConfiguredBudgetPeriods"
)
