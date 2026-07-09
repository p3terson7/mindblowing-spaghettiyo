param(
    [string]$Path = "",

    [string]$EmployeeCode = "",

    [switch]$SkipUserValidation,

    [string]$OutputPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-DefaultGc179ImportPath {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $candidates = @(
        (Join-Path $repoRoot "scripts/gc179-000100001-2026-05.fdf")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "No default GC179 FDF was found. Export a GC179 to FDF from Acrobat, then pass it with -Path."
}

function ConvertFrom-FdfLiteral {
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
            "b" { [void]$builder.Append([char]8); $index++; continue }
            "f" { [void]$builder.Append([char]12); $index++; continue }
            "(" { [void]$builder.Append("("); $index++; continue }
            ")" { [void]$builder.Append(")"); $index++; continue }
            "\" { [void]$builder.Append("\"); $index++; continue }
        }

        if ($escaped -match "[0-7]") {
            $octal = [string]$escaped
            $lookahead = $index + 1
            while ($lookahead -lt $text.Length -and $octal.Length -lt 3 -and $text[$lookahead] -match "[0-7]") {
                $octal += [string]$text[$lookahead]
                $lookahead++
            }

            try {
                [void]$builder.Append([char][Convert]::ToInt32($octal, 8))
            }
            catch {
                [void]$builder.Append($octal)
            }
            $index = $lookahead
            continue
        }

        [void]$builder.Append($escaped)
        $index++
    }

    return $builder.ToString()
}

function ConvertFrom-FdfName {
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

function ConvertFrom-FdfValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $trimmed = ([string]$Value).Trim()
    if ($trimmed.StartsWith("(")) {
        return ConvertFrom-FdfLiteral -Value $trimmed
    }

    if ($trimmed.StartsWith("/")) {
        return ConvertFrom-FdfName -Value $trimmed
    }

    return $trimmed
}

function Read-Gc179FdfFields {
    param([Parameter(Mandatory = $true)][string]$FdfPath)

    $resolvedPath = (Resolve-Path -LiteralPath $FdfPath).Path
    $content = [System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)
    $fields = @{}

    $fieldPattern = "(?s)/T\s*(?<name>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+).*?/V\s*(?<value>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+|[^\s<>\[\]]+)"
    foreach ($match in [regex]::Matches($content, $fieldPattern)) {
        $name = ConvertFrom-FdfValue -Value $match.Groups["name"].Value
        $value = ConvertFrom-FdfValue -Value $match.Groups["value"].Value
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $fields[$name] = $value
        }
    }

    $kidsPattern = "(?s)/Kids\s*\[(?<kids>.*?)\]\s*/T\s*(?<parent>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+)"
    foreach ($groupMatch in [regex]::Matches($content, $kidsPattern)) {
        $parentName = ConvertFrom-FdfValue -Value $groupMatch.Groups["parent"].Value
        if ([string]::IsNullOrWhiteSpace($parentName)) {
            continue
        }

        $kidsContent = $groupMatch.Groups["kids"].Value
        $childPattern = "(?s)<<\s*/T\s*(?<child>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+)(\s*/V\s*(?<value>\((\\.|[^\\)])*\)|/[^\s<>\[\]]+|[^\s<>\[\]]+))?"
        foreach ($childMatch in [regex]::Matches($kidsContent, $childPattern)) {
            $childName = ConvertFrom-FdfValue -Value $childMatch.Groups["child"].Value
            if ([string]::IsNullOrWhiteSpace($childName)) {
                continue
            }

            $fieldName = "{0}.{1}" -f $parentName, $childName
            $value = ""
            if ($childMatch.Groups["value"].Success) {
                $value = ConvertFrom-FdfValue -Value $childMatch.Groups["value"].Value
            }
            $fields[$fieldName] = $value
        }
    }

    return $fields
}

