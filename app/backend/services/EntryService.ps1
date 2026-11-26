$entryIdentityModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.EntryIdentity.psd1"
Import-Module -Name $entryIdentityModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name entryIdentityModuleManifest -ErrorAction SilentlyContinue

$entryStateModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.EntryState.psd1"
Import-Module -Name $entryStateModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name entryStateModuleManifest -ErrorAction SilentlyContinue

$entryDurationModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.EntryDuration.psd1"
Import-Module -Name $entryDurationModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name entryDurationModuleManifest -ErrorAction SilentlyContinue

$businessRulesModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.BusinessRules.psd1"
Import-Module -Name $businessRulesModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name businessRulesModuleManifest -ErrorAction SilentlyContinue

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
    return (Saphir.EntryDuration\ConvertTo-SaphirNearestQuarterHourTime -Time $dateTime)
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

    if (($null -ne $Entry.PSObject.Properties["exactPunchOut"]) -and -not [string]::IsNullOrWhiteSpace([string]$Entry.exactPunchOut)) {
        return [string]$Entry.exactPunchOut
    }

    if (($null -ne $Entry.PSObject.Properties["punchOut"]) -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchOut)) {
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

function Get-QuarterHourCreditSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Date,
        [Parameter(Mandatory = $true)][string]$PunchIn,
        [Parameter(Mandatory = $true)][string]$PunchOut
    )

    return (Saphir.EntryDuration\Get-QuarterHourCreditSummary -Date $Date -PunchIn $PunchIn -PunchOut $PunchOut)
}

function Test-EntryGc179Import {
    param($Entry)

    if ($null -eq $Entry) {
        return $false
    }

    foreach ($propertyName in @("gc179ImportBatchId", "gc179ImportedAtUtc", "gc179SourceFile")) {
        if ($Entry.PSObject.Properties.Name -contains $propertyName -and
            -not [string]::IsNullOrWhiteSpace([string]$Entry.PSObject.Properties[$propertyName].Value)) {
            return $true
        }
    }

    return $false
}

function Get-EntryReviewIssues {
    param($Entry, [switch]$AsBoolean)

    if ($null -eq $Entry) {
        if ($AsBoolean) { return $false }
        return
    }
    if (Test-EntryForgottenClockOut -Entry $Entry) {
        if ($AsBoolean) { return $true }
        [PSCustomObject]@{ code = "clockOutMissing" }
    }

    $exactPunchIn = Get-EntryExactPunchInText -Entry $Entry
    $exactPunchOut = Get-EntryExactPunchOutText -Entry $Entry
    if ([string]::IsNullOrWhiteSpace($exactPunchIn) -or [string]::IsNullOrWhiteSpace($exactPunchOut)) {
        if ($AsBoolean) { return $false }
        return
    }

    $credit = Saphir.EntryDuration\Get-QuarterHourCreditSummary -Date ([string]$Entry.date) -PunchIn $exactPunchIn -PunchOut $exactPunchOut -CreditedSecondsOnly:$AsBoolean
    $creditedSeconds = if ($AsBoolean) { $credit } elseif ($credit.isValid) { $credit.creditedSeconds } else { -1 }
    if ($creditedSeconds -lt 0) {
        if ($AsBoolean) { return $true }
        [PSCustomObject]@{ code = "invalidPunchTimes" }
    }
    elseif ($creditedSeconds -eq 0 -and -not (Test-EntryGc179Import -Entry $Entry)) {
        if ($AsBoolean) { return $true }
        [PSCustomObject]@{
            code            = "shortOvertime"
            actualSeconds   = [int]$credit.actualSeconds
            creditedSeconds = [int]$creditedSeconds
        }
    }
    if ($AsBoolean) { return $false }
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

function Set-EntrySupervisorNote {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [AllowNull()][AllowEmptyString()][string]$Note,
        $CurrentUser
    )

    $normalizedNote = ([string]$Note).Trim()
    Set-EntryPropertyValue -Entry $Entry -Name "message" -Value $normalizedNote

    # These fields are deliberately additive. Older entries without attribution
    # remain valid and are rendered with the legacy generic label.
    if ([string]::IsNullOrWhiteSpace($normalizedNote)) {
        Set-EntryPropertyValue -Entry $Entry -Name "messageAuthorName" -Value ""
        Set-EntryPropertyValue -Entry $Entry -Name "messageAuthorUsername" -Value ""
        Set-EntryPropertyValue -Entry $Entry -Name "messageUpdatedAt" -Value ""
        return $Entry
    }

    $authorName = ""
    $authorUsername = ""
    if ($null -ne $CurrentUser) {
        if ($CurrentUser.PSObject.Properties.Name -contains "displayName") {
            $authorName = ([string]$CurrentUser.displayName).Trim()
        }
        if ($CurrentUser.PSObject.Properties.Name -contains "username") {
            $authorUsername = ([string]$CurrentUser.username).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($authorName)) {
        $authorName = $authorUsername
    }

    Set-EntryPropertyValue -Entry $Entry -Name "messageAuthorName" -Value $authorName
    Set-EntryPropertyValue -Entry $Entry -Name "messageAuthorUsername" -Value $authorUsername
    Set-EntryPropertyValue -Entry $Entry -Name "messageUpdatedAt" -Value ((Get-Date).ToUniversalTime().ToString("o"))
    return $Entry
}

function ConvertTo-EntryNoteTimestamp {
    param($Value)
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime().ToString("o")
    }
    return [string]$Value
}

