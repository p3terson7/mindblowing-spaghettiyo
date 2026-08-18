$script:Gc179ImportMaxContentBytes = 1048576
$script:Gc179ImportMaxFileNameLength = 260
$script:Gc179ImportMaxManagerMessageLength = 1000

function Set-Gc179ImportProperty {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        $PropertyValue
    )

    if ($Value.PSObject.Properties.Name -contains $Name) {
        $Value.PSObject.Properties[$Name].Value = $PropertyValue
        return
    }

    $Value | Add-Member -NotePropertyName $Name -NotePropertyValue $PropertyValue -Force
}

function Get-Gc179ImportSha256 {
    param([AllowNull()][string]$Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-Gc179ImportPayload {
    param(
        [Parameter(Mandatory = $true)][string]$FdfContent,
        [AllowNull()][string]$FileName,
        [AllowNull()][string]$ManagerMessage
    )

    if ([string]::IsNullOrWhiteSpace($FdfContent)) {
        throw "FDF content is required."
    }

    $contentByteCount = [System.Text.Encoding]::UTF8.GetByteCount($FdfContent)
    if ($contentByteCount -gt $script:Gc179ImportMaxContentBytes) {
        throw "The GC179 FDF is too large. The maximum supported size is 1 MB."
    }

    if ($FdfContent -notmatch "(?m)^%FDF-") {
        throw "The selected file is not an Acrobat FDF file. Export the completed GC179 as FDF and try again."
    }

    $safeFileName = [System.IO.Path]::GetFileName([string]$FileName)
    if ([string]::IsNullOrWhiteSpace($safeFileName)) {
        throw "An FDF filename is required."
    }
    if ($safeFileName.Length -gt $script:Gc179ImportMaxFileNameLength) {
        throw "The FDF filename is too long."
    }
    if ([System.IO.Path]::GetExtension($safeFileName).ToLowerInvariant() -ne ".fdf") {
        throw "The selected file must have an .fdf extension."
    }

    if (([string]$ManagerMessage).Length -gt $script:Gc179ImportMaxManagerMessageLength) {
        throw "The manager note cannot exceed 1000 characters."
    }
}

function Read-Gc179EmployeeDataStrict {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $raw = Read-TextFileWithRetry -Path $Path
    }
    catch {
        Rethrow-SaphirHttpStatusException -Exception $_.Exception
        throw "Unable to read the employee data file. No GC179 changes were made."
    }

    $trimmed = ([string]$raw).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or
        (-not $trimmed.StartsWith("[") -and -not $trimmed.StartsWith("{"))) {
        throw "The employee data file is not a valid JSON entry collection. Repair it before importing GC179 entries."
    }

    try {
        $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The employee data file contains invalid JSON. Repair it before importing GC179 entries."
    }

    if ($null -eq $parsed) {
        return @()
    }

    # v1 stored a single employee entry as a JSON object. Accept that legacy
    # root and normalize it to the same collection contract used by new data.
    return @($parsed)
}

function ConvertTo-Gc179ImportStatus {
    param([AllowNull()][string]$Status)

    $normalized = ([string]$Status).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "pending"
    }
    if ($normalized -ne "approved" -and $normalized -ne "pending" -and $normalized -ne "rejected") {
        throw "Status must be pending, approved, or rejected."
    }

    return $normalized
}

function ConvertFrom-Gc179ImportFdfLiteral {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ""
    }

    $text = [string]$Value
    if ($text.Length -ge 2 -and $text[0] -eq "(" -and $text[$text.Length - 1] -eq ")") {
        $text = $text.Substring(1, $text.Length - 2)
    }

    $builder = New-Object System.Text.StringBuilder
    $index = 0
    while ($index -lt $text.Length) {
        $char = $text[$index]
        if ($char -ne "\") {
            [void]$builder.Append($char)
            $index++
            continue
        }

        $index++
        if ($index -ge $text.Length) {
            [void]$builder.Append("\")
            break
        }

        $escaped = $text[$index]
        if ($escaped -eq "`r") {
            $index++
            if ($index -lt $text.Length -and $text[$index] -eq "`n") {
                $index++
            }
            continue
        }
        if ($escaped -eq "`n") {
            $index++
            continue
        }
        switch ($escaped) {
            "n" { [void]$builder.Append("`n"); $index++; continue }
            "r" { [void]$builder.Append("`r"); $index++; continue }
            "t" { [void]$builder.Append("`t"); $index++; continue }
            "b" { [void]$builder.Append("`b"); $index++; continue }
            "f" { [void]$builder.Append("`f"); $index++; continue }
            "(" { [void]$builder.Append("("); $index++; continue }
            ")" { [void]$builder.Append(")"); $index++; continue }
            "\" { [void]$builder.Append("\"); $index++; continue }
        }

        if ([string]$escaped -match "^[0-7]$") {
            $octal = New-Object System.Text.StringBuilder
            $octalCount = 0
            while ($index -lt $text.Length -and $octalCount -lt 3 -and [string]$text[$index] -match "^[0-7]$") {
                [void]$octal.Append($text[$index])
                $index++
                $octalCount++
            }
            [void]$builder.Append([char][Convert]::ToInt32($octal.ToString(), 8))
            continue
        }

        [void]$builder.Append($escaped)
        $index++
    }

    return $builder.ToString()
}

function ConvertFrom-Gc179ImportFdfName {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $name = ([string]$Value).Trim()
    if ($name.StartsWith("/")) {
        $name = $name.Substring(1)
    }

    $name = [regex]::Replace($name, "#([0-9A-Fa-f]{2})", {
        param($Match)
        return [string][char][Convert]::ToInt32($Match.Groups[1].Value, 16)
    })

    return $name
}

