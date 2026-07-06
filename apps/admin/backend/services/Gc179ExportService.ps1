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

function Get-Gc179HeaderValues {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)]$MonthParts
    )

    $user = Get-EmployeeUserByCode -EmployeeCode $EmployeeCode
    $displayName = if ($null -ne $user -and $user.PSObject.Properties.Name -contains "displayName") {
        [string]$user.displayName
    }
    else {
        [string](Get-EmployeeName $EmployeeCode)
    }

    $profile = if ($null -ne $user) {
        Get-Gc179ProfileFromUserRecord -UserRecord $user
    }
    else {
        ConvertTo-Gc179ProfileObject -Value $null -DisplayName $displayName
    }

    return [PSCustomObject]@{
        Month     = [string]$MonthParts.Month
        Year      = [string]$MonthParts.Year
        Department = "GRC-RCMP"
        Branch    = "CDIV-PTSO-GEEM"
        Paylist   = "0337"
        Group     = "STS"
        SubGroup  = "SUF-00"
        Surname   = [string]$profile.surname
        Given     = [string]$profile.givenName
        Initials  = [string]$profile.initials
        PRI       = ConvertTo-Gc179PriText -Value ([string]$profile.pri)
        Level     = [string]$profile.level
        WorkWeek  = if ($profile.compressedWorkWeek) { "2" } else { "1" }
    }
}

