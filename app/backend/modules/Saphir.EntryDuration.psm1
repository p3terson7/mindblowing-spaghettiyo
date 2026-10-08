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

function Get-QuarterHourCreditSummary {
    <#
        Each clock-aligned quarter-hour only earns fifteen minutes when the
        exact punch interval overlaps it for at least ten minutes.  This is
        deliberately based on exact times, not independently rounded punches.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Date,
        [Parameter(Mandatory = $true)][string]$PunchIn,
        [Parameter(Mandatory = $true)][string]$PunchOut
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $dateValue = [DateTime]::MinValue
    try {
        $dateValue = [DateTime]::ParseExact(([string]$Date).Trim(), "yyyy-MM-dd", $culture)
    }
    catch {
        return (New-QuarterHourCreditSummary)
    }

    $punchInValue = [DateTime]::MinValue
    $punchOutValue = [DateTime]::MinValue
    $timeFormats = @("HH:mm:ss", "H:mm:ss", "HH:mm", "H:mm")
    $hasPunchIn = $false
    $hasPunchOut = $false
    foreach ($format in $timeFormats) {
        if (-not $hasPunchIn) {
            try {
                $punchInValue = [DateTime]::ParseExact(([string]$PunchIn).Trim(), $format, $culture)
                $hasPunchIn = $true
            }
            catch {
                # Continue through the supported legacy time formats.
            }
        }
        if (-not $hasPunchOut) {
            try {
                $punchOutValue = [DateTime]::ParseExact(([string]$PunchOut).Trim(), $format, $culture)
                $hasPunchOut = $true
            }
            catch {
                # Continue through the supported legacy time formats.
            }
        }
    }

    if (-not $hasPunchIn -or -not $hasPunchOut) {
        return (New-QuarterHourCreditSummary)
    }

    $start = $dateValue.Date.Add($punchInValue.TimeOfDay)
    $end = $dateValue.Date.Add($punchOutValue.TimeOfDay)
    if ($end -le $start) {
        return (New-QuarterHourCreditSummary)
    }

    $actualSeconds = [int]($end - $start).TotalSeconds
    $quarterMinute = [int]([math]::Floor($start.Minute / 15.0) * 15)
    $quarterStart = $start.Date.AddHours($start.Hour).AddMinutes($quarterMinute)
    $creditedSeconds = 0
    $qualifyingQuarterCount = 0

    while ($quarterStart -lt $end) {
        $quarterEnd = $quarterStart.AddMinutes(15)
        $overlapStart = if ($start -gt $quarterStart) { $start } else { $quarterStart }
        $overlapEnd = if ($end -lt $quarterEnd) { $end } else { $quarterEnd }
        $overlapSeconds = [int]($overlapEnd - $overlapStart).TotalSeconds

        if ($overlapSeconds -ge 600) {
            $creditedSeconds += 900
            $qualifyingQuarterCount++
        }

        $quarterStart = $quarterEnd
    }

    return (New-QuarterHourCreditSummary `
        -IsValid $true `
        -ActualSeconds $actualSeconds `
        -CreditedSeconds $creditedSeconds `
        -QualifyingQuarterCount $qualifyingQuarterCount)
}

Export-ModuleMember -Function @(
    "Get-QuarterHourCreditSummary"
)