function ConvertFrom-Gc179ImportFdfValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $trimmed = ([string]$Value).Trim()
    if ($trimmed.StartsWith("(")) {
        return ConvertFrom-Gc179ImportFdfLiteral -Value $trimmed
    }

    if ($trimmed.StartsWith("/")) {
        return ConvertFrom-Gc179ImportFdfName -Value $trimmed
    }

    return $trimmed
}

function Read-Gc179ImportFdfFields {
    param([Parameter(Mandatory = $true)][string]$FdfContent)

    $fields = @{}
    $fieldPattern = "(?s)/T\s*(?<name>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+).*?/V\s*(?<value>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+|[^\s<>\[\]]+)"
    foreach ($match in [regex]::Matches([string]$FdfContent, $fieldPattern)) {
        $name = ConvertFrom-Gc179ImportFdfValue -Value $match.Groups["name"].Value
        $value = ConvertFrom-Gc179ImportFdfValue -Value $match.Groups["value"].Value
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $fields[$name] = $value
        }
    }

    # Acrobat exports repeated GC179 rows as a parent field with numeric Kids:
    # <</Kids[<</T(0)/V(11)>><</T(1)/V(15)>>]/T(DayofWeek)>>
    # Internally SAPHIR uses the generated FDF naming style DayofWeek.0, so
    # normalize Acrobat's structure to the same flat keys.
    $kidsPattern = "(?s)/Kids\s*\[(?<kids>.*?)\]\s*/T\s*(?<parent>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+)"
    foreach ($groupMatch in [regex]::Matches([string]$FdfContent, $kidsPattern)) {
        $parentName = ConvertFrom-Gc179ImportFdfValue -Value $groupMatch.Groups["parent"].Value
        if ([string]::IsNullOrWhiteSpace($parentName)) {
            continue
        }

        $kidsContent = $groupMatch.Groups["kids"].Value
        $childPattern = "(?s)<<\s*/T\s*(?<child>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+)(\s*/V\s*(?<value>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+|[^\s<>\[\]]+))?"
        foreach ($childMatch in [regex]::Matches($kidsContent, $childPattern)) {
            $childName = ConvertFrom-Gc179ImportFdfValue -Value $childMatch.Groups["child"].Value
            if ([string]::IsNullOrWhiteSpace($childName)) {
                continue
            }

            $fieldName = "{0}.{1}" -f $parentName, $childName
            $value = ""
            if ($childMatch.Groups["value"].Success) {
                $value = ConvertFrom-Gc179ImportFdfValue -Value $childMatch.Groups["value"].Value
            }
            $fields[$fieldName] = $value
        }
    }

    return $fields
}

function Get-Gc179ImportField {
    param(
        [Parameter(Mandatory = $true)]$Fields,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$RowIndex = -1
    )

    $candidates = @()
    if ($RowIndex -ge 0) {
        $candidates += ("{0}.{1}" -f $Name, $RowIndex)
        if ($Name -eq "Payment") {
            if ($RowIndex -eq 0) {
                $candidates += "Payment"
            }
            else {
                $candidates += ("Payment{0}" -f $RowIndex)
            }
        }
        if ($RowIndex -eq 0) {
            $candidates += $Name
        }
    }
    else {
        $candidates += $Name
    }

    foreach ($candidate in $candidates) {
        if ($Fields.ContainsKey($candidate)) {
            return [string]$Fields[$candidate]
        }
    }

    return ""
}

function ConvertTo-Gc179ImportMonthNumber {
    param([AllowNull()][string]$Value)

    $text = ([string]$Value).Trim()
    $month = 0
    if ([int]::TryParse($text, [ref]$month) -and $month -ge 1 -and $month -le 12) {
        return $month
    }

    return 0
}

function ConvertTo-Gc179ImportTimeText {
    param([AllowNull()][string]$Value)

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    $text = $text.Replace("H", ":").Replace("h", ":").Replace(".", ":")
    if ($text -match "^\d{3,4}$") {
        if ($text.Length -eq 3) {
            $text = "0$text"
        }
        $text = "{0}:{1}" -f $text.Substring(0, 2), $text.Substring(2, 2)
    }

    $parts = @($text.Split(":"))
    if ($parts.Count -eq 2 -or $parts.Count -eq 3) {
        $hour = 0
        $minute = 0
        $second = 0
        $validParts = [int]::TryParse([string]$parts[0], [ref]$hour) -and [int]::TryParse([string]$parts[1], [ref]$minute)
        if ($validParts -and $parts.Count -eq 3) {
            $validParts = [int]::TryParse([string]$parts[2], [ref]$second)
        }

        if ($validParts -and $hour -ge 0 -and $hour -le 23 -and $minute -ge 0 -and $minute -le 59 -and $second -ge 0 -and $second -le 59) {
            return ("{0:00}:{1:00}:{2:00}" -f $hour, $minute, $second)
        }
    }

    return ""
}

function ConvertTo-Gc179ImportDurationComponent {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][string]$Rate,
        [Parameter(Mandatory = $true)][string]$Category
    )

    $text = ([string]$Value).Trim().Replace(",", ".")
    $hours = 0.0
    if ([string]::IsNullOrWhiteSpace($text) -or -not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$hours) -or $hours -le 0) {
        return $null
    }

    $minutes = [int][math]::Round($hours * 60.0)
    return [PSCustomObject]@{
        field    = $FieldName
        rate     = $Rate
        category = $Category
        hours    = $hours.ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture)
        minutes  = $minutes
    }
}

function ConvertTo-Gc179ImportMinutesText {
    param([int]$Minutes)

    if ($Minutes -le 0) {
        return ""
    }

    return ("{0:00}:{1:00}:00" -f [math]::Floor($Minutes / 60), ($Minutes % 60))
}