function Get-Gc179Field {
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

function ConvertTo-Gc179MonthNumber {
    param([AllowNull()][string]$Value)

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 0
    }

    $month = 0
    if ([int]::TryParse($text, [ref]$month) -and $month -ge 1 -and $month -le 12) {
        return $month
    }

    $lookup = @{
        "jan" = 1; "january" = 1; "janvier" = 1
        "feb" = 2; "february" = 2; "fevrier" = 2; "février" = 2
        "mar" = 3; "march" = 3; "mars" = 3
        "apr" = 4; "april" = 4; "avril" = 4
        "may" = 5; "mai" = 5
        "jun" = 6; "june" = 6; "juin" = 6
        "jul" = 7; "july" = 7; "juillet" = 7
        "aug" = 8; "august" = 8; "aout" = 8; "août" = 8
        "sep" = 9; "sept" = 9; "september" = 9; "septembre" = 9
        "oct" = 10; "october" = 10; "octobre" = 10
        "nov" = 11; "november" = 11; "novembre" = 11
        "dec" = 12; "december" = 12; "decembre" = 12; "décembre" = 12
    }

    $key = $text.ToLowerInvariant()
    if ($lookup.ContainsKey($key)) {
        return [int]$lookup[$key]
    }

    return 0
}

function ConvertTo-NormalizedGc179Time {
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

function ConvertTo-OvertimeTextFromHours {
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
    $hourPart = [math]::Floor($totalMinutes / 60)
    $minutePart = $totalMinutes % 60
    return ("{0:00}:{1:00}:00" -f $hourPart, $minutePart)
}

function ConvertTo-OvertimeTextFromTimes {
    param(
        [AllowNull()][string]$DateText,
        [AllowNull()][string]$StartTime,
        [AllowNull()][string]$EndTime
    )

    if ([string]::IsNullOrWhiteSpace($DateText) -or [string]::IsNullOrWhiteSpace($StartTime) -or [string]::IsNullOrWhiteSpace($EndTime)) {
        return ""
    }

    try {
        $start = [DateTime]::ParseExact(("{0} {1}" -f $DateText, $StartTime), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        $end = [DateTime]::ParseExact(("{0} {1}" -f $DateText, $EndTime), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        if ($end -le $start) {
            $end = $end.AddDays(1)
        }

        $minutes = [int][math]::Round(($end - $start).TotalMinutes)
        if ($minutes -le 0) {
            return ""
        }

        return ("{0:00}:{1:00}:00" -f [math]::Floor($minutes / 60), ($minutes % 60))
    }
    catch {
        return ""
    }
}

function Get-Gc179RateInfo {
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
        $value = Get-Gc179Field -Fields $Fields -Name ([string]$rateField.Name) -RowIndex $RowIndex
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [PSCustomObject]@{
                FieldName = [string]$rateField.Name
                Rate     = [string]$rateField.Rate
                Value    = [string]$value
            }
        }
    }

    return [PSCustomObject]@{
        FieldName = ""
        Rate     = ""
        Value    = ""
    }
}

function Get-Gc179PaymentOption {
    param([AllowNull()][string]$Value)

    $normalized = ([string]$Value).Trim().TrimStart("/")
    switch ($normalized) {
        "1" { return "cash" }
        "2" { return "leave" }
        default { return "" }
    }
}

function Get-Gc179WorkWeek {
    param([AllowNull()][string]$Value)

    $normalized = ([string]$Value).Trim().TrimStart("/")
    switch ($normalized) {
        "1" { return "standard" }
        "2" { return "compressed" }
        default { return "" }
    }
}

function Get-Gc179IdentityFromFileName {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $result = [ordered]@{
        EmployeeCode = ""
        Surname      = ""
        GivenName    = ""
    }

    if ($baseName -match "^(?<code>\d+)_+(?<surname>[^_]+)_+(?<given>[^_]+)_+GC179") {
        $result.EmployeeCode = $Matches["code"]
        $result.Surname = $Matches["surname"]
        $result.GivenName = $Matches["given"]
    }
    elseif ($baseName -match "^gc179-(?<code>\d+)-\d{4}-\d{2}") {
        $result.EmployeeCode = $Matches["code"]
    }

    return $result
}

function Get-SaphirUserByEmployeeCode {
    param([AllowNull()][string]$TargetEmployeeCode)

    $code = ([string]$TargetEmployeeCode).Trim()
    if ([string]::IsNullOrWhiteSpace($code)) {
        return $null
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $usersPath = Join-Path $repoRoot "data/users.json"
    if (-not (Test-Path -LiteralPath $usersPath)) {
        return $null
    }

    try {
        $users = Get-Content -LiteralPath $usersPath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }

    foreach ($user in @($users)) {
        $userEmployeeCode = ""
        $username = ""
        if ($user.PSObject.Properties.Name -contains "employeeCode") {
            $userEmployeeCode = ([string]$user.employeeCode).Trim()
        }
        if ($user.PSObject.Properties.Name -contains "username") {
            $username = ([string]$user.username).Trim()
        }

        if ($userEmployeeCode -eq $code -or $username -eq $code) {
            return $user
        }
    }

    return $null
}

$resolvedPath = ""
if ([string]::IsNullOrWhiteSpace($Path)) {
    $resolvedPath = Get-DefaultGc179ImportPath
}
else {
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
}

$extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
$sourceKind = ""
if ($extension -eq ".fdf") {
    $sourceKind = "fdf"
    $fields = Read-Gc179FdfFields -FdfPath $resolvedPath
}
elseif ($extension -eq ".pdf") {
    throw "Direct PDF import is disabled for this no-Python prototype. Export the GC179 form data to an FDF file from Acrobat, then run this script with -Path your-file.fdf."
}
else {
    throw "Unsupported GC179 import source '$extension'. Use an FDF file."
}

if ($fields.Count -eq 0) {
    throw "No form fields could be read from $resolvedPath. The PDF may be flattened/scanned, or the FDF may not contain field data."
}

$month = ConvertTo-Gc179MonthNumber -Value (Get-Gc179Field -Fields $fields -Name "Month")
$yearText = (Get-Gc179Field -Fields $fields -Name "Year").Trim()
$year = 0
if (-not [int]::TryParse($yearText, [ref]$year)) {
    $year = 0
}

$fileIdentity = Get-Gc179IdentityFromFileName -SourcePath $resolvedPath
$targetEmployeeCode = ([string]$EmployeeCode).Trim()
if ([string]::IsNullOrWhiteSpace($targetEmployeeCode)) {
    $targetEmployeeCode = ([string]$fileIdentity.EmployeeCode).Trim()
}

if ([string]::IsNullOrWhiteSpace($targetEmployeeCode)) {
    throw "No target employee was specified. Run the script with -EmployeeCode 000100001, or name the FDF with an employee code."
}

$targetUser = Get-SaphirUserByEmployeeCode -TargetEmployeeCode $targetEmployeeCode
if ($null -eq $targetUser -and -not $SkipUserValidation) {
    throw "EmployeeCode '$targetEmployeeCode' was not found in data/users.json. Use an existing SAPHIR employee code, or add -SkipUserValidation for a preview only."
}

$targetUsername = ""
$targetDisplayName = ""
if ($null -ne $targetUser) {
    if ($targetUser.PSObject.Properties.Name -contains "username") {
        $targetUsername = [string]$targetUser.username
    }
    if ($targetUser.PSObject.Properties.Name -contains "displayName") {
        $targetDisplayName = [string]$targetUser.displayName
    }
}

$entries = @()
$skippedRows = @()

for ($rowIndex = 0; $rowIndex -lt 16; $rowIndex++) {
    $dayText = (Get-Gc179Field -Fields $fields -Name "DayofWeek" -RowIndex $rowIndex).Trim()
    $startTime = ConvertTo-NormalizedGc179Time -Value (Get-Gc179Field -Fields $fields -Name "StartTime" -RowIndex $rowIndex)
    $endTime = ConvertTo-NormalizedGc179Time -Value (Get-Gc179Field -Fields $fields -Name "EndTime" -RowIndex $rowIndex)
    $overtimeCode = (Get-Gc179Field -Fields $fields -Name "OvertimeCode" -RowIndex $rowIndex).Trim()
    $reasonCode = (Get-Gc179Field -Fields $fields -Name "OTCODE" -RowIndex $rowIndex).Trim()
    $paymentOption = Get-Gc179PaymentOption -Value (Get-Gc179Field -Fields $fields -Name "Payment" -RowIndex $rowIndex)
    $rateInfo = Get-Gc179RateInfo -Fields $fields -RowIndex $rowIndex

    if ([string]::IsNullOrWhiteSpace($dayText) -and [string]::IsNullOrWhiteSpace($startTime) -and [string]::IsNullOrWhiteSpace($endTime) -and [string]::IsNullOrWhiteSpace($overtimeCode) -and [string]::IsNullOrWhiteSpace($reasonCode)) {
        continue
    }

    $day = 0
    if ($month -lt 1 -or $year -lt 1 -or -not [int]::TryParse($dayText, [ref]$day)) {
        $skippedRows += [PSCustomObject]@{
            row    = $rowIndex
            reason = "Missing or invalid year/month/day."
        }
        continue
    }

    try {
        $entryDate = Get-Date -Year $year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
    }
    catch {
        $skippedRows += [PSCustomObject]@{
            row    = $rowIndex
            reason = "Invalid calendar date."
        }
        continue
    }

    $dateText = $entryDate.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    $overtimeText = ConvertTo-OvertimeTextFromHours -Value ([string]$rateInfo.Value)
    if ([string]::IsNullOrWhiteSpace($overtimeText)) {
        $overtimeText = ConvertTo-OvertimeTextFromTimes -DateText $dateText -StartTime $startTime -EndTime $endTime
    }

    $entries += [PSCustomObject]@{
        entryType          = "overtime"
        date               = $dateText
        punchIn            = $startTime
        punchOut           = $endTime
        exactPunchIn       = $startTime
        exactPunchOut      = $endTime
        overtime           = $overtimeText
        status             = "approved"
        projectCode        = ""
        overtimeCode       = $overtimeCode
        paymentOption      = $paymentOption
        reasonCode         = $reasonCode
        managerMessage     = ""
        source             = "gc179-fdf-import-test"
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

$result = [ordered]@{
    kind        = "gc179-import-preview"
    generatedAt = (Get-Date).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
    sourcePath  = $resolvedPath
    sourceKind  = $sourceKind
    fieldCount  = $fields.Count
    monthKey    = $monthKey
    employeeCodeFromFileName = $fileIdentity.EmployeeCode
    targetEmployeeCode = $targetEmployeeCode
    targetUsername = $targetUsername
    targetDisplayName = $targetDisplayName
    header      = [ordered]@{
        month      = Get-Gc179Field -Fields $fields -Name "Month"
        year       = Get-Gc179Field -Fields $fields -Name "Year"
        surname    = Get-Gc179Field -Fields $fields -Name "Surname"
        givenName  = Get-Gc179Field -Fields $fields -Name "Given"
        initials   = Get-Gc179Field -Fields $fields -Name "Initials"
        pri        = Get-Gc179Field -Fields $fields -Name "PRI"
        department = Get-Gc179Field -Fields $fields -Name "Department"
        branch     = Get-Gc179Field -Fields $fields -Name "Branch"
        payList    = Get-Gc179Field -Fields $fields -Name "Paylist"
        group      = Get-Gc179Field -Fields $fields -Name "Group"
        subGroup   = Get-Gc179Field -Fields $fields -Name "SubGroup"
        position   = Get-Gc179Field -Fields $fields -Name "Group"
        level      = Get-Gc179Field -Fields $fields -Name "Level"
        workWeek   = Get-Gc179WorkWeek -Value (Get-Gc179Field -Fields $fields -Name "WorkWeek")
    }
    importNotes = @(
        "This is a preview-only prototype. It does not write to app data.",
        "GC179 does not contain SAPHIR project codes, so projectCode is left blank.",
        "GC179 does not contain manager notes, entry ids, or original exact clock timestamps.",
        "Rows are treated as approved because a completed GC179 is assumed to be historical validated data."
    )
    entryCount  = @($entries).Count
    entries     = @($entries)
    skippedRows = @($skippedRows)
}

$json = $result | ConvertTo-Json -Depth 12
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = $OutputPath
    if (-not [System.IO.Path]::IsPathRooted($resolvedOutputPath)) {
        $resolvedOutputPath = Join-Path (Get-Location).Path $resolvedOutputPath
    }

    $parent = Split-Path -Parent $resolvedOutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutputPath -Value $json -Encoding UTF8
    Write-Host ("GC179 import preview written: {0}" -f $resolvedOutputPath)
    Write-Host ("Entries reconstructed: {0}" -f @($entries).Count)
}
else {
    $json
}
