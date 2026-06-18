function ConvertTo-Gc179MonthParts {
    param([Parameter(Mandatory = $true)][string]$MonthKey)

    $normalized = ([string]$MonthKey).Trim()
    if ($normalized -notmatch "^\d{4}-\d{2}$") {
        throw "Month must use YYYY-MM format."
    }

    $year = [int]$normalized.Substring(0, 4)
    $month = [int]$normalized.Substring(5, 2)
    if ($month -lt 1 -or $month -gt 12) {
        throw "Month must be between 01 and 12."
    }

    return [PSCustomObject]@{
        MonthKey = $normalized
        Year     = $year
        Month    = $month
    }
}

function ConvertTo-Gc179FdfLiteral {
    param([AllowNull()][string]$Value)

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $text = $text -replace "\\", "\\"
    $text = $text -replace "\(", "\("
    $text = $text -replace "\)", "\)"
    $text = $text -replace "`r`n", "\r"
    $text = $text -replace "`n", "\r"
    $text = $text -replace "`r", "\r"
    return $text
}

function Add-Gc179FdfTextField {
    param(
        [Parameter(Mandatory = $true)]$Builder,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value
    )

    [void]$Builder.AppendLine("<<")
    [void]$Builder.AppendLine("/T ($Name)")
    [void]$Builder.AppendLine("/V ($(ConvertTo-Gc179FdfLiteral -Value $Value))")
    [void]$Builder.AppendLine(">>")
}

function Add-Gc179FdfNameField {
    param(
        [Parameter(Mandatory = $true)]$Builder,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ValueName
    )

    [void]$Builder.AppendLine("<<")
    [void]$Builder.AppendLine("/T ($Name)")
    [void]$Builder.AppendLine("/V /$ValueName")
    [void]$Builder.AppendLine(">>")
}

function Get-Gc179PaymentFieldName {
    param([Parameter(Mandatory = $true)][int]$RowIndex)

    if ($RowIndex -eq 0) {
        return "Payment"
    }

    return ("Payment{0}" -f $RowIndex)
}

function Get-Gc179PaymentValueName {
    param([AllowNull()][string]$PaymentOption)

    $normalized = ([string]$PaymentOption).Trim().ToLowerInvariant()
    if ($normalized -eq "cash" -or $normalized -eq "en espece" -or $normalized -eq "en espèce") {
        return "1"
    }

    if ($normalized -eq "leave" -or $normalized -eq "conge" -or $normalized -eq "congé") {
        return "2"
    }

    return "1"
}

function ConvertTo-Gc179TimeText {
    param([AllowNull()][string]$TimeText)

    $normalized = Convert-ToNormalizedTimeText -TimeText ([string]$TimeText)
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    return $normalized.Substring(0, 5)
}

