function New-EntryIdentifier {
    return ([System.Guid]::NewGuid().ToString("N"))
}

function Convert-ToNormalizedDateText {
    param([string]$DateText)

    $candidate = ([string]$DateText).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
        $candidate,
        "yyyy-MM-dd",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )) {
        return $null
    }

    return $parsed.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
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

function Set-EntryPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Entry.PSObject.Properties.Name -contains $Name) {
        $Entry.PSObject.Properties[$Name].Value = $Value
        return
    }

    $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Convert-ToBooleanFlag {
    param($Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($null -eq $Value) {
        return $false
    }

    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    return ($normalized -eq "true" -or $normalized -eq "1" -or $normalized -eq "yes")
}

function Test-EntryForgottenClockOut {
    param($Entry)

    if ($null -eq $Entry) {
        return $false
    }

    $forgottenFlag = $false
    $reviewFlag = $false

    if ($Entry.PSObject.Properties.Name -contains "forgottenClockOut") {
        $forgottenFlag = Convert-ToBooleanFlag -Value $Entry.forgottenClockOut
    }

    if ($Entry.PSObject.Properties.Name -contains "needsClockOutReview") {
        $reviewFlag = Convert-ToBooleanFlag -Value $Entry.needsClockOutReview
    }

    return ($forgottenFlag -or $reviewFlag)
}

function Get-LatestActiveEntry {
    param([Parameter(Mandatory = $true)]$Entries)

    $latestEntry = $null
    $latestEntryDateTime = [DateTime]::MinValue
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry -or
            -not $entry.punchIn -or
            $entry.punchOut -or
            (Test-EntryForgottenClockOut -Entry $entry)) {
            continue
        }

        $entryDateTime = [DateTime]::MinValue
        try {
            $entryDateTime = [DateTime]::ParseExact(
                ("{0} {1}" -f [string]$entry.date, [string]$entry.punchIn),
                "yyyy-MM-dd HH:mm:ss",
                $null
            )
        }
        catch {
            # Invalid legacy timestamps rank before valid entries.
        }

        # Employee files are append ordered. When duplicate active records have
        # the same timestamp, deterministically prefer the later file record;
        # Sort-Object's tie ordering varies with the surrounding input shape.
        if ($null -eq $latestEntry -or $entryDateTime -ge $latestEntryDateTime) {
            $latestEntry = $entry
            $latestEntryDateTime = $entryDateTime
        }
    }

    return $latestEntry
}

function Set-EntryForgottenClockOutReview {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$AttemptDate,
        [Parameter(Mandatory = $true)][string]$AttemptTime
    )

    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOut" -Value $true
    Set-EntryPropertyValue -Entry $Entry -Name "needsClockOutReview" -Value $true
    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOutAttemptedDate" -Value $AttemptDate
    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOutAttemptedTime" -Value $AttemptTime
    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOutDetectedAtUtc" -Value ((Get-Date).ToUniversalTime().ToString("o"))

    $note = "Clock-out missing: employee attempted to end this previous-day entry on $AttemptDate at $AttemptTime. Supervisor must correct the end time."
    $currentMessage = if ($Entry.PSObject.Properties.Name -contains "message") { [string]$Entry.message } else { "" }
    if ([string]::IsNullOrWhiteSpace($currentMessage)) {
        Set-EntryPropertyValue -Entry $Entry -Name "message" -Value $note
    }
    elseif ($currentMessage -notmatch "Clock-out missing") {
        Set-EntryPropertyValue -Entry $Entry -Name "message" -Value ($currentMessage.Trim() + " " + $note)
    }
}

function Clear-EntryForgottenClockOutReview {
    param([Parameter(Mandatory = $true)]$Entry)

    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOut" -Value $false
    Set-EntryPropertyValue -Entry $Entry -Name "needsClockOutReview" -Value $false
    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOutAttemptedDate" -Value ""
    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOutAttemptedTime" -Value ""
    Set-EntryPropertyValue -Entry $Entry -Name "forgottenClockOutDetectedAtUtc" -Value ""
}

function Convert-ToNormalizedEntryObject {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    $entryType = if ($Entry.PSObject.Properties.Name -contains "entryType" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.entryType)) { ([string]$Entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }

    return [PSCustomObject]@{
        entryId       = Get-EntryIdentifierValue -Entry $Entry
        entryType     = $entryType
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
        paymentOption = if ($null -ne $Entry.paymentOption -and -not [string]::IsNullOrWhiteSpace([string]$Entry.paymentOption)) { [string]$Entry.paymentOption } elseif ($entryType -eq "diverse") { "" } else { "cash" }
        reasonCode    = if ($null -ne $Entry.reasonCode) { [string]$Entry.reasonCode } else { "" }
        workComment   = if ($Entry.PSObject.Properties.Name -contains "workComment") { [string]$Entry.workComment } else { "" }
        diverseReason = if ($Entry.PSObject.Properties.Name -contains "diverseReason") { [string]$Entry.diverseReason } else { "" }
        diverseSummary = if ($Entry.PSObject.Properties.Name -contains "diverseSummary") { [string]$Entry.diverseSummary } else { "" }
        forgottenClockOut = Test-EntryForgottenClockOut -Entry $Entry
        needsClockOutReview = Test-EntryForgottenClockOut -Entry $Entry
        forgottenClockOutAttemptedDate = if ($Entry.PSObject.Properties.Name -contains "forgottenClockOutAttemptedDate") { [string]$Entry.forgottenClockOutAttemptedDate } else { "" }
        forgottenClockOutAttemptedTime = if ($Entry.PSObject.Properties.Name -contains "forgottenClockOutAttemptedTime") { [string]$Entry.forgottenClockOutAttemptedTime } else { "" }
        forgottenClockOutDetectedAtUtc = if ($Entry.PSObject.Properties.Name -contains "forgottenClockOutDetectedAtUtc") { [string]$Entry.forgottenClockOutDetectedAtUtc } else { "" }
    }
}