function Get-EntryEmployeeCommentAdditions {
    param($Entry)
    if ($null -eq $Entry.PSObject.Properties["employeeCommentAdditions"]) { return }
    foreach ($addition in @($Entry.employeeCommentAdditions)) {
        if ($null -ne $addition -and -not [string]::IsNullOrWhiteSpace([string]$addition.text)) {
            [PSCustomObject]@{
                id = [string]$addition.id
                text = [string]$addition.text
                createdAtUtc = ConvertTo-EntryNoteTimestamp $addition.createdAtUtc
            }
        }
    }
}

function Convert-ToNormalizedEntryObject {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    $properties = $Entry.PSObject.Properties
    $entryType = Saphir.BusinessRules\ConvertTo-SaphirEntryType -Value $(if ($null -ne $properties["entryType"]) { [string]$Entry.entryType } else { "" })
    $workSchedule = Saphir.BusinessRules\ConvertTo-SaphirWorkSchedule -Value $(if ($null -ne $properties["workSchedule"]) { [string]$Entry.workSchedule } else { "" })
    $forgottenClockOut = Test-EntryForgottenClockOut -Entry $Entry

    $normalizedEntry = [PSCustomObject]@{
        entryId       = Get-EntryIdentifierValue -Entry $Entry
        entryType     = $entryType
        workSchedule  = $workSchedule
        workScheduleSource = if ($null -ne $properties["workScheduleSource"]) { [string]$Entry.workScheduleSource } else { "" }
        name          = if ($null -ne $Entry.name) { [string]$Entry.name } else { "" }
        date          = if ($null -ne $Entry.date) { [string]$Entry.date } else { "" }
        punchIn       = if ($null -ne $Entry.punchIn) { [string]$Entry.punchIn } else { "" }
        exactPunchIn  = Get-EntryExactPunchInText -Entry $Entry
        punchOut      = if ($null -ne $Entry.punchOut -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchOut)) { [string]$Entry.punchOut } else { $null }
        exactPunchOut = Get-EntryExactPunchOutText -Entry $Entry
        overtime      = if ($null -ne $Entry.overtime -and -not [string]::IsNullOrWhiteSpace([string]$Entry.overtime)) { [string]$Entry.overtime } else { $null }
        status        = if ($null -ne $Entry.status -and -not [string]::IsNullOrWhiteSpace([string]$Entry.status)) { [string]$Entry.status } else { "pending" }
        message       = if ($null -ne $Entry.message) { [string]$Entry.message } else { "" }
        messageAuthorName = if ($null -ne $properties["messageAuthorName"]) { [string]$Entry.messageAuthorName } else { "" }
        messageAuthorUsername = if ($null -ne $properties["messageAuthorUsername"]) { [string]$Entry.messageAuthorUsername } else { "" }
        messageUpdatedAt = if ($null -ne $properties["messageUpdatedAt"]) { ConvertTo-EntryNoteTimestamp $Entry.messageUpdatedAt } else { "" }
        projectCode   = if ($null -ne $Entry.projectCode) { [string]$Entry.projectCode } else { "" }
        overtimeCode  = if ($null -ne $Entry.overtimeCode) { [string]$Entry.overtimeCode } else { "" }
        paymentOption = if ($null -ne $Entry.paymentOption -and -not [string]::IsNullOrWhiteSpace([string]$Entry.paymentOption)) { [string]$Entry.paymentOption } elseif ($entryType -eq "diverse") { "" } else { "cash" }
        reasonCode    = if ($null -ne $Entry.reasonCode) { [string]$Entry.reasonCode } else { "" }
        workComment   = if ($null -ne $properties["workComment"]) { [string]$Entry.workComment } else { "" }
        diverseReason = if ($null -ne $properties["diverseReason"]) { [string]$Entry.diverseReason } else { "" }
        diverseSummary = if ($null -ne $properties["diverseSummary"]) { [string]$Entry.diverseSummary } else { "" }
        overtimeCalculationRule = if ($null -ne $properties["overtimeCalculationRule"]) { [string]$Entry.overtimeCalculationRule } else { "" }
        gc179ImportBatchId = if ($null -ne $properties["gc179ImportBatchId"]) { [string]$Entry.gc179ImportBatchId } else { "" }
        gc179ImportedAtUtc = if ($null -ne $properties["gc179ImportedAtUtc"]) { [string]$Entry.gc179ImportedAtUtc } else { "" }
        gc179SourceFile = if ($null -ne $properties["gc179SourceFile"]) { [string]$Entry.gc179SourceFile } else { "" }
        forgottenClockOut = $forgottenClockOut
        needsClockOutReview = $forgottenClockOut
        forgottenClockOutAttemptedDate = if ($null -ne $properties["forgottenClockOutAttemptedDate"]) { [string]$Entry.forgottenClockOutAttemptedDate } else { "" }
        forgottenClockOutAttemptedTime = if ($null -ne $properties["forgottenClockOutAttemptedTime"]) { [string]$Entry.forgottenClockOutAttemptedTime } else { "" }
        forgottenClockOutDetectedAtUtc = if ($null -ne $properties["forgottenClockOutDetectedAtUtc"]) { [string]$Entry.forgottenClockOutDetectedAtUtc } else { "" }
    }
    if ($null -ne $properties["employeeCommentAdditions"]) {
        $normalizedEntry | Add-Member -NotePropertyName employeeCommentAdditions -NotePropertyValue @(Get-EntryEmployeeCommentAdditions $Entry)
    }
    if (($null -ne $properties["holidayNotScheduledWorkday"]) -and $Entry.holidayNotScheduledWorkday -is [bool]) {
        $normalizedEntry | Add-Member -NotePropertyName holidayNotScheduledWorkday -NotePropertyValue ([bool]$Entry.holidayNotScheduledWorkday)
    }
    return $normalizedEntry
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

    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace([string]$Entry.date)) {
        if ($null -ne $Entry) {
            $Entry.overtime = $null
        }
        return
    }

    # Imported GC179 rows carry the duration declared on the official form.
    # Saving a note or status change must never silently replace that value.
    if (Test-EntryGc179Import -Entry $Entry) {
        return
    }

    $exactPunchIn = Get-EntryExactPunchInText -Entry $Entry
    $exactPunchOut = Get-EntryExactPunchOutText -Entry $Entry
    if ([string]::IsNullOrWhiteSpace($exactPunchIn) -or [string]::IsNullOrWhiteSpace($exactPunchOut)) {
        $Entry.overtime = $null
        return
    }

    $creditSummary = Get-QuarterHourCreditSummary -Date ([string]$Entry.date) -PunchIn $exactPunchIn -PunchOut $exactPunchOut
    if (-not [bool]$creditSummary.isValid) {
        $Entry.overtime = $null
        return
    }

    Set-EntryPropertyValue -Entry $Entry -Name "overtime" -Value ([string]$creditSummary.creditedOvertime)
    Set-EntryPropertyValue -Entry $Entry -Name "overtimeCalculationRule" -Value "quarter-10m-v1"
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
