function Get-SaphirOvertimeRateCatalog {
    <#
        Central, versioned source for overtime multipliers used by exports and
        future monetary analytics. Annual salaries are intentionally excluded:
        they remain administrator-managed in the compensation grid.
    #>
    return [PSCustomObject]@{
        schemaVersion = 1
        agreement     = "PA"
        thresholdHours = [decimal]7.5
        multipliers   = [PSCustomObject]@{
            timeAndHalf         = [decimal]1.5
            timeAndThreeQuarter = [decimal]1.75
            doubleTime          = [decimal]2.0
        }
        overtimeCodes = @(
            [PSCustomObject]@{ code = "260"; category = "regular"; label = "Regular Workday" },
            [PSCustomObject]@{ code = "261"; category = "first-day-rest"; label = "First Day of Rest" },
            [PSCustomObject]@{ code = "262"; category = "subsequent-day-rest"; label = "Second/Subsequent Day of Rest" },
            [PSCustomObject]@{ code = "263"; category = "holiday"; label = "Designated Paid Holiday" }
        )
    }
}

function Get-SaphirOvertimeMonetaryContract {
    <#
        Monetary results produced by this module are decision-support estimates,
        not payroll statements. Salary values remain administrator-managed, while
        the annual-to-hourly conversion and overtime multipliers are versioned
        business rules from the PA agreement.
    #>
    return [PSCustomObject][ordered]@{
        schemaVersion          = 1
        calculationVersion     = "PA-MONETARY-v1"
        agreement              = "PA"
        currency               = "CAD"
        resultStatus           = "estimated"
        costBasis              = "salary-only"
        includesEmployerCosts  = $false
        weeksPerYear           = [decimal]52.176
        standardHoursPerWeek   = [decimal]37.5
        annualHoursDivisor     = [decimal]1956.6
        creditedMinuteInterval = 15
        rounding               = [PSCustomObject][ordered]@{
            precision         = "cent"
            midpoint          = "away-from-zero"
            scope             = "entry-total"
            segmentAllocation = "final-segment-adjustment"
        }
        paymentOptions         = @("cash", "leave")
        source                 = "Treasury Board of Canada Secretariat, PA collective agreement"
        sourceUrl              = "https://www.tbs-sct.canada.ca/agreements-conventions/download-fra.aspx?id=56"
    }
}

function Get-SaphirOvertimeCategory {
    param([AllowNull()][AllowEmptyString()][string]$OvertimeCode)

    switch (([string]$OvertimeCode).Trim()) {
        "261" { return "first-day-rest" }
        "262" { return "subsequent-day-rest" }
        "263" { return "holiday" }
        # 260 is the canonical regular-workday code. Travel on a regular
        # workday (089) and legacy/unknown codes retain the regular category.
        default { return "regular" }
    }
}

function Get-SaphirOvertimeRatePlan {
    param(
        [AllowNull()][AllowEmptyString()][string]$OvertimeCode,
        [Parameter(Mandatory = $true)][ValidateSet("regular", "compressed")][string]$WorkSchedule,
        [bool]$HolidayAdjacentToSecondRest = $false
    )

    $catalog = Get-SaphirOvertimeRateCatalog
    $category = Get-SaphirOvertimeCategory -OvertimeCode $OvertimeCode
    $timeAndHalf = [decimal]$catalog.multipliers.timeAndHalf
    $timeAndThreeQuarter = [decimal]$catalog.multipliers.timeAndThreeQuarter
    $doubleTime = [decimal]$catalog.multipliers.doubleTime

    if ($WorkSchedule -eq "compressed" -and $category -ne "holiday") {
        # PA 25.27: variable-schedule overtime on workdays and rest days.
        return [PSCustomObject]@{
            category = $category
            workSchedule = $WorkSchedule
            baseMultiplier = $timeAndThreeQuarter
            thresholdHours = $null
            excessMultiplier = $null
        }
    }

    if ($category -eq "subsequent-day-rest") {
        # PA 28.06(b): all work on the second/subsequent contiguous rest day.
        return [PSCustomObject]@{
            category = $category
            workSchedule = $WorkSchedule
            baseMultiplier = $doubleTime
            thresholdHours = $null
            excessMultiplier = $null
        }
    }

    if ($category -eq "holiday" -and $HolidayAdjacentToSecondRest) {
        # PA 30.08(c): holiday contiguous to a worked second/subsequent rest day.
        return [PSCustomObject]@{
            category = $category
            workSchedule = $WorkSchedule
            baseMultiplier = $doubleTime
            thresholdHours = $null
            excessMultiplier = $null
        }
    }

    if ($WorkSchedule -eq "compressed" -and $category -eq "holiday") {
        # SAPHIR currently knows that the schedule is compressed, but not the
        # employee's exact scheduled daily hours. Keep the supported portion at
        # 1.5 instead of inventing a double-time boundary.
        return [PSCustomObject]@{
            category = $category
            workSchedule = $WorkSchedule
            baseMultiplier = $timeAndHalf
            thresholdHours = $null
            excessMultiplier = $null
        }
    }

    # PA 28.05, 28.06(a), and 30.08(a): 1.5 for the first 7.5 hours,
    # then 2.0. Previously credited hours let multiple same-day rows share the
    # threshold without changing the legal entitlement.
    return [PSCustomObject]@{
        category = $category
        workSchedule = $WorkSchedule
        baseMultiplier = $timeAndHalf
        thresholdHours = [decimal]$catalog.thresholdHours
        excessMultiplier = $doubleTime
    }
}

