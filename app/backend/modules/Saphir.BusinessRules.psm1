function Get-SaphirBusinessRuleContract {
    <#
        This contract intentionally contains shapes and allowed values only.
        Budget dates and compensation formulas remain administrator-managed
        business data and must never be hard-coded in the application.
    #>
    return [PSCustomObject]@{
        contractVersion = 1
        entryTypes = @("overtime", "diverse")
        workSchedules = @("regular", "compressed", "unconfirmed")
        classification = [PSCustomObject]@{
            groupPattern = "^[A-Z]+$"
            subGroupPattern = "^[0-9]{2}$"
            levelPattern = "^[0-9]{2}$"
        }
        budgetPeriodIds = @("P1", "P2", "P3", "P4")
    }
}

function ConvertTo-SaphirEntryType {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [ValidateSet("overtime", "diverse")][string]$DefaultValue = "overtime"
    )

    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    if (@("overtime", "diverse") -contains $normalized) {
        return $normalized
    }

    return $DefaultValue
}

function ConvertTo-SaphirWorkSchedule {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [ValidateSet("regular", "compressed", "unconfirmed")][string]$DefaultValue = "unconfirmed"
    )

    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    switch ($normalized) {
        "regular" { return "regular" }
        "standard" { return "regular" }
        "compressed" { return "compressed" }
        "unconfirmed" { return "unconfirmed" }
        default { return $DefaultValue }
    }
}

function Test-SaphirClassificationGroup {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    return ([string]$Value).Trim().ToUpperInvariant() -match "^[A-Z]+$"
}

function Test-SaphirClassificationOrdinal {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    return ([string]$Value).Trim() -match "^[0-9]{2}$"
}

Export-ModuleMember -Function @(
    "Get-SaphirBusinessRuleContract",
    "ConvertTo-SaphirEntryType",
    "ConvertTo-SaphirWorkSchedule",
    "Test-SaphirClassificationGroup",
    "Test-SaphirClassificationOrdinal"
)
