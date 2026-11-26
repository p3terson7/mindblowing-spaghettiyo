function ConvertTo-SaphirNearestQuarterHourTime {
    param([Parameter(Mandatory = $true)][datetime]$Time)

    # Display rounds at minutes 08, 23, 38 and 53, without moving a punch
    # to the next day. Paid duration is a separate rule based on exact times.
    $minuteOfDay = 60 * $Time.Hour + $Time.Minute
    $roundedMinute = [math]::Min(23 * 60 + 45, 15 * [math]::Floor(($minuteOfDay + 7) / 15))
    return $Time.Date.AddMinutes($roundedMinute).ToString("HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-QuarterHourCreditSummary {
    param(
        [bool]$IsValid = $false,
        [int]$ActualSeconds = 0,
        [int]$CreditedSeconds = 0,
        [int]$QualifyingQuarterCount = 0
    )

    return [PSCustomObject]@{
        isValid                = $IsValid
        actualSeconds          = $ActualSeconds
        creditedSeconds        = $CreditedSeconds
        creditedOvertime       = [TimeSpan]::FromSeconds($CreditedSeconds).ToString("hh\:mm\:ss")
        qualifyingQuarterCount = $QualifyingQuarterCount
    }
}

$script:QuarterHourTimeFormats = [string[]]@("HH:mm:ss", "H:mm:ss", "HH:mm", "H:mm")

function Get-QuarterHourCreditSummary {
    <#
        Each clock-aligned quarter-hour only earns fifteen minutes when the
        exact punch interval overlaps it for at least ten minutes.  This is
        deliberately based on exact times, not independently rounded punches.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Date,
        [Parameter(Mandatory = $true)][string]$PunchIn,
        [Parameter(Mandatory = $true)][string]$PunchOut,
        # List-level checks need only the numeric result (-1 means invalid).
        [switch]$CreditedSecondsOnly
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::None
    $dateValue = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Date.Trim(), "yyyy-MM-dd", $culture, $styles, [ref]$dateValue)) {
        if ($CreditedSecondsOnly) { return -1 }
        return (New-QuarterHourCreditSummary)
    }

    $punchInValue = [DateTime]::MinValue
    $punchOutValue = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($PunchIn.Trim(), $script:QuarterHourTimeFormats, $culture, $styles, [ref]$punchInValue) -or
        -not [DateTime]::TryParseExact($PunchOut.Trim(), $script:QuarterHourTimeFormats, $culture, $styles, [ref]$punchOutValue)) {
        if ($CreditedSecondsOnly) { return -1 }
        return (New-QuarterHourCreditSummary)
    }

    $start = [int]$punchInValue.TimeOfDay.TotalSeconds
    $end = [int]$punchOutValue.TimeOfDay.TotalSeconds
    $actualSeconds = $end - $start
    if ($actualSeconds -le 0) {
        if ($CreditedSecondsOnly) { return -1 }
        return (New-QuarterHourCreditSummary)
    }

    # Only the edge quarters can be partial. The end is exclusive, so
    # a punch right on a boundary belongs to the preceding bucket.
    $first = [int][math]::Floor($start / 900.0)
    $last = [int][math]::Floor(($end - 1) / 900.0)
    if ($first -eq $last) {
        $qualifyingQuarterCount = [int]($actualSeconds -ge 600)
    }
    else {
        $qualifyingQuarterCount = $last - $first - 1
        if ((($first + 1) * 900 - $start) -ge 600) { $qualifyingQuarterCount++ }
        if (($end - $last * 900) -ge 600) { $qualifyingQuarterCount++ }
    }

    $creditedSeconds = 900 * $qualifyingQuarterCount
    if ($CreditedSecondsOnly) { return $creditedSeconds }
    return (New-QuarterHourCreditSummary `
        -IsValid $true `
        -ActualSeconds $actualSeconds `
        -CreditedSeconds $creditedSeconds `
        -QualifyingQuarterCount $qualifyingQuarterCount)
}

Export-ModuleMember -Function @(
    "ConvertTo-SaphirNearestQuarterHourTime",
    "Get-QuarterHourCreditSummary"
)