function Get-SaphirOvertimeRateSegments {
    param(
        [AllowNull()][AllowEmptyString()][string]$OvertimeCode,
        [Parameter(Mandatory = $true)][ValidateSet("regular", "compressed")][string]$WorkSchedule,
        [Parameter(Mandatory = $true)][decimal]$Hours,
        [decimal]$PreviouslyCreditedHours = 0,
        [bool]$HolidayAdjacentToSecondRest = $false
    )

    if ($Hours -le 0) {
        return @()
    }
    if ($PreviouslyCreditedHours -lt 0) {
        throw [System.ArgumentOutOfRangeException]::new("PreviouslyCreditedHours", "Previously credited hours cannot be negative.")
    }

    $plan = Get-SaphirOvertimeRatePlan `
        -OvertimeCode $OvertimeCode `
        -WorkSchedule $WorkSchedule `
        -HolidayAdjacentToSecondRest $HolidayAdjacentToSecondRest

    if ($null -eq $plan.thresholdHours) {
        return @([PSCustomObject]@{
            category = [string]$plan.category
            multiplier = [decimal]$plan.baseMultiplier
            hours = [decimal]$Hours
        })
    }

    $remainingBaseHours = [decimal]::Max([decimal]0, ([decimal]$plan.thresholdHours - $PreviouslyCreditedHours))
    $baseHours = [decimal]::Min($Hours, $remainingBaseHours)
    $excessHours = $Hours - $baseHours
    $segments = New-Object System.Collections.ArrayList
    if ($baseHours -gt 0) {
        [void]$segments.Add([PSCustomObject]@{
            category = [string]$plan.category
            multiplier = [decimal]$plan.baseMultiplier
            hours = $baseHours
        })
    }
    if ($excessHours -gt 0) {
        [void]$segments.Add([PSCustomObject]@{
            category = [string]$plan.category
            multiplier = [decimal]$plan.excessMultiplier
            hours = $excessHours
        })
    }

    return @($segments.ToArray())
}

function ConvertTo-SaphirHourlyRateCents {
    <#
        PA defines the hourly rate as the annual rate divided by 52.176, then
        by 37.5 hours. Keep the decimal result unrounded so entry-level totals
        can be rounded once, at the cent, without compounding rate rounding.
    #>
    param([Parameter(Mandatory = $true)][long]$AnnualSalaryCents)

    if ($AnnualSalaryCents -le 0) {
        throw [System.ArgumentOutOfRangeException]::new("AnnualSalaryCents", "Annual salary cents must be positive.")
    }

    $contract = Get-SaphirOvertimeMonetaryContract
    return ([decimal]$AnnualSalaryCents / [decimal]$contract.annualHoursDivisor)
}

function Get-SaphirOvertimeCostEstimate {
    <#
        Calculates the economic value of one already-credited overtime entry.
        The caller is responsible for supplying the credited quarter-hours and
        the credited minutes from earlier entries on the same applicable day.
        JavaScript clients must consume projected results, never reproduce this
        calculation independently.
    #>
    param(
        [Parameter(Mandatory = $true)][long]$AnnualSalaryCents,
        [AllowNull()][AllowEmptyString()][string]$OvertimeCode,
        [Parameter(Mandatory = $true)][ValidateSet("regular", "compressed", "unconfirmed")][string]$WorkSchedule,
        [Parameter(Mandatory = $true)][int]$CreditedMinutes,
        [int]$PreviouslyCreditedMinutes = 0,
        [ValidateSet("cash", "leave")][string]$PaymentOption = "cash",
        [bool]$HolidayAdjacentToSecondRest = $false
    )

    if ($AnnualSalaryCents -le 0) {
        throw [System.ArgumentOutOfRangeException]::new("AnnualSalaryCents", "Annual salary cents must be positive.")
    }
    if ($CreditedMinutes -lt 0 -or ($CreditedMinutes % 15) -ne 0) {
        throw [System.ArgumentOutOfRangeException]::new("CreditedMinutes", "Credited minutes must be a non-negative multiple of 15.")
    }
    if ($PreviouslyCreditedMinutes -lt 0 -or ($PreviouslyCreditedMinutes % 15) -ne 0) {
        throw [System.ArgumentOutOfRangeException]::new("PreviouslyCreditedMinutes", "Previously credited minutes must be a non-negative multiple of 15.")
    }

    $contract = Get-SaphirOvertimeMonetaryContract
    $baseResult = [ordered]@{
        schemaVersion                       = [int]$contract.schemaVersion
        calculationVersion                  = [string]$contract.calculationVersion
        calculationStatus                   = "estimated"
        estimateOnly                        = $true
        currency                            = [string]$contract.currency
        costBasis                           = [string]$contract.costBasis
        includesEmployerCosts               = [bool]$contract.includesEmployerCosts
        overtimeCode                        = ([string]$OvertimeCode).Trim()
        overtimeCategory                    = Get-SaphirOvertimeCategory -OvertimeCode $OvertimeCode
        workSchedule                        = $WorkSchedule
        paymentOption                       = $PaymentOption
        creditedMinutes                     = $CreditedMinutes
        previouslyCreditedMinutes           = $PreviouslyCreditedMinutes
        annualSalaryCents                   = $AnnualSalaryCents
        annualHoursDivisor                  = [decimal]$contract.annualHoursDivisor
        hourlyRateCents                     = $null
        segments                            = @()
        totalAmountCents                    = $null
        cashAmountCents                     = $null
        compensatoryLeaveValueCents         = $null
        unavailableReason                   = $null
    }

    if ($WorkSchedule -eq "unconfirmed") {
        $baseResult.calculationStatus = "unavailable"
        $baseResult.unavailableReason = "work-schedule-unconfirmed"
        return [PSCustomObject]$baseResult
    }

    $hourlyRateCents = ConvertTo-SaphirHourlyRateCents -AnnualSalaryCents $AnnualSalaryCents
    $baseResult.hourlyRateCents = [decimal]::Round($hourlyRateCents, 6, [System.MidpointRounding]::AwayFromZero)

    $creditedHours = [decimal]$CreditedMinutes / [decimal]60
    $previouslyCreditedHours = [decimal]$PreviouslyCreditedMinutes / [decimal]60
    $rateSegments = @(Get-SaphirOvertimeRateSegments `
        -OvertimeCode $OvertimeCode `
        -WorkSchedule $WorkSchedule `
        -Hours $creditedHours `
        -PreviouslyCreditedHours $previouslyCreditedHours `
        -HolidayAdjacentToSecondRest $HolidayAdjacentToSecondRest)

    $segments = New-Object System.Collections.ArrayList
    $unroundedTotalCents = [decimal]0
    $roundedSegmentTotalCents = [long]0
    foreach ($rateSegment in $rateSegments) {
        $segmentMinutes = [int]([decimal]$rateSegment.hours * [decimal]60)
        $unroundedAmountCents = $hourlyRateCents * [decimal]$rateSegment.hours * [decimal]$rateSegment.multiplier
        $roundedAmountCents = [long][decimal]::Round($unroundedAmountCents, 0, [System.MidpointRounding]::AwayFromZero)
        $unroundedTotalCents += $unroundedAmountCents
        $roundedSegmentTotalCents += $roundedAmountCents
        [void]$segments.Add([PSCustomObject][ordered]@{
            category        = [string]$rateSegment.category
            creditedMinutes = $segmentMinutes
            multiplier      = [decimal]$rateSegment.multiplier
            amountCents     = $roundedAmountCents
        })
    }

    $totalAmountCents = [long][decimal]::Round($unroundedTotalCents, 0, [System.MidpointRounding]::AwayFromZero)
    if ($segments.Count -gt 0 -and $roundedSegmentTotalCents -ne $totalAmountCents) {
        $lastSegment = $segments[$segments.Count - 1]
        $lastSegment.amountCents = [long]$lastSegment.amountCents + ($totalAmountCents - $roundedSegmentTotalCents)
    }

    $baseResult.segments = @($segments.ToArray())
    $baseResult.totalAmountCents = $totalAmountCents
    $baseResult.cashAmountCents = if ($PaymentOption -eq "cash") { $totalAmountCents } else { [long]0 }
    $baseResult.compensatoryLeaveValueCents = if ($PaymentOption -eq "leave") { $totalAmountCents } else { [long]0 }
    return [PSCustomObject]$baseResult
}

Export-ModuleMember -Function @(
    "Get-SaphirOvertimeRateCatalog",
    "Get-SaphirOvertimeMonetaryContract",
    "Get-SaphirOvertimeCategory",
    "Get-SaphirOvertimeRatePlan",
    "Get-SaphirOvertimeRateSegments",
    "ConvertTo-SaphirHourlyRateCents",
    "Get-SaphirOvertimeCostEstimate"
)