function Find-EntryIndex {
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [string]$EntryId,
        [string]$Date,
        [string]$PunchIn
    )

    $entryList = @($Entries)
    if (-not [string]::IsNullOrWhiteSpace($EntryId)) {
        $matchingIndex = -1
        for ($i = 0; $i -lt $entryList.Count; $i++) {
            $storedEntryId = Get-EntryIdentifierValue -Entry $entryList[$i]
            if (-not [string]::IsNullOrWhiteSpace($storedEntryId) -and $storedEntryId -eq $EntryId) {
                if ($matchingIndex -ge 0) {
                    # Duplicate stable identifiers indicate damaged data. Fail
                    # closed instead of choosing an arbitrary record.
                    return -1
                }
                $matchingIndex = $i
            }
        }

        # Once a stable identifier is supplied, date/time metadata must never
        # redirect the mutation to a different entry.
        return $matchingIndex
    }

    $legacyMatchingIndex = -1
    for ($i = 0; $i -lt $entryList.Count; $i++) {
        $entry = $entryList[$i]
        if (-not [string]::IsNullOrWhiteSpace($Date) -and -not [string]::IsNullOrWhiteSpace($PunchIn)) {
            $exactPunchIn = Get-EntryExactPunchInText -Entry $entry
            if ([string]$entry.date -eq $Date -and ([string]$entry.punchIn -eq $PunchIn -or [string]$exactPunchIn -eq $PunchIn)) {
                if ($legacyMatchingIndex -ge 0) {
                    # Legacy date/time identifiers are only safe when unique.
                    return -1
                }
                $legacyMatchingIndex = $i
            }
        }
    }

    return $legacyMatchingIndex
}

function Get-EntryLegacyLookupKey {
    param(
        [string]$Date,
        [string]$PunchIn
    )

    if ([string]::IsNullOrWhiteSpace($Date) -or [string]::IsNullOrWhiteSpace($PunchIn)) {
        return ""
    }

    return ("{0}{1}{2}" -f $Date, [char]31, $PunchIn)
}

function New-EntryIndexLookup {
    param([Parameter(Mandatory = $true)]$Entries)

    $entryList = @($Entries)
    $byId = @{}
    $byDateAndPunch = @{}

    for ($i = 0; $i -lt $entryList.Count; $i++) {
        $entry = $entryList[$i]
        $entryId = Get-EntryIdentifierValue -Entry $entry
        if (-not [string]::IsNullOrWhiteSpace($entryId)) {
            if ($byId.ContainsKey($entryId)) {
                # A negative lookup value marks an ambiguous identifier.
                $byId[$entryId] = -1
            }
            else {
                $byId[$entryId] = $i
            }
        }

        $entryDate = [string]$entry.date
        if ([string]::IsNullOrWhiteSpace($entryDate)) {
            continue
        }

        $punchTimes = @([string]$entry.punchIn, [string](Get-EntryExactPunchInText -Entry $entry))
        foreach ($punchTime in $punchTimes) {
            $legacyKey = Get-EntryLegacyLookupKey -Date $entryDate -PunchIn $punchTime
            if (-not [string]::IsNullOrWhiteSpace($legacyKey)) {
                if ($byDateAndPunch.ContainsKey($legacyKey) -and [int]$byDateAndPunch[$legacyKey] -ne $i) {
                    $byDateAndPunch[$legacyKey] = -1
                }
                elseif (-not $byDateAndPunch.ContainsKey($legacyKey)) {
                    $byDateAndPunch[$legacyKey] = $i
                }
            }
        }
    }

    return [PSCustomObject]@{
        ById           = $byId
        ByDateAndPunch = $byDateAndPunch
    }
}

function Find-EntryIndexFromLookup {
    param(
        [Parameter(Mandatory = $true)]$Lookup,
        [string]$EntryId,
        [string]$Date,
        [string]$PunchIn
    )

    if (-not [string]::IsNullOrWhiteSpace($EntryId)) {
        if ($Lookup.ById.ContainsKey($EntryId)) {
            return [int]$Lookup.ById[$EntryId]
        }

        # Do not use mutable date/time fields as a fallback when the caller
        # supplied a stable ID: that could mutate a different record.
        return -1
    }

    $legacyKey = Get-EntryLegacyLookupKey -Date $Date -PunchIn $PunchIn
    if (-not [string]::IsNullOrWhiteSpace($legacyKey) -and $Lookup.ByDateAndPunch.ContainsKey($legacyKey)) {
        return [int]$Lookup.ByDateAndPunch[$legacyKey]
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
