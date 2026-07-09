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
        switch ($escaped) {
            "n" { [void]$builder.Append("`n"); $index++; continue }
            "r" { [void]$builder.Append("`r"); $index++; continue }
            "t" { [void]$builder.Append("`t"); $index++; continue }
            "(" { [void]$builder.Append("("); $index++; continue }
            ")" { [void]$builder.Append(")"); $index++; continue }
            "\" { [void]$builder.Append("\"); $index++; continue }
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

function ConvertTo-Gc179ImportDurationText {
    param([AllowNull()][string]$Value)

    $text = ([string]$Value).Trim().Replace(",", ".")
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    $hours = 0.0
    if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$hours)) {
        return ""
    }

    if ($hours -le 0) {
        return ""
    }

    $totalMinutes = [int][math]::Round($hours * 60.0)
    return ("{0:00}:{1:00}:00" -f [math]::Floor($totalMinutes / 60), ($totalMinutes % 60))
}

function Get-Gc179ImportRateInfo {
    param(
        [Parameter(Mandatory = $true)]$Fields,
        [Parameter(Mandatory = $true)][int]$RowIndex
    )

    $rateFields = @(
        @{ Name = "RegTime"; Rate = "1.0" },
        @{ Name = "RegTimeHalf"; Rate = "1.5" },
        @{ Name = "RegTime3Quarter"; Rate = "1.75" },
        @{ Name = "RegTimeDouble"; Rate = "2.0" }
    )

    foreach ($rateField in $rateFields) {
        $value = Get-Gc179ImportField -Fields $Fields -Name ([string]$rateField.Name) -RowIndex $RowIndex
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [PSCustomObject]@{
                FieldName = [string]$rateField.Name
                Rate      = [string]$rateField.Rate
                Value     = [string]$value
            }
        }
    }

    return [PSCustomObject]@{
        FieldName = ""
        Rate      = ""
        Value     = ""
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

    $normalizedStatus = ([string]$Status).Trim().ToLowerInvariant()
    if ($normalizedStatus -ne "approved" -and $normalizedStatus -ne "pending" -and $normalizedStatus -ne "rejected") {
        $normalizedStatus = "approved"
    }

    $entries = @()
    $warnings = @()
    for ($rowIndex = 0; $rowIndex -lt 16; $rowIndex++) {
        $dayText = (Get-Gc179ImportField -Fields $fields -Name "DayofWeek" -RowIndex $rowIndex).Trim()
        $startTime = ConvertTo-Gc179ImportTimeText -Value (Get-Gc179ImportField -Fields $fields -Name "StartTime" -RowIndex $rowIndex)
        $endTime = ConvertTo-Gc179ImportTimeText -Value (Get-Gc179ImportField -Fields $fields -Name "EndTime" -RowIndex $rowIndex)
        $overtimeCode = (Get-Gc179ImportField -Fields $fields -Name "OvertimeCode" -RowIndex $rowIndex).Trim()
        $reasonCode = (Get-Gc179ImportField -Fields $fields -Name "OTCODE" -RowIndex $rowIndex).Trim()
        $paymentOption = Get-Gc179ImportPaymentOption -Value (Get-Gc179ImportField -Fields $fields -Name "Payment" -RowIndex $rowIndex)
        $rateInfo = Get-Gc179ImportRateInfo -Fields $fields -RowIndex $rowIndex

        if ([string]::IsNullOrWhiteSpace($dayText) -and [string]::IsNullOrWhiteSpace($startTime) -and [string]::IsNullOrWhiteSpace($endTime) -and [string]::IsNullOrWhiteSpace($overtimeCode) -and [string]::IsNullOrWhiteSpace($reasonCode)) {
            continue
        }

        $day = 0
        if ($month -lt 1 -or $year -lt 1 -or -not [int]::TryParse($dayText, [ref]$day)) {
            $warnings += "Row $($rowIndex + 1) skipped: invalid date."
            continue
        }

        try {
            $entryDate = Get-Date -Year $year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
        }
        catch {
            $warnings += "Row $($rowIndex + 1) skipped: invalid calendar date."
            continue
        }

        if ([string]::IsNullOrWhiteSpace($startTime) -or [string]::IsNullOrWhiteSpace($endTime)) {
            $warnings += "Row $($rowIndex + 1) skipped: start or end time is missing."
            continue
        }

        $durationText = ConvertTo-Gc179ImportDurationText -Value ([string]$rateInfo.Value)
        if ([string]::IsNullOrWhiteSpace($durationText)) {
            try {
                $start = [DateTime]::ParseExact(("{0} {1}" -f $entryDate.ToString("yyyy-MM-dd"), $startTime), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
                $end = [DateTime]::ParseExact(("{0} {1}" -f $entryDate.ToString("yyyy-MM-dd"), $endTime), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
                if ($end -le $start) {
                    $end = $end.AddDays(1)
                }
                $durationText = ($end - $start).ToString("hh\:mm\:ss")
            }
            catch {
                $durationText = ""
            }
        }

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
        }
    }

    $monthKey = ""
    if ($month -ge 1 -and $year -ge 1) {
        $monthKey = ("{0:0000}-{1:00}" -f $year, $month)
    }

    return [PSCustomObject]@{
        kind        = "gc179-import-preview"
        sourceFile  = [string]$FileName
        employeeCode = [string]$EmployeeCode
        projectCode = ([string]$ProjectCode).Trim()
        fieldCount  = $fields.Count
        monthKey    = $monthKey
        header      = [PSCustomObject]@{
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
        entryCount  = @($entries).Count
        entries     = @($entries)
        warnings    = @($warnings)
    }
}

function Get-Gc179ImportDuplicateKey {
    param($Entry)

    return ("{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f [string]$Entry.date, [string]$Entry.punchIn, [string]$Entry.punchOut, [string]$Entry.projectCode, [string]$Entry.overtimeCode, [string]$Entry.paymentOption, [string]$Entry.reasonCode)
}

function Import-Gc179PreviewEntries {
    param(
        [Parameter(Mandatory = $true)]$Preview,
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [AllowNull()][string]$SourceFile,
        [bool]$SkipDuplicates = $true
    )

    $dataFile = Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode
    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
    try {
        $existingData = @(Read-JsonArrayFile -Path $dataFile)
        $existingKeys = @{}
        foreach ($existingEntry in $existingData) {
            if ($null -ne $existingEntry) {
                $existingKeys[(Get-Gc179ImportDuplicateKey -Entry $existingEntry)] = $true
            }
        }

        $imported = 0
        $skippedDuplicates = 0
        $importedEntryIds = @()
        foreach ($entry in @($Preview.entries)) {
            $duplicateKey = Get-Gc179ImportDuplicateKey -Entry $entry
            if ($SkipDuplicates -and $existingKeys.ContainsKey($duplicateKey)) {
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
                gc179SourceRow      = [int]$entry.sourceRow
                gc179SourceFile     = [string]$SourceFile
                gc179ImportedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
            }

            $existingData += $newEntry
            $existingKeys[$duplicateKey] = $true
            $importedEntryIds += [string]$newEntry.entryId
            $imported++
        }

        Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 8
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    Publish-DataChange -Category "employee" -Resource $EmployeeCode

    return [PSCustomObject]@{
        importedCount          = $imported
        skippedDuplicateCount  = $skippedDuplicates
        entryIds               = @($importedEntryIds)
    }
}