function ConvertTo-Gc179DayText {
    param([Parameter(Mandatory = $true)][DateTime]$Date)

    return $Date.ToString("dd", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-Gc179WeekdayText {
    param([Parameter(Mandatory = $true)][DateTime]$Date)

    switch ($Date.DayOfWeek) {
        "Monday" { return "Mon" }
        "Tuesday" { return "Tue" }
        "Wednesday" { return "Wed" }
        "Thursday" { return "Thu" }
        "Friday" { return "Fri" }
        "Saturday" { return "Sat" }
        "Sunday" { return "Sun" }
        default { return "" }
    }
}

function Test-Gc179ExportableEntry {
    param(
        $Entry,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    if ($null -eq $Entry) {
        return $false
    }

    $entryDate = [string]$Entry.date
    if ([string]::IsNullOrWhiteSpace($entryDate) -or -not $entryDate.StartsWith($MonthKey, [System.StringComparison]::Ordinal)) {
        return $false
    }

    $status = ([string]$Entry.status).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = "pending"
    }
    if ($status -eq "rejected") {
        return $false
    }

    $entryType = "overtime"
    if ($Entry.PSObject.Properties.Name -contains "entryType" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.entryType)) {
        $entryType = ([string]$Entry.entryType).Trim().ToLowerInvariant()
    }
    if ($entryType -eq "diverse") {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace([string]$Entry.punchIn) -or [string]::IsNullOrWhiteSpace([string]$Entry.punchOut)) {
        return $false
    }

    return $true
}

function Get-Gc179EntrySortKey {
    param($Entry)

    try {
        return [DateTime]::ParseExact(("{0} {1}" -f $Entry.date, $Entry.punchIn), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        try {
            return [DateTime]::ParseExact(("{0} {1}" -f $Entry.date, $Entry.punchIn), "yyyy-MM-dd HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            return [DateTime]::MinValue
        }
    }
}

function Get-Gc179ExportEntries {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    $dataFile = Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode
    $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)
    return @(
        $entries |
            Where-Object { Test-Gc179ExportableEntry -Entry $_ -MonthKey $MonthKey } |
            Sort-Object @{ Expression = { Get-Gc179EntrySortKey -Entry $_ } }
    )
}

function New-Gc179FdfExport {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    $monthParts = ConvertTo-Gc179MonthParts -MonthKey $MonthKey
    $entries = @(Get-Gc179ExportEntries -EmployeeCode $EmployeeCode -MonthKey $monthParts.MonthKey)
    if ($entries.Count -gt 16) {
        throw ("GC179 only has 16 rows. {0} exportable entries were found for {1}." -f $entries.Count, $monthParts.MonthKey)
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("%FDF-1.2")
    [void]$builder.AppendLine("1 0 obj")
    [void]$builder.AppendLine("<<")
    [void]$builder.AppendLine("/FDF <<")
    [void]$builder.AppendLine("/Fields [")

    Add-Gc179FdfTextField -Builder $builder -Name "Month" -Value ([string]$monthParts.Month)
    Add-Gc179FdfTextField -Builder $builder -Name "Year" -Value ([string]$monthParts.Year)

    for ($index = 0; $index -lt 16; $index++) {
        if ($index -lt $entries.Count) {
            $entry = $entries[$index]
            try {
                $entryDate = [DateTime]::ParseExact([string]$entry.date, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
            }
            catch {
                $entryDate = $null
            }

            if ($null -ne $entryDate) {
                Add-Gc179FdfTextField -Builder $builder -Name ("DayofWeek.{0}" -f $index) -Value (ConvertTo-Gc179DayText -Date $entryDate)
                Add-Gc179FdfTextField -Builder $builder -Name ("OTCODE.{0}" -f $index) -Value ([string]$entry.reasonCode)
                Add-Gc179FdfTextField -Builder $builder -Name ("DayWorked.{0}" -f $index) -Value (ConvertTo-Gc179WeekdayText -Date $entryDate)
                Add-Gc179FdfTextField -Builder $builder -Name ("StartTime.{0}" -f $index) -Value (ConvertTo-Gc179TimeText -TimeText ([string]$entry.punchIn))
                Add-Gc179FdfTextField -Builder $builder -Name ("EndTime.{0}" -f $index) -Value (ConvertTo-Gc179TimeText -TimeText ([string]$entry.punchOut))
                Add-Gc179FdfTextField -Builder $builder -Name ("OvertimeCode.{0}" -f $index) -Value ([string]$entry.overtimeCode)
                Add-Gc179FdfNameField -Builder $builder -Name (Get-Gc179PaymentFieldName -RowIndex $index) -ValueName (Get-Gc179PaymentValueName -PaymentOption ([string]$entry.paymentOption))
                continue
            }
        }

        Add-Gc179FdfTextField -Builder $builder -Name ("DayofWeek.{0}" -f $index) -Value ""
        Add-Gc179FdfTextField -Builder $builder -Name ("OTCODE.{0}" -f $index) -Value ""
        Add-Gc179FdfTextField -Builder $builder -Name ("DayWorked.{0}" -f $index) -Value ""
        Add-Gc179FdfTextField -Builder $builder -Name ("StartTime.{0}" -f $index) -Value ""
        Add-Gc179FdfTextField -Builder $builder -Name ("EndTime.{0}" -f $index) -Value ""
        Add-Gc179FdfTextField -Builder $builder -Name ("OvertimeCode.{0}" -f $index) -Value ""
        Add-Gc179FdfNameField -Builder $builder -Name (Get-Gc179PaymentFieldName -RowIndex $index) -ValueName "0"
    }

    [void]$builder.AppendLine("]")
    [void]$builder.AppendLine(">>")
    [void]$builder.AppendLine(">>")
    [void]$builder.AppendLine("endobj")
    [void]$builder.AppendLine("trailer")
    [void]$builder.AppendLine("<< /Root 1 0 R >>")
    [void]$builder.AppendLine("%%EOF")

    $safeEmployeeCode = ([string]$EmployeeCode) -replace "[^0-9A-Za-z_-]", "_"
    return [PSCustomObject]@{
        Content = $builder.ToString()
        FileName = ("gc179-{0}-{1}.fdf" -f $safeEmployeeCode, $monthParts.MonthKey)
        RowCount = $entries.Count
    }
}