function Get-Gc179ImportRateInfo {
    param(
        [Parameter(Mandatory = $true)]$Fields,
        [Parameter(Mandatory = $true)][int]$RowIndex
    )

    # Keep the legacy RegTime fields for checked-in/generated FDF compatibility,
    # and recognize every duration column present in the official GC179 PDF.
    $rateFields = @(
        @{ Name = "RegTime"; Rate = "1.0"; Category = "regular" },
        @{ Name = "RegTimeHalf"; Rate = "1.5"; Category = "regular" },
        @{ Name = "RegTime3Quarter"; Rate = "1.75"; Category = "regular" },
        @{ Name = "RegTimeDouble"; Rate = "2.0"; Category = "regular" },
        @{ Name = "FirstDayRest"; Rate = "1.0"; Category = "first-day-rest" },
        @{ Name = "FirstDayTimeHalf"; Rate = "1.5"; Category = "first-day-rest" },
        @{ Name = "FirstDay3Quarter"; Rate = "1.75"; Category = "first-day-rest" },
        @{ Name = "FirstDayTimeDbl"; Rate = "2.0"; Category = "first-day-rest" },
        @{ Name = "SubseqDayRest"; Rate = "1.0"; Category = "subsequent-day-rest" },
        @{ Name = "SubseqTimeHalf"; Rate = "1.5"; Category = "subsequent-day-rest" },
        @{ Name = "SubseqTime3Quarter"; Rate = "1.75"; Category = "subsequent-day-rest" },
        @{ Name = "SubseqTimeDbl"; Rate = "2.0"; Category = "subsequent-day-rest" },
        @{ Name = "Holiday"; Rate = "1.0"; Category = "holiday" },
        @{ Name = "HolidayTimeHalf"; Rate = "1.5"; Category = "holiday" },
        @{ Name = "HolidayTime3quarter"; Rate = "1.75"; Category = "holiday" },
        @{ Name = "HolidayTimeDbl"; Rate = "2.0"; Category = "holiday" },
        @{ Name = "CallBack"; Rate = "callback"; Category = "callback" },
        @{ Name = "StandbyWD"; Rate = "standby"; Category = "standby-weekday" },
        @{ Name = "StandbyWE"; Rate = "standby"; Category = "standby-weekend" },
        @{ Name = "ShiftWD_Ev"; Rate = "shift"; Category = "weekday-evening" },
        @{ Name = "ShiftWD_Night"; Rate = "shift"; Category = "weekday-night" },
        @{ Name = "ShiftSatDay"; Rate = "shift"; Category = "saturday-day" },
        @{ Name = "ShiftSatEven"; Rate = "shift"; Category = "saturday-evening" },
        @{ Name = "ShiftSatNight"; Rate = "shift"; Category = "saturday-night" },
        @{ Name = "ShiftSunDay"; Rate = "shift"; Category = "sunday-day" },
        @{ Name = "ShiftSunEven"; Rate = "shift"; Category = "sunday-evening" },
        @{ Name = "ShiftSunNight"; Rate = "shift"; Category = "sunday-night" }
    )

    $components = New-Object System.Collections.ArrayList
    $invalidFields = New-Object System.Collections.ArrayList
    foreach ($rateField in $rateFields) {
        $value = Get-Gc179ImportField -Fields $Fields -Name ([string]$rateField.Name) -RowIndex $RowIndex
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $normalizedValue = ([string]$value).Trim().Replace(",", ".")
            $numericValue = 0.0
            if (-not [double]::TryParse($normalizedValue, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$numericValue) -or $numericValue -lt 0) {
                [void]$invalidFields.Add([string]$rateField.Name)
            }
            elseif ($numericValue -gt 0) {
                $component = ConvertTo-Gc179ImportDurationComponent -Value $value -FieldName ([string]$rateField.Name) -Rate ([string]$rateField.Rate) -Category ([string]$rateField.Category)
                [void]$components.Add($component)
            }
        }
    }

    $componentArray = @($components.ToArray())
    $totalMinutes = 0
    foreach ($component in $componentArray) {
        $totalMinutes += [int]$component.minutes
    }

    return [PSCustomObject]@{
        FieldName    = if ($componentArray.Count -eq 1) { [string]$componentArray[0].field } elseif ($componentArray.Count -gt 1) { "mixed" } else { "" }
        Rate         = if ($componentArray.Count -eq 1) { [string]$componentArray[0].rate } elseif ($componentArray.Count -gt 1) { "mixed" } else { "" }
        Value        = if ($totalMinutes -gt 0) { ($totalMinutes / 60.0).ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture) } else { "" }
        DurationText = ConvertTo-Gc179ImportMinutesText -Minutes $totalMinutes
        TotalMinutes = $totalMinutes
        Components   = $componentArray
        InvalidFields = @($invalidFields.ToArray())
        HasAnyValue  = ($componentArray.Count -gt 0 -or $invalidFields.Count -gt 0)
    }
}

function Get-Gc179ImportPaymentOption {
    param([AllowNull()][string]$Value)

    $normalized = ([string]$Value).Trim().TrimStart("/")
    switch ($normalized) {
        "1" { return "cash" }
        "2" { return "leave" }
        default { return "" }
    }
}

function Get-Gc179ImportWorkWeek {
    param([AllowNull()][string]$Value)

    $normalized = ([string]$Value).Trim().TrimStart("/")
    switch ($normalized) {
        "1" { return "standard" }
        "2" { return "compressed" }
        default { return "" }
    }
}

