function New-EntryIdentifier {
    return ([System.Guid]::NewGuid().ToString("N"))
}

function Convert-ToNormalizedTimeText {
    param([string]$TimeText)

    $candidate = [string]$TimeText
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $formats = @(
        "HH:mm:ss",
        "H:mm:ss",
        "HH:mm",
        "H:mm"
    )

    foreach ($format in $formats) {
        try {
            $parsed = [DateTime]::ParseExact($candidate, $format, $null)
            return $parsed.ToString("HH:mm:ss")
        }
        catch {
            # Try the next supported time format.
        }
    }

    return $null
}

function Convert-ToNearestQuarterHourText {
    param(
        [Parameter(Mandatory = $true)][string]$Date,
        [Parameter(Mandatory = $true)][string]$TimeText
    )

    $normalizedTime = Convert-ToNormalizedTimeText -TimeText $TimeText
    if ([string]::IsNullOrWhiteSpace($normalizedTime)) {
        return $null
    }

    $dateTime = [DateTime]::ParseExact(("{0} {1}" -f $Date, $normalizedTime), "yyyy-MM-dd HH:mm:ss", $null)
    $roundedHour = $dateTime.Hour
    $roundedMinute = 0

    if ($dateTime.Minute -lt 8) {
        $roundedMinute = 0
    }
    elseif ($dateTime.Minute -lt 23) {
        $roundedMinute = 15
    }
    elseif ($dateTime.Minute -lt 38) {
        $roundedMinute = 30
    }
    elseif ($dateTime.Minute -lt 53) {
        $roundedMinute = 45
    }
    else {
        if ($dateTime.Hour -lt 23) {
            $roundedHour = $dateTime.Hour + 1
            $roundedMinute = 0
        }
        else {
            $roundedHour = 23
            $roundedMinute = 45
        }
    }

    return (Get-Date -Year $dateTime.Year -Month $dateTime.Month -Day $dateTime.Day -Hour $roundedHour -Minute $roundedMinute -Second 0).ToString("HH:mm:ss")
}

function Get-EntryIdentifierValue {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    if ($Entry.PSObject.Properties.Name -contains "entryId" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.entryId)) {
        return [string]$Entry.entryId
    }

    return $null
}

function Get-EntryExactPunchInText {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    if ($Entry.PSObject.Properties.Name -contains "exactPunchIn" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.exactPunchIn)) {
        return [string]$Entry.exactPunchIn
    }

    if ($Entry.PSObject.Properties.Name -contains "punchIn" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchIn)) {
        return [string]$Entry.punchIn
    }

    return $null
}

function Get-EntryExactPunchOutText {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    if ($Entry.PSObject.Properties.Name -contains "exactPunchOut" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.exactPunchOut)) {
        return [string]$Entry.exactPunchOut
    }

    if ($Entry.PSObject.Properties.Name -contains "punchOut" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchOut)) {
        return [string]$Entry.punchOut
    }

    return $null
}

function Convert-ToNormalizedEntryObject {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    return [PSCustomObject]@{
        entryId       = Get-EntryIdentifierValue -Entry $Entry
        name          = if ($null -ne $Entry.name) { [string]$Entry.name } else { "" }
        date          = if ($null -ne $Entry.date) { [string]$Entry.date } else { "" }
        punchIn       = if ($null -ne $Entry.punchIn) { [string]$Entry.punchIn } else { "" }
        exactPunchIn  = Get-EntryExactPunchInText -Entry $Entry
        punchOut      = if ($null -ne $Entry.punchOut -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchOut)) { [string]$Entry.punchOut } else { $null }
        exactPunchOut = Get-EntryExactPunchOutText -Entry $Entry
        overtime      = if ($null -ne $Entry.overtime -and -not [string]::IsNullOrWhiteSpace([string]$Entry.overtime)) { [string]$Entry.overtime } else { $null }
        status        = if ($null -ne $Entry.status -and -not [string]::IsNullOrWhiteSpace([string]$Entry.status)) { [string]$Entry.status } else { "pending" }
        message       = if ($null -ne $Entry.message) { [string]$Entry.message } else { "" }
        projectCode   = if ($null -ne $Entry.projectCode) { [string]$Entry.projectCode } else { "" }
        overtimeCode  = if ($null -ne $Entry.overtimeCode) { [string]$Entry.overtimeCode } else { "" }
    }
}

function Find-EntryIndex {
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [string]$EntryId,
        [string]$Date,
        [string]$PunchIn
    )

    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]
        $storedEntryId = Get-EntryIdentifierValue -Entry $entry
        if (-not [string]::IsNullOrWhiteSpace($EntryId) -and -not [string]::IsNullOrWhiteSpace($storedEntryId) -and $storedEntryId -eq $EntryId) {
            return $i
        }

        if (-not [string]::IsNullOrWhiteSpace($Date) -and -not [string]::IsNullOrWhiteSpace($PunchIn)) {
            $exactPunchIn = Get-EntryExactPunchInText -Entry $entry
            if ([string]$entry.date -eq $Date -and ([string]$entry.punchIn -eq $PunchIn -or [string]$exactPunchIn -eq $PunchIn)) {
                return $i
            }
        }
    }

    return -1
}

function Update-EntryComputedOvertime {
    param($Entry)

    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace([string]$Entry.date) -or [string]::IsNullOrWhiteSpace([string]$Entry.punchIn) -or [string]::IsNullOrWhiteSpace([string]$Entry.punchOut)) {
        if ($null -ne $Entry) {
            $Entry.overtime = $null
        }
        return
    }

    $punchInTime = [DateTime]::ParseExact(("{0} {1}" -f [string]$Entry.date, [string]$Entry.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
    $punchOutTime = [DateTime]::ParseExact(("{0} {1}" -f [string]$Entry.date, [string]$Entry.punchOut), "yyyy-MM-dd HH:mm:ss", $null)
    $Entry.overtime = ($punchOutTime - $punchInTime).ToString("hh\:mm\:ss")
}

function Get-EntryHistorySpanText {
    param(
        [Parameter(Mandatory = $true)][string]$StartTime,
        [string]$EndTime
    )

    if ([string]::IsNullOrWhiteSpace($EndTime)) {
        return "starting at <strong>$(Format-TimeForHistory $StartTime)</strong>"
    }

    return "from <strong>$(Format-TimeForHistory $StartTime)</strong> to <strong>$(Format-TimeForHistory $EndTime)</strong>"
}