function ConvertTo-Gc179FdfLiteral {
    param([AllowNull()][string]$Value)

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $text = $text.Replace("\", "\\")
    $text = $text.Replace("(", "\(")
    $text = $text.Replace(")", "\)")
    $text = $text.Replace("`r`n", "\r")
    $text = $text.Replace("`r", "\r")
    $text = $text.Replace("`n", "\r")
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

    $safeValueName = ([string]$ValueName).Trim()
    if ($safeValueName -notmatch "^[0-9A-Za-z_.-]+$") {
        $safeValueName = "Off"
    }

    [void]$Builder.AppendLine("<<")
    [void]$Builder.AppendLine("/T ($Name)")
    [void]$Builder.AppendLine("/V /$safeValueName")
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

function ConvertTo-Gc179DurationText {
    param($Entry)

    if ($null -eq $Entry) {
        return ""
    }

    if ($Entry.PSObject.Properties.Name -contains "overtime" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.overtime)) {
        $parts = @(([string]$Entry.overtime).Split(":"))
        if ($parts.Count -ge 2) {
            $hours = 0
            $minutes = 0
            if ([int]::TryParse([string]$parts[0], [ref]$hours) -and [int]::TryParse([string]$parts[1], [ref]$minutes)) {
                return ("{0:D2}:{1:D2}" -f $hours, $minutes)
            }
        }
    }

    try {
        $punchIn = Convert-ToNormalizedTimeText -TimeText ([string]$Entry.punchIn)
        $punchOut = Convert-ToNormalizedTimeText -TimeText ([string]$Entry.punchOut)
        if ([string]::IsNullOrWhiteSpace($punchIn) -or [string]::IsNullOrWhiteSpace($punchOut)) {
            return ""
        }

        $start = [DateTime]::ParseExact(("{0} {1}" -f [string]$Entry.date, $punchIn), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        $end = [DateTime]::ParseExact(("{0} {1}" -f [string]$Entry.date, $punchOut), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        if ($end -le $start) {
            $end = $end.AddDays(1)
        }

        $totalMinutes = [int][math]::Round(($end - $start).TotalMinutes)
        if ($totalMinutes -le 0) {
            return ""
        }

        return ("{0:D2}:{1:D2}" -f ([int][math]::Floor($totalMinutes / 60)), ($totalMinutes % 60))
    }
    catch {
        return ""
    }
}

function Get-Gc179RegularWorkdayFieldName {
    param(
        [Parameter(Mandatory = $true)]$EntryDate,
        [Parameter(Mandatory = $true)][bool]$CompressedWorkWeek,
        [Parameter(Mandatory = $true)]$WorkedDateSet
    )

    if ($CompressedWorkWeek) {
        return "RegTime3Quarter"
    }

    if ($EntryDate.DayOfWeek -eq [System.DayOfWeek]::Sunday) {
        $previousDateKey = $EntryDate.AddDays(-1).ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
        if ($WorkedDateSet -and $WorkedDateSet.ContainsKey($previousDateKey)) {
            return "RegTimeDouble"
        }
    }

    return "RegTimeHalf"
}

function Add-Gc179RegularWorkdayFields {
    param(
        [Parameter(Mandatory = $true)]$Builder,
        [Parameter(Mandatory = $true)][int]$RowIndex,
        [AllowNull()][string]$TargetFieldName,
        [AllowNull()][string]$DurationText
    )

    $fieldNames = @("RegTime", "RegTimeHalf", "RegTime3Quarter", "RegTimeDouble")
    foreach ($fieldName in $fieldNames) {
        $value = if ($fieldName -eq $TargetFieldName) { [string]$DurationText } else { "" }
        Add-Gc179FdfTextField -Builder $Builder -Name ("{0}.{1}" -f $fieldName, $RowIndex) -Value $value
    }
}

function Test-Gc179WorkedDateEntry {
    param($Entry)

    if ($null -eq $Entry) {
        return $false
    }

    $entryDate = [string]$Entry.date
    if ([string]::IsNullOrWhiteSpace($entryDate) -or $entryDate -notmatch "^\d{4}-\d{2}-\d{2}$") {
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

    return (-not [string]::IsNullOrWhiteSpace([string]$Entry.punchIn) -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchOut))
}

function Get-Gc179WorkedDateSet {
    param([Parameter(Mandatory = $true)][string]$EmployeeCode)

    $dataFile = Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode
    $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)
    $workedDateSet = @{}

    foreach ($entry in $entries) {
        if (Test-Gc179WorkedDateEntry -Entry $entry) {
            $workedDateSet[[string]$entry.date] = $true
        }
    }

    return $workedDateSet
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

function New-Gc179FdfExportPart {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)]$MonthParts,
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)]$WorkedDateSet,
        [int]$PartNumber = 1,
        [int]$PartCount = 1
    )

    $entries = @($Entries)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("%FDF-1.2")
    [void]$builder.AppendLine("1 0 obj")
    [void]$builder.AppendLine("<<")
    [void]$builder.AppendLine("/FDF <<")
    [void]$builder.AppendLine("/F ($(ConvertTo-Gc179FdfLiteral -Value "GC179.pdf"))")
    [void]$builder.AppendLine("/Fields [")

    $headerValues = Get-Gc179HeaderValues -EmployeeCode $EmployeeCode -MonthParts $MonthParts
    Add-Gc179FdfTextField -Builder $builder -Name "Month" -Value ([string]$headerValues.Month)
    Add-Gc179FdfTextField -Builder $builder -Name "Year" -Value ([string]$headerValues.Year)
    Add-Gc179FdfTextField -Builder $builder -Name "Department" -Value ([string]$headerValues.Department)
    Add-Gc179FdfTextField -Builder $builder -Name "Branch" -Value ([string]$headerValues.Branch)
    Add-Gc179FdfTextField -Builder $builder -Name "Paylist" -Value ([string]$headerValues.Paylist)
    Add-Gc179FdfTextField -Builder $builder -Name "Group" -Value ([string]$headerValues.Group)
    Add-Gc179FdfTextField -Builder $builder -Name "SubGroup" -Value ([string]$headerValues.SubGroup)
    Add-Gc179FdfTextField -Builder $builder -Name "Surname" -Value ([string]$headerValues.Surname)
    Add-Gc179FdfTextField -Builder $builder -Name "Given" -Value ([string]$headerValues.Given)
    Add-Gc179FdfTextField -Builder $builder -Name "Initials" -Value ([string]$headerValues.Initials)
    Add-Gc179FdfTextField -Builder $builder -Name "PRI" -Value ([string]$headerValues.PRI)
    Add-Gc179FdfTextField -Builder $builder -Name "Level" -Value ([string]$headerValues.Level)
    Add-Gc179FdfNameField -Builder $builder -Name "WorkWeek" -ValueName ([string]$headerValues.WorkWeek)
    $compressedWorkWeek = ([string]$headerValues.WorkWeek -eq "2")

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
                $durationText = ConvertTo-Gc179DurationText -Entry $entry
                $regularWorkdayFieldName = Get-Gc179RegularWorkdayFieldName -EntryDate $entryDate -CompressedWorkWeek $compressedWorkWeek -WorkedDateSet $WorkedDateSet
                Add-Gc179FdfTextField -Builder $builder -Name ("DayofWeek.{0}" -f $index) -Value (ConvertTo-Gc179DayText -Date $entryDate)
                Add-Gc179FdfTextField -Builder $builder -Name ("OTCODE.{0}" -f $index) -Value ([string]$entry.reasonCode)
                Add-Gc179FdfTextField -Builder $builder -Name ("DayWorked.{0}" -f $index) -Value (ConvertTo-Gc179WeekdayText -Date $entryDate)
                Add-Gc179FdfTextField -Builder $builder -Name ("StartTime.{0}" -f $index) -Value (ConvertTo-Gc179TimeText -TimeText ([string]$entry.punchIn))
                Add-Gc179FdfTextField -Builder $builder -Name ("EndTime.{0}" -f $index) -Value (ConvertTo-Gc179TimeText -TimeText ([string]$entry.punchOut))
                Add-Gc179FdfTextField -Builder $builder -Name ("OvertimeCode.{0}" -f $index) -Value ([string]$entry.overtimeCode)
                Add-Gc179RegularWorkdayFields -Builder $builder -RowIndex $index -TargetFieldName $regularWorkdayFieldName -DurationText $durationText
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
        Add-Gc179RegularWorkdayFields -Builder $builder -RowIndex $index -TargetFieldName "" -DurationText ""
        Add-Gc179FdfNameField -Builder $builder -Name (Get-Gc179PaymentFieldName -RowIndex $index) -ValueName "Off"
    }

    [void]$builder.AppendLine("]")
    [void]$builder.AppendLine(">>")
    [void]$builder.AppendLine(">>")
    [void]$builder.AppendLine("endobj")
    [void]$builder.AppendLine("trailer")
    [void]$builder.AppendLine("<< /Root 1 0 R >>")
    [void]$builder.AppendLine("%%EOF")

    $safeEmployeeCode = ([string]$EmployeeCode) -replace "[^0-9A-Za-z_-]", "_"
    $fileName = if ($PartCount -gt 1) {
        "gc179-{0}-{1}-part-{2:D2}-of-{3:D2}.fdf" -f $safeEmployeeCode, $MonthParts.MonthKey, $PartNumber, $PartCount
    }
    else {
        "gc179-{0}-{1}.fdf" -f $safeEmployeeCode, $MonthParts.MonthKey
    }

    return [PSCustomObject]@{
        Content    = $builder.ToString()
        FileName   = $fileName
        RowCount   = $entries.Count
        PartNumber = $PartNumber
        PartCount  = $PartCount
    }
}

