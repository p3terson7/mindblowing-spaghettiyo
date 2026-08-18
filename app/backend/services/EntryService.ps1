$entryIdentityModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.EntryIdentity.psd1"
Import-Module -Name $entryIdentityModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name entryIdentityModuleManifest -ErrorAction SilentlyContinue

$entryStateModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.EntryState.psd1"
Import-Module -Name $entryStateModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name entryStateModuleManifest -ErrorAction SilentlyContinue

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

    return (Saphir.EntryIdentity\Get-EntryIdentifierValue -Entry $Entry)
}

function Get-EntryExactPunchInText {
    param($Entry)

    return (Saphir.EntryIdentity\Get-EntryExactPunchInText -Entry $Entry)
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

    return (Saphir.EntryState\ConvertTo-BooleanFlag -Value $Value)
}

function Test-EntryForgottenClockOut {
    param($Entry)

    return (Saphir.EntryState\Test-EntryForgottenClockOut -Entry $Entry)
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
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Entries,
        [string]$EntryId,
        [string]$Date,
        [string]$PunchIn
    )

    return (Saphir.EntryIdentity\Find-EntryIndex -Entries $Entries -EntryId $EntryId -Date $Date -PunchIn $PunchIn)
}

function Get-EntryLegacyLookupKey {
    param(
        [string]$Date,
        [string]$PunchIn
    )

    return (Saphir.EntryIdentity\Get-EntryLegacyLookupKey -Date $Date -PunchIn $PunchIn)
}

function New-EntryIndexLookup {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Entries)

    return (Saphir.EntryIdentity\New-EntryIndexLookup -Entries $Entries)
}

function Find-EntryIndexFromLookup {
    param(
        [Parameter(Mandatory = $true)]$Lookup,
        [string]$EntryId,
        [string]$Date,
        [string]$PunchIn
    )

    return (Saphir.EntryIdentity\Find-EntryIndexFromLookup -Lookup $Lookup -EntryId $EntryId -Date $Date -PunchIn $PunchIn)
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