function New-Gc179ImportPreview {
    param(
        [Parameter(Mandatory = $true)][string]$FdfContent,
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [AllowNull()][string]$ProjectCode,
        [AllowNull()][string]$FileName,
        [AllowNull()][string]$Status,
        [AllowNull()][string]$ManagerMessage
    )

    $fields = Read-Gc179ImportFdfFields -FdfContent $FdfContent
    if ($fields.Count -eq 0) {
        throw "No FDF form fields could be read."
    }

    $month = ConvertTo-Gc179ImportMonthNumber -Value (Get-Gc179ImportField -Fields $fields -Name "Month")
    $yearText = (Get-Gc179ImportField -Fields $fields -Name "Year").Trim()
    $year = 0
    if (-not [int]::TryParse($yearText, [ref]$year)) {
        $year = 0
    }

    if ($month -lt 1) {
        throw "The GC179 month is missing or invalid."
    }
    if ($year -lt 2000 -or $year -gt 2100) {
        throw "The GC179 year is missing or outside the supported range 2000-2100."
    }

    $normalizedStatus = ConvertTo-Gc179ImportStatus -Status $Status

    $entries = @()
    $warnings = @()
    $skippedRowCount = 0
    for ($rowIndex = 0; $rowIndex -lt 16; $rowIndex++) {
        $dayText = (Get-Gc179ImportField -Fields $fields -Name "DayofWeek" -RowIndex $rowIndex).Trim()
        $startTime = ConvertTo-Gc179ImportTimeText -Value (Get-Gc179ImportField -Fields $fields -Name "StartTime" -RowIndex $rowIndex)
        $endTime = ConvertTo-Gc179ImportTimeText -Value (Get-Gc179ImportField -Fields $fields -Name "EndTime" -RowIndex $rowIndex)
        $overtimeCode = (Get-Gc179ImportField -Fields $fields -Name "OvertimeCode" -RowIndex $rowIndex).Trim()
        $reasonCode = (Get-Gc179ImportField -Fields $fields -Name "OTCODE" -RowIndex $rowIndex).Trim()
        $paymentOption = Get-Gc179ImportPaymentOption -Value (Get-Gc179ImportField -Fields $fields -Name "Payment" -RowIndex $rowIndex)
        $rateInfo = Get-Gc179ImportRateInfo -Fields $fields -RowIndex $rowIndex

        if ([string]::IsNullOrWhiteSpace($dayText) -and [string]::IsNullOrWhiteSpace($startTime) -and [string]::IsNullOrWhiteSpace($endTime) -and [string]::IsNullOrWhiteSpace($overtimeCode) -and [string]::IsNullOrWhiteSpace($reasonCode) -and -not [bool]$rateInfo.HasAnyValue) {
            continue
        }

        $day = 0
        if ($month -lt 1 -or $year -lt 1 -or -not [int]::TryParse($dayText, [ref]$day)) {
            $warnings += "Row $($rowIndex + 1) skipped: invalid date."
            $skippedRowCount++
            continue
        }

        try {
            $entryDate = Get-Date -Year $year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
        }
        catch {
            $warnings += "Row $($rowIndex + 1) skipped: invalid calendar date."
            $skippedRowCount++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($startTime) -or [string]::IsNullOrWhiteSpace($endTime)) {
            $warnings += "Row $($rowIndex + 1) skipped: start or end time is missing."
            $skippedRowCount++
            continue
        }

        $rowValidationErrors = @()
        $rowWarnings = @()
        foreach ($invalidField in @($rateInfo.InvalidFields)) {
            $rowValidationErrors += "Row $($rowIndex + 1) has an invalid duration in '$invalidField'."
        }

        $intervalMinutes = 0
        try {
            $start = [DateTime]::ParseExact(("{0} {1}" -f $entryDate.ToString("yyyy-MM-dd"), $startTime), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
            $end = [DateTime]::ParseExact(("{0} {1}" -f $entryDate.ToString("yyyy-MM-dd"), $endTime), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
            if ($end -le $start) {
                $end = $end.AddDays(1)
            }
            $intervalMinutes = [int][math]::Round(($end - $start).TotalMinutes)
        }
        catch {
            $rowValidationErrors += "Row $($rowIndex + 1) has an invalid punch interval."
        }

        $durationText = [string]$rateInfo.DurationText
        if ([string]::IsNullOrWhiteSpace($durationText)) {
            $durationText = ConvertTo-Gc179ImportMinutesText -Minutes $intervalMinutes
        }
        elseif ($intervalMinutes -gt 0 -and [math]::Abs(([int]$rateInfo.TotalMinutes) - $intervalMinutes) -gt 1) {
            $rowWarnings += "Row $($rowIndex + 1): GC179 duration columns total $($rateInfo.DurationText), but the punch interval is $(ConvertTo-Gc179ImportMinutesText -Minutes $intervalMinutes)."
        }

        if ([string]::IsNullOrWhiteSpace($durationText)) {
            $rowValidationErrors += "Row $($rowIndex + 1) has no usable duration."
        }

        $warnings += @($rowWarnings)

        $entries += [PSCustomObject]@{
            entryType          = "overtime"
            date               = $entryDate.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
            punchIn            = $startTime
            exactPunchIn       = $startTime
            punchOut           = $endTime
            exactPunchOut      = $endTime
            overtime           = $durationText
            status             = $normalizedStatus
            message            = ([string]$ManagerMessage).Trim()
            projectCode        = ([string]$ProjectCode).Trim()
            overtimeCode       = $overtimeCode
            paymentOption      = $paymentOption
            reasonCode         = $reasonCode
            sourceRow          = $rowIndex
            gc179Rate          = [string]$rateInfo.Rate
            gc179RateField     = [string]$rateInfo.FieldName
            gc179DurationValue = [string]$rateInfo.Value
            gc179RateComponents = @($rateInfo.Components)
            validationErrors   = @($rowValidationErrors)
            warnings           = @($rowWarnings)
        }
    }

    $monthKey = ""
    if ($month -ge 1 -and $year -ge 1) {
        $monthKey = ("{0:0000}-{1:00}" -f $year, $month)
    }

    return [PSCustomObject]@{
        kind         = "gc179-import-preview"
        sourceFile   = [System.IO.Path]::GetFileName([string]$FileName)
        employeeCode = [string]$EmployeeCode
        projectCode  = ([string]$ProjectCode).Trim()
        fieldCount   = $fields.Count
        monthKey     = $monthKey
        skippedRowCount = $skippedRowCount
        header       = [PSCustomObject]@{
            month      = Get-Gc179ImportField -Fields $fields -Name "Month"
            year       = Get-Gc179ImportField -Fields $fields -Name "Year"
            surname    = Get-Gc179ImportField -Fields $fields -Name "Surname"
            givenName  = Get-Gc179ImportField -Fields $fields -Name "Given"
            initials   = Get-Gc179ImportField -Fields $fields -Name "Initials"
            pri        = Get-Gc179ImportField -Fields $fields -Name "PRI"
            department = Get-Gc179ImportField -Fields $fields -Name "Department"
            branch     = Get-Gc179ImportField -Fields $fields -Name "Branch"
            payList    = Get-Gc179ImportField -Fields $fields -Name "Paylist"
            group      = Get-Gc179ImportField -Fields $fields -Name "Group"
            subGroup   = Get-Gc179ImportField -Fields $fields -Name "SubGroup"
            level      = Get-Gc179ImportField -Fields $fields -Name "Level"
            workWeek   = Get-Gc179ImportWorkWeek -Value (Get-Gc179ImportField -Fields $fields -Name "WorkWeek")
        }
        entryCount   = @($entries).Count
        entries      = @($entries)
        warnings     = @($warnings)
    }
}

function Get-Gc179ImportDuplicateKey {
    param($Entry)

    return ("{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f [string]$Entry.date, [string]$Entry.punchIn, [string]$Entry.punchOut, [string]$Entry.projectCode, [string]$Entry.overtimeCode, [string]$Entry.paymentOption, [string]$Entry.reasonCode)
}

function ConvertTo-Gc179IdentityDigits {
    param([AllowNull()][string]$Value)

    return (([string]$Value) -replace "\D", "")
}

function Get-Gc179ImportFileEmployeeCode {
    param([AllowNull()][string]$FileName)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileName([string]$FileName))
    if ($baseName -match "^gc179[-_](?<code>\d{6,12})([-_]|$)") {
        return [string]$matches["code"]
    }
    if ($baseName -match "^(?<code>\d{6,12})_.*_GC179(_|$)") {
        return [string]$matches["code"]
    }

    return ""
}

function Get-Gc179ImportIdentity {
    param(
        [Parameter(Mandatory = $true)]$Preview,
        [Parameter(Mandatory = $true)]$EmployeeUser,
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [AllowNull()][string]$FileName,
        [bool]$ConfirmIdentity = $false
    )

    $sourcePri = ConvertTo-Gc179IdentityDigits -Value ([string]$Preview.header.pri)
    $sourceFileCode = Get-Gc179ImportFileEmployeeCode -FileName $FileName
    $targetProfile = Get-Gc179ProfileFromUserRecord -UserRecord $EmployeeUser
    $targetPri = ConvertTo-Gc179IdentityDigits -Value ([string]$targetProfile.pri)
    $sourceName = (("{0} {1}" -f [string]$Preview.header.givenName, [string]$Preview.header.surname).Trim())

    $matchesIdentity = New-Object System.Collections.ArrayList
    $mismatchesIdentity = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($sourceFileCode)) {
        if ($sourceFileCode -eq $EmployeeCode) {
            [void]$matchesIdentity.Add("filename")
        }
        else {
            [void]$mismatchesIdentity.Add(("filename employee code {0}" -f $sourceFileCode))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($sourcePri) -and -not [string]::IsNullOrWhiteSpace($targetPri)) {
        if ($sourcePri -eq $targetPri) {
            [void]$matchesIdentity.Add("PRI")
        }
        else {
            [void]$mismatchesIdentity.Add(("form PRI {0}" -f $sourcePri))
        }
    }

    $status = "unverified"
    $message = "The FDF does not contain identity information that SAPHIR can verify. Confirm that it belongs to the selected employee before importing."
    if ($mismatchesIdentity.Count -gt 0) {
        $status = "mismatch"
        $message = "The GC179 identity does not match employee $EmployeeCode ($EmployeeName): $([string]::Join(', ', @($mismatchesIdentity.ToArray())))."
    }
    elseif ($matchesIdentity.Count -gt 0) {
        $status = "matched"
        $message = "GC179 identity matched using $([string]::Join(' and ', @($matchesIdentity.ToArray())))."
    }

    return [PSCustomObject]@{
        status                = $status
        sourceEmployeeCode    = $sourceFileCode
        sourcePri             = $sourcePri
        sourceName            = $sourceName
        targetEmployeeCode    = $EmployeeCode
        targetEmployeeName    = $EmployeeName
        targetPri             = $targetPri
        message               = $message
        requiresConfirmation  = ($status -eq "unverified")
        confirmed             = ($status -eq "matched" -or ($status -eq "unverified" -and $ConfirmIdentity))
    }
}

function Get-Gc179ImportDurationSignature {
    param($Entry)

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add(([string]$Entry.overtime).Trim())
    if ($Entry.PSObject.Properties.Name -contains "gc179RateComponents") {
        foreach ($component in @($Entry.gc179RateComponents)) {
            if ($null -eq $component) {
                continue
            }
            [void]$parts.Add(("{0}:{1}:{2}" -f [string]$component.field, [string]$component.rate, [string]$component.hours))
        }
    }

    return [string]::Join("|", @($parts.ToArray()))
}

function Get-Gc179ImportRateComponentSignature {
    param($Entry)

    $parts = New-Object System.Collections.ArrayList
    if ($Entry.PSObject.Properties.Name -contains "gc179RateComponents") {
        foreach ($component in @($Entry.gc179RateComponents)) {
            if ($null -ne $component) {
                [void]$parts.Add(("{0}:{1}:{2}" -f [string]$component.field, [string]$component.rate, [string]$component.hours))
            }
        }
    }
    return [string]::Join("|", @($parts.ToArray()))
}

function Test-Gc179ImportEntriesExactDuplicate {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    if (([string]$Left.overtime).Trim() -ne ([string]$Right.overtime).Trim()) {
        return $false
    }

    $leftComponents = Get-Gc179ImportRateComponentSignature -Entry $Left
    $rightComponents = Get-Gc179ImportRateComponentSignature -Entry $Right
    if ([string]::IsNullOrWhiteSpace($leftComponents) -or [string]::IsNullOrWhiteSpace($rightComponents)) {
        return $true
    }

    return ($leftComponents -eq $rightComponents)
}

function Complete-Gc179ImportPreview {
    param(
        [Parameter(Mandatory = $true)]$Preview,
        [Parameter(Mandatory = $true)]$EmployeeUser,
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [AllowNull()][string]$FileName,
        [bool]$ConfirmIdentity = $false,
        [bool]$SkipDuplicates = $true
    )

    if (-not $SkipDuplicates) {
        throw "GC179 duplicate skipping cannot be disabled."
    }

    $identity = Get-Gc179ImportIdentity -Preview $Preview -EmployeeUser $EmployeeUser -EmployeeCode $EmployeeCode -EmployeeName $EmployeeName -FileName $FileName -ConfirmIdentity:$ConfirmIdentity
    $globalErrors = @()
    if ([string]$identity.status -eq "mismatch") {
        $globalErrors += [string]$identity.message
    }

    $dataFile = Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode
    $existingEntries = @(Read-Gc179EmployeeDataStrict -Path $dataFile)
    $existingByBaseKey = @{}
    foreach ($existingEntry in $existingEntries) {
        if ($null -eq $existingEntry) {
            continue
        }
        $baseKey = Get-Gc179ImportDuplicateKey -Entry $existingEntry
        if (-not $existingByBaseKey.ContainsKey($baseKey)) {
            $existingByBaseKey[$baseKey] = New-Object System.Collections.ArrayList
        }
        [void]$existingByBaseKey[$baseKey].Add($existingEntry)
    }

    $overtimeCodes = Get-OvertimeCodes
    $paymentOptions = Get-PaymentOptions
    $reasonCodes = Get-ReasonCodes
    $duplicateCount = 0
    $errorRowCount = 0
    $validRowCount = 0
    $importableCount = 0

    foreach ($entry in @($Preview.entries)) {
        $rowNumber = ([int]$entry.sourceRow) + 1
        $rowErrors = @()
        if ($entry.PSObject.Properties.Name -contains "validationErrors") {
            $rowErrors += @($entry.validationErrors)
        }
        if (-not (Test-OptionCode -Options $overtimeCodes -Code ([string]$entry.overtimeCode) -AllowBlank $true)) {
            $rowErrors += "Row $rowNumber has invalid overtime code '$($entry.overtimeCode)'."
        }
        if (-not (Test-OptionCode -Options $paymentOptions -Code ([string]$entry.paymentOption) -AllowBlank $false)) {
            $rowErrors += "Row $rowNumber has a missing or invalid payment option."
        }
        if (-not (Test-OptionCode -Options $reasonCodes -Code ([string]$entry.reasonCode) -AllowBlank $true)) {
            $rowErrors += "Row $rowNumber has invalid reason code '$($entry.reasonCode)'."
        }

        $duplicateStatus = "none"
        $baseKey = Get-Gc179ImportDuplicateKey -Entry $entry
        if ($existingByBaseKey.ContainsKey($baseKey)) {
            $hasExact = $false
            foreach ($existingEntry in @($existingByBaseKey[$baseKey])) {
                if (Test-Gc179ImportEntriesExactDuplicate -Left $existingEntry -Right $entry) {
                    $hasExact = $true
                    break
                }
            }

            if ($hasExact) {
                $duplicateStatus = "exact"
            }
            else {
                $duplicateStatus = "conflict"
                $rowErrors += "Row $rowNumber matches an existing shift, but its duration or GC179 rate components differ. Resolve it manually."
            }
            $duplicateCount++
        }

        $canImport = ($rowErrors.Count -eq 0 -and $duplicateStatus -eq "none")
        Set-Gc179ImportProperty -Value $entry -Name "validationErrors" -PropertyValue @($rowErrors)
        Set-Gc179ImportProperty -Value $entry -Name "isDuplicate" -PropertyValue ($duplicateStatus -ne "none")
        Set-Gc179ImportProperty -Value $entry -Name "duplicateStatus" -PropertyValue $duplicateStatus
        Set-Gc179ImportProperty -Value $entry -Name "canImport" -PropertyValue ([bool]$canImport)

        if ($rowErrors.Count -gt 0) {
            $errorRowCount++
        }
        else {
            $validRowCount++
        }
        if ($canImport) {
            $importableCount++
        }
    }

    if ([int]$Preview.entryCount -le 0) {
        $globalErrors += "No importable GC179 entries were found."
    }

    $counts = [PSCustomObject]@{
        parsed     = ([int]$Preview.entryCount + [int]$Preview.skippedRowCount)
        valid      = $validRowCount
        skipped    = [int]$Preview.skippedRowCount
        duplicates = $duplicateCount
        errors     = $errorRowCount
        importable = $importableCount
    }
    $identityReady = ([string]$identity.status -eq "matched" -or [bool]$identity.confirmed)
    Set-Gc179ImportProperty -Value $Preview -Name "identity" -PropertyValue $identity
    Set-Gc179ImportProperty -Value $Preview -Name "validationErrors" -PropertyValue @($globalErrors)
    Set-Gc179ImportProperty -Value $Preview -Name "counts" -PropertyValue $counts
    Set-Gc179ImportProperty -Value $Preview -Name "canCommit" -PropertyValue ([bool]($globalErrors.Count -eq 0 -and $identityReady -and $importableCount -gt 0))

    return $Preview
}

function Get-Gc179SelectedImportEntries {
    param(
        [Parameter(Mandatory = $true)]$Preview,
        [Parameter(Mandatory = $true)][int[]]$SelectedSourceRows
    )

    if (@($SelectedSourceRows).Count -eq 0) {
        throw "Select at least one GC179 row to import."
    }

    $entryByRow = @{}
    foreach ($entry in @($Preview.entries)) {
        $entryByRow[[int]$entry.sourceRow] = $entry
    }

    $selected = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($sourceRow in @($SelectedSourceRows)) {
        if ($sourceRow -lt 0 -or $sourceRow -gt 15 -or -not $entryByRow.ContainsKey([int]$sourceRow)) {
            throw "Selected GC179 row $($sourceRow + 1) is not available in this preview."
        }
        if ($seen.ContainsKey([int]$sourceRow)) {
            continue
        }

        $entry = $entryByRow[[int]$sourceRow]
        if (-not [bool]$entry.canImport) {
            $details = @($entry.validationErrors) -join " "
            if ([string]::IsNullOrWhiteSpace($details) -and [bool]$entry.isDuplicate) {
                $details = "It is already present in the employee's records."
            }
            throw "GC179 row $($sourceRow + 1) cannot be imported. $details"
        }

        [void]$selected.Add($entry)
        $seen[[int]$sourceRow] = $true
    }

    return @($selected.ToArray())
}

function Import-Gc179PreviewEntries {
    param(
        [Parameter(Mandatory = $true)]$Preview,
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [AllowNull()][string]$SourceFile,
        [AllowNull()][string]$SourceHash,
        [AllowNull()][string]$ImportedBy,
        [AllowNull()][string]$BatchId,
        [bool]$SkipDuplicates = $true,
        [bool]$PublishChange = $true
    )

    if (-not $SkipDuplicates) {
        throw "GC179 duplicate skipping cannot be disabled."
    }

    $resolvedBatchId = ([string]$BatchId).Trim()
    if ([string]::IsNullOrWhiteSpace($resolvedBatchId)) {
        $resolvedBatchId = "gc179-" + [Guid]::NewGuid().ToString("N")
    }
    if ($resolvedBatchId -notmatch "^gc179-[0-9a-fA-F]{32}$") {
        throw "Invalid GC179 import batch identifier."
    }

    $dataFile = Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode
    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
    $imported = 0
    $skippedDuplicates = 0
    $importedEntryIds = @()
    try {
        $existingData = @(Read-Gc179EmployeeDataStrict -Path $dataFile)
        $existingByBaseKey = @{}
        foreach ($existingEntry in $existingData) {
            if ($null -ne $existingEntry) {
                $baseKey = Get-Gc179ImportDuplicateKey -Entry $existingEntry
                if (-not $existingByBaseKey.ContainsKey($baseKey)) {
                    $existingByBaseKey[$baseKey] = New-Object System.Collections.ArrayList
                }
                [void]$existingByBaseKey[$baseKey].Add($existingEntry)
            }
        }

        $importedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        foreach ($entry in @($Preview.entries)) {
            $baseKey = Get-Gc179ImportDuplicateKey -Entry $entry
            if ($existingByBaseKey.ContainsKey($baseKey)) {
                $hasExact = $false
                foreach ($existingEntry in @($existingByBaseKey[$baseKey])) {
                    if (Test-Gc179ImportEntriesExactDuplicate -Left $existingEntry -Right $entry) {
                        $hasExact = $true
                        break
                    }
                }

                if (-not $hasExact) {
                    throw "GC179 row $(([int]$entry.sourceRow) + 1) conflicts with an existing shift whose duration or rate components differ. Preview the file again and resolve the conflict manually."
                }
                $skippedDuplicates++
                continue
            }

            $newEntry = [PSCustomObject]@{
                entryId             = New-EntryIdentifier
                entryType           = "overtime"
                name                = $EmployeeName
                date                = [string]$entry.date
                punchIn             = [string]$entry.punchIn
                exactPunchIn        = [string]$entry.exactPunchIn
                punchOut            = [string]$entry.punchOut
                exactPunchOut       = [string]$entry.exactPunchOut
                overtime            = [string]$entry.overtime
                status              = [string]$entry.status
                message             = [string]$entry.message
                projectCode         = [string]$entry.projectCode
                overtimeCode        = [string]$entry.overtimeCode
                paymentOption       = [string]$entry.paymentOption
                reasonCode          = [string]$entry.reasonCode
                gc179Rate           = [string]$entry.gc179Rate
                gc179RateField      = [string]$entry.gc179RateField
                gc179RateComponents = @($entry.gc179RateComponents)
                gc179SourceRow      = [int]$entry.sourceRow
                gc179SourceFile     = [System.IO.Path]::GetFileName([string]$SourceFile)
                gc179SourceHash     = [string]$SourceHash
                gc179ImportedAtUtc  = $importedAtUtc
                gc179ImportedBy     = ([string]$ImportedBy).Trim()
                gc179ImportBatchId  = $resolvedBatchId
            }

            $fingerprint = Get-Gc179ImportEntryFingerprint -Entry $newEntry
            Set-Gc179ImportProperty -Value $newEntry -Name "gc179ImportFingerprint" -PropertyValue $fingerprint

            $existingData += $newEntry
            if (-not $existingByBaseKey.ContainsKey($baseKey)) {
                $existingByBaseKey[$baseKey] = New-Object System.Collections.ArrayList
            }
            [void]$existingByBaseKey[$baseKey].Add($newEntry)
            $importedEntryIds += [string]$newEntry.entryId
            $imported++
        }

        if ($imported -gt 0) {
            Write-JsonArrayAtomic -Path $dataFile -Items $existingData -Depth 10
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    $postCommitWarnings = @()
    if ($imported -gt 0 -and $PublishChange) {
        try {
            Publish-DataChange -Category "employee" -Resource $EmployeeCode | Out-Null
        }
        catch {
            $postCommitWarnings += "Entries were saved, but other open SAPHIR windows may need a manual refresh."
        }
    }

    return [PSCustomObject]@{
        batchId               = $resolvedBatchId
        importedCount          = $imported
        skippedDuplicateCount  = $skippedDuplicates
        entryIds               = @($importedEntryIds)
        warnings               = @($postCommitWarnings)
    }
}

function Get-Gc179ImportEntryFingerprint {
    param([Parameter(Mandatory = $true)]$Entry)

    $values = New-Object System.Collections.ArrayList
    foreach ($propertyName in @(
        "entryId", "entryType", "name", "date", "punchIn", "exactPunchIn", "punchOut", "exactPunchOut",
        "overtime", "status", "message", "projectCode", "overtimeCode", "paymentOption", "reasonCode",
        "gc179Rate", "gc179RateField", "gc179SourceRow", "gc179SourceFile", "gc179SourceHash",
        "gc179ImportedAtUtc", "gc179ImportedBy", "gc179ImportBatchId"
    )) {
        $rawPropertyValue = if ($Entry.PSObject.Properties.Name -contains $propertyName) { $Entry.PSObject.Properties[$propertyName].Value } else { $null }
        $propertyValue = if ($rawPropertyValue -is [DateTime]) { ([DateTime]$rawPropertyValue).ToUniversalTime().ToString("o", [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$rawPropertyValue }
        [void]$values.Add(("{0}={1}" -f $propertyName, $propertyValue.Replace("|", "%7C")))
    }

    # Preserve fingerprints written by older releases, while treating a comment
    # added later through entry editing as a material change that blocks undo.
    if ($Entry.PSObject.Properties.Name -contains "workComment") {
        $workComment = [string]$Entry.workComment
        [void]$values.Add(("workComment={0}" -f $workComment.Replace("|", "%7C")))
    }

    [void]$values.Add(("components={0}" -f (Get-Gc179ImportDurationSignature -Entry $Entry)))
    return Get-Gc179ImportSha256 -Value ([string]::Join("|", @($values.ToArray())))
}

function Undo-Gc179ImportBatch {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)]$CurrentUser,
        [bool]$PublishChange = $true
    )

    $normalizedBatchId = ([string]$BatchId).Trim()
    if ($normalizedBatchId -notmatch "^gc179-[0-9a-fA-F]{32}$") {
        throw "Invalid GC179 import batch identifier."
    }

    $dataFile = Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode
    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
    $removedEntryIds = @()
    $removedProjectCodes = @()
    try {
        $existingData = @(Read-Gc179EmployeeDataStrict -Path $dataFile)
        $batchEntries = @($existingData | Where-Object {
            $null -ne $_ -and
            $_.PSObject.Properties.Name -contains "gc179ImportBatchId" -and
            [string]$_.gc179ImportBatchId -eq $normalizedBatchId
        })
        if ($batchEntries.Count -eq 0) {
            throw "GC179 import batch '$normalizedBatchId' was not found for this employee."
        }

        foreach ($entry in $batchEntries) {
            $projectCode = ([string]$entry.projectCode).Trim()
            if (-not (Test-CurrentUserCanModifyProjectCode -CurrentUser $CurrentUser -ProjectCode $projectCode)) {
                throw "You no longer have permission to undo this GC179 batch because it contains project '$projectCode'."
            }

            $entryStatus = ([string]$entry.status).Trim().ToLowerInvariant()
            $employeeRole = Get-EmployeeRoleByCode -EmployeeCode $EmployeeCode
            if ($entryStatus -ne "pending" -and -not (Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $employeeRole)) {
                throw "You do not have permission to undo approved or rejected GC179 entries for this employee role."
            }

            $storedFingerprint = if ($entry.PSObject.Properties.Name -contains "gc179ImportFingerprint") { [string]$entry.gc179ImportFingerprint } else { "" }
            if ([string]::IsNullOrWhiteSpace($storedFingerprint) -or (Get-Gc179ImportEntryFingerprint -Entry $entry) -ne $storedFingerprint) {
                throw "GC179 import batch '$normalizedBatchId' cannot be undone because one or more imported entries were changed after import."
            }
        }

        $remaining = New-Object System.Collections.ArrayList
        foreach ($entry in $existingData) {
            $isBatchEntry = ($null -ne $entry -and $entry.PSObject.Properties.Name -contains "gc179ImportBatchId" -and [string]$entry.gc179ImportBatchId -eq $normalizedBatchId)
            if ($isBatchEntry) {
                $removedEntryIds += [string]$entry.entryId
                $projectCode = ([string]$entry.projectCode).Trim()
                if ($removedProjectCodes -notcontains $projectCode) {
                    $removedProjectCodes += $projectCode
                }
                continue
            }
            [void]$remaining.Add($entry)
        }

        if ($removedEntryIds.Count -gt 0) {
            Write-JsonArrayAtomic -Path $dataFile -Items @($remaining.ToArray()) -Depth 10
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    $postCommitWarnings = @()
    if ($removedEntryIds.Count -gt 0 -and $PublishChange) {
        try {
            Publish-DataChange -Category "employee" -Resource $EmployeeCode | Out-Null
        }
        catch {
            $postCommitWarnings += "The undo was saved, but other open SAPHIR windows may need a manual refresh."
        }
    }

    return [PSCustomObject]@{
        employeeCode = $EmployeeCode
        batchId       = $normalizedBatchId
        undoneCount   = $removedEntryIds.Count
        entryIds      = @($removedEntryIds)
        projectCodes  = @($removedProjectCodes)
        warnings      = @($postCommitWarnings)
    }
}