function New-Gc179FdfExportSet {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    $monthParts = ConvertTo-Gc179MonthParts -MonthKey $MonthKey
    $entries = @(Get-Gc179ExportEntries -EmployeeCode $EmployeeCode -MonthKey $monthParts.MonthKey)
    $workedDateSet = Get-Gc179WorkedDateSet -EmployeeCode $EmployeeCode
    $partCount = [int][math]::Ceiling($entries.Count / 16.0)
    if ($partCount -lt 1) {
        $partCount = 1
    }

    $exports = New-Object System.Collections.ArrayList
    for ($partIndex = 0; $partIndex -lt $partCount; $partIndex++) {
        $chunk = New-Object System.Collections.ArrayList
        $startIndex = $partIndex * 16
        $endIndex = [math]::Min(($startIndex + 15), ($entries.Count - 1))
        if ($startIndex -le $endIndex) {
            for ($entryIndex = $startIndex; $entryIndex -le $endIndex; $entryIndex++) {
                [void]$chunk.Add($entries[$entryIndex])
            }
        }

        $partExport = New-Gc179FdfExportPart -EmployeeCode $EmployeeCode -MonthParts $monthParts -Entries @($chunk.ToArray()) -WorkedDateSet $workedDateSet -PartNumber ($partIndex + 1) -PartCount $partCount
        [void]$exports.Add($partExport)
    }

    return [PSCustomObject]@{
        MonthParts = $monthParts
        Entries    = @($entries)
        Exports    = @($exports.ToArray())
    }
}

function ConvertTo-Gc179Utf8BomBytes {
    param([Parameter(Mandatory = $true)][string]$Text)

    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $true
    $preamble = $encoding.GetPreamble()
    $contentBytes = $encoding.GetBytes($Text)
    $bytes = New-Object byte[] ($preamble.Length + $contentBytes.Length)
    [System.Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [System.Array]::Copy($contentBytes, 0, $bytes, $preamble.Length, $contentBytes.Length)
    return $bytes
}

function Get-Gc179TemplatePdfPath {
    $templatePath = Join-Path -Path $repoRoot -ChildPath "docs/GC179.pdf"
    if (-not (Test-Path -Path $templatePath -PathType Leaf)) {
        throw "GC179 template not found at docs/GC179.pdf."
    }

    return $templatePath
}

function New-Gc179OpenFdfScript {
    return @'
$ErrorActionPreference = "Stop"

function ConvertTo-Gc179FdfLiteral {
    param([AllowNull()][string]$Value)

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $text = $text.Replace("\", "\\")
    $text = $text.Replace("(", "\(")
    $text = $text.Replace(")", "\)")
    $text = $text.Replace("`r`n", "\r")
    $text = $text.Replace("`r", "\r")
    $text = $text.Replace("`n", "\r")
    return $text
}

function Get-Gc179FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function New-Gc179LaunchFdf {
    param(
        [Parameter(Mandatory = $true)]$FdfFile,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$FdfFile.Name)
    $launchFdfPath = Join-Path -Path $OutputDirectory -ChildPath ("{0}-ouvrir.fdf" -f $baseName)
    $fdfText = [System.IO.File]::ReadAllText([string]$FdfFile.FullName, [System.Text.Encoding]::ASCII)
    $templateDirectory = Split-Path -Path $TemplatePath -Parent
    $partTemplatePath = Join-Path -Path $templateDirectory -ChildPath ("{0}.pdf" -f $baseName)
    $effectiveTemplatePath = if (Test-Path -Path $partTemplatePath -PathType Leaf) {
        $partTemplatePath
    }
    else {
        $TemplatePath
    }
    $templateLiteral = ConvertTo-Gc179FdfLiteral -Value (Get-Gc179FullPath -Path $effectiveTemplatePath)
    $fieldReference = "/F ($templateLiteral)"

    if ($fdfText -match "/F\s*\([^)]*\)") {
        $safeReplacement = $fieldReference.Replace('$', '$$')
        $fdfText = [System.Text.RegularExpressions.Regex]::Replace($fdfText, "/F\s*\([^)]*\)", $safeReplacement, 1)
    }
    else {
        $fdfText = $fdfText -replace "/FDF\s*<<", ("/FDF <<" + [Environment]::NewLine + $fieldReference)
    }

    [System.IO.File]::WriteAllText($launchFdfPath, $fdfText, [System.Text.Encoding]::ASCII)
    return $launchFdfPath
}

function Start-Gc179File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        Start-Process -FilePath $Path | Out-Null
        return
    }

    $openCommand = Get-Command -Name "open" -ErrorAction SilentlyContinue
    if ($null -ne $openCommand) {
        & $openCommand.Source $Path | Out-Null
        return
    }

    Start-Process -FilePath $Path | Out-Null
}

$root = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$templatePath = Join-Path -Path $root -ChildPath "GC179.pdf"
$outputDirectory = Join-Path -Path $root -ChildPath "FDF-ouverture"

if (-not (Test-Path -Path $templatePath -PathType Leaf)) {
    throw "GC179.pdf is missing from the local export folder."
}

if (-not (Test-Path -Path $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$fdfFiles = @(
    Get-ChildItem -Path $root -Filter "gc179-*.fdf" -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.Name -notlike "*-ouvrir.fdf" } |
        Sort-Object Name
)

if ($fdfFiles.Count -lt 1) {
    throw "No GC179 FDF file was found in the local export folder."
}

foreach ($fdfFile in $fdfFiles) {
    $launchFdfPath = New-Gc179LaunchFdf -FdfFile $fdfFile -TemplatePath $templatePath -OutputDirectory $outputDirectory
    Start-Gc179File -Path $launchFdfPath
    Start-Sleep -Milliseconds 1400
}
'@
}

function Get-Gc179LocalExportRoot {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $basePath = [string]$env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($basePath)) {
            $basePath = Join-Path -Path ([System.Environment]::GetFolderPath("LocalApplicationData")) -ChildPath "GEEM"
        }
        else {
            $basePath = Join-Path -Path $basePath -ChildPath "GEEM"
        }

        return (Join-Path -Path $basePath -ChildPath "GC179")
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:HOME)) {
        $basePath = Join-Path -Path ([string]$env:HOME) -ChildPath "Library/Application Support/GEEM"
        return (Join-Path -Path $basePath -ChildPath "GC179")
    }

    $fallbackBasePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "GEEM"
    return (Join-Path -Path $fallbackBasePath -ChildPath "GC179")
}

function Remove-OldGc179LocalExportFolders {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [int]$RetentionDays = 14
    )

    if (-not (Test-Path -Path $RootPath -PathType Container)) {
        return
    }

    $cutoff = (Get-Date).AddDays(-1 * [math]::Max(1, $RetentionDays))
    Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            }
            catch {
            }
        }
}

function New-Gc179LocalExportFolder {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    $safeEmployeeCode = ([string]$EmployeeCode) -replace "[^0-9A-Za-z_-]", "_"
    $safeMonthKey = ([string]$MonthKey) -replace "[^0-9A-Za-z_-]", "_"
    $folderName = "gc179-{0}-{1}-{2}" -f $safeEmployeeCode, $safeMonthKey, (Get-Date).ToString("yyyyMMdd-HHmmss")
    $rootPath = Get-Gc179LocalExportRoot
    if (-not (Test-Path -Path $rootPath -PathType Container)) {
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
    }
    Remove-OldGc179LocalExportFolders -RootPath $rootPath

    $folderPath = Join-Path -Path $rootPath -ChildPath $folderName
    New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    return $folderPath
}

function Write-Gc179LocalExportWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)]$ExportSet
    )

    $templateBytes = [System.IO.File]::ReadAllBytes((Get-Gc179TemplatePdfPath))
    [System.IO.File]::WriteAllBytes((Join-Path -Path $FolderPath -ChildPath "GC179.pdf"), $templateBytes)
    [System.IO.File]::WriteAllBytes((Join-Path -Path $FolderPath -ChildPath "GENERER-GC179.ps1"), (ConvertTo-Gc179Utf8BomBytes -Text (New-Gc179OpenFdfScript)))

    foreach ($export in @($ExportSet.Exports)) {
        $fdfPath = Join-Path -Path $FolderPath -ChildPath ([string]$export.FileName)
        $pdfBaseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$export.FileName)
        $pdfPath = Join-Path -Path $FolderPath -ChildPath ("{0}.pdf" -f $pdfBaseName)
        [System.IO.File]::WriteAllText($fdfPath, [string]$export.Content, [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllBytes($pdfPath, $templateBytes)
    }
}

function Get-Gc179PowerShellExecutable {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $systemRoot = [string]$env:SystemRoot
        if ([string]::IsNullOrWhiteSpace($systemRoot)) {
            $systemRoot = "C:\Windows"
        }

        $candidate = Join-Path -Path $systemRoot -ChildPath "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (Test-Path -Path $candidate -PathType Leaf) {
            return $candidate
        }

        return "powershell.exe"
    }

    $pwsh = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue
    if ($null -ne $pwsh) {
        return [string]$pwsh.Source
    }

    $powershell = Get-Command -Name "powershell" -ErrorAction SilentlyContinue
    if ($null -ne $powershell) {
        return [string]$powershell.Source
    }

    return "pwsh"
}

function Start-Gc179LocalExportWorkspace {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $scriptPath = Join-Path -Path $FolderPath -ChildPath "GENERER-GC179.ps1"
    $stdoutPath = Join-Path -Path $FolderPath -ChildPath "gc179-launch.log"
    $stderrPath = Join-Path -Path $FolderPath -ChildPath "gc179-launch-error.log"
    $powershellPath = Get-Gc179PowerShellExecutable
    $quotedScriptPath = '"' + ([string]$scriptPath).Replace('"', '\"') + '"'
    $argumentList = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
    }
    else {
        "-NoProfile -File $quotedScriptPath"
    }

    $process = $null
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try {
            $process = Start-Process -FilePath $powershellPath -ArgumentList $argumentList -WorkingDirectory $FolderPath -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        }
        catch {
            $process = Start-Process -FilePath $powershellPath -ArgumentList $argumentList -WorkingDirectory $FolderPath -PassThru
        }
    }
    else {
        $process = Start-Process -FilePath $powershellPath -ArgumentList $argumentList -WorkingDirectory $FolderPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    }

    $processId = if ($null -ne $process) { [int]$process.Id } else { 0 }
    return [PSCustomObject]@{
        ProcessId    = $processId
        LogPath      = $stdoutPath
        ErrorLogPath = $stderrPath
    }
}

function Start-Gc179LocalExport {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    $exportSet = New-Gc179FdfExportSet -EmployeeCode $EmployeeCode -MonthKey $MonthKey
    $folderPath = New-Gc179LocalExportFolder -EmployeeCode $EmployeeCode -MonthKey ([string]$exportSet.MonthParts.MonthKey)
    Write-Gc179LocalExportWorkspace -FolderPath $folderPath -ExportSet $exportSet
    $launch = Start-Gc179LocalExportWorkspace -FolderPath $folderPath

    return [PSCustomObject]@{
        launched     = $true
        folderPath   = $folderPath
        logPath      = [string]$launch.LogPath
        errorLogPath = [string]$launch.ErrorLogPath
        processId    = [int]$launch.ProcessId
        entryCount   = @($exportSet.Entries).Count
        partCount    = @($exportSet.Exports).Count
        message      = "GC179 export prepared and launched locally."
    }
}
