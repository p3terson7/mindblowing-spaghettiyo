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

function New-Gc179FdfExportPart {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)]$MonthParts,
        [Parameter(Mandatory = $true)]$Entries,
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
    $fileName = if ($PartCount -gt 1) {
        "gc179-{0}-{1}-part-{2:D2}-of-{3:D2}.fdf" -f $safeEmployeeCode, $MonthParts.MonthKey, $PartNumber, $PartCount
    }
    else {
        "gc179-{0}-{1}.fdf" -f $safeEmployeeCode, $MonthParts.MonthKey
    }

    return [PSCustomObject]@{
        Content = $builder.ToString()
        FileName = $fileName
        RowCount = $entries.Count
        PartNumber = $PartNumber
        PartCount = $PartCount
    }
}

function New-Gc179FdfExport {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    $monthParts = ConvertTo-Gc179MonthParts -MonthKey $MonthKey
    $entries = @(Get-Gc179ExportEntries -EmployeeCode $EmployeeCode -MonthKey $monthParts.MonthKey)
    if ($entries.Count -gt 16) {
        throw ("GC179 only has 16 rows. {0} exportable entries were found for {1}. Use New-Gc179FdfExportPackage for multi-part export." -f $entries.Count, $monthParts.MonthKey)
    }

    return (New-Gc179FdfExportPart -EmployeeCode $EmployeeCode -MonthParts $monthParts -Entries $entries -PartNumber 1 -PartCount 1)
}

function Add-Gc179ZipEntryBytes {
    param(
        [Parameter(Mandatory = $true)]$ZipArchive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $zipEntry = $ZipArchive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $entryStream = $zipEntry.Open()
    try {
        $entryStream.Write($Bytes, 0, $Bytes.Length)
    }
    finally {
        $entryStream.Dispose()
    }
}

function Add-Gc179ZipEntryText {
    param(
        [Parameter(Mandatory = $true)]$ZipArchive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Add-Gc179ZipEntryBytes -ZipArchive $ZipArchive -EntryName $EntryName -Bytes $bytes
}

function Get-Gc179TemplatePdfPath {
    $templatePath = Join-Path -Path $repoRoot -ChildPath "docs/GC179.pdf"
    if (-not (Test-Path -Path $templatePath -PathType Leaf)) {
        throw "GC179 template not found at docs/GC179.pdf."
    }

    return $templatePath
}

function Get-Gc179AcrobatSequenceFileName {
    return "GEEM_GC179.sequ"
}

function New-Gc179AcrobatSequenceContent {
    return @'
<?xml version="1.0" encoding="UTF-8"?>
<Workflow xmlns="http://ns.adobe.com/acrobat/workflow/2012" title="GEEM - GC179" description="Aide-memoire pour traiter les exports GC179 produits par l'application GEEM." majorVersion="1" minorVersion="0">
	<Group label="Traitement GC179">
		<Instruction label="Extrayez le ZIP GC179 telecharge depuis GEEM dans un dossier local." pauseBefore="false"/>
		<Instruction label="Sur Windows, double-cliquez GENERER-GC179.cmd. Le script copie GC179.pdf dans PDF-remplis, importe les FDF dans les copies, puis sauvegarde les PDF remplis." pauseBefore="false"/>
		<Instruction label="Si le script automatique est bloque par le poste, ouvrez GC179.pdf dans Acrobat et importez les fichiers FDF un par un avec l'outil de formulaire." pauseBefore="false"/>
	</Group>
</Workflow>
'@
}

function Get-Gc179AcrobatSequenceDirectory {
    if (-not [string]::IsNullOrWhiteSpace([string]$env:APPDATA)) {
        return (Join-Path -Path ([string]$env:APPDATA) -ChildPath "Adobe\Acrobat\DC\Sequences")
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:HOME)) {
        return (Join-Path -Path ([string]$env:HOME) -ChildPath "Library/Application Support/Adobe/Acrobat/DC/Sequences")
    }

    return $null
}

function Install-Gc179AcrobatSequenceIfNeeded {
    $sequenceDirectory = Get-Gc179AcrobatSequenceDirectory
    if ([string]::IsNullOrWhiteSpace([string]$sequenceDirectory)) {
        return [PSCustomObject]@{
            Installed = $false
            Path      = ""
            Message   = "Adobe Acrobat Sequences folder could not be resolved."
        }
    }

    if (-not (Test-Path -Path $sequenceDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $sequenceDirectory -Force | Out-Null
    }

    $sequencePath = Join-Path -Path $sequenceDirectory -ChildPath (Get-Gc179AcrobatSequenceFileName)
    $content = New-Gc179AcrobatSequenceContent
    $shouldWrite = $true
    if (Test-Path -Path $sequencePath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($sequencePath)
        $shouldWrite = -not [string]::Equals($existing, $content, [System.StringComparison]::Ordinal)
    }

    if ($shouldWrite) {
        [System.IO.File]::WriteAllText($sequencePath, $content, [System.Text.Encoding]::UTF8)
    }

    return [PSCustomObject]@{
        Installed = $shouldWrite
        Path      = $sequencePath
        Message   = "GC179 Acrobat sequence is available."
    }
}

function New-Gc179AdobeAutomationScript {
    return @'
param()

$ErrorActionPreference = "Stop"

function Get-Gc179OperatingSystemName {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return "Windows"
    }

    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS) {
        return "MacOS"
    }

    return "Other"
}

function ConvertTo-Gc179JavaScriptString {
    param([AllowNull()][string]$Value)

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $text = $text.Replace("\", "\\")
    $text = $text.Replace('"', '\"')
    $text = $text.Replace("`r`n", "\n")
    $text = $text.Replace("`r", "\n")
    $text = $text.Replace("`n", "\n")
    return ('"{0}"' -f $text)
}

function Get-Gc179OutputPath {
    param(
        [Parameter(Mandatory = $true)]$FdfFile,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$FdfFile.Name)
    return (Join-Path -Path $OutputDirectory -ChildPath ("{0}-rempli.pdf" -f $baseName))
}

function Get-Gc179WorkingPath {
    param(
        [Parameter(Mandatory = $true)]$FdfFile,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$FdfFile.Name)
    return (Join-Path -Path $OutputDirectory -ChildPath ("{0}-travail.pdf" -f $baseName))
}

function ConvertTo-Gc179FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function ConvertTo-Gc179AcrobatPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = ConvertTo-Gc179FullPath -Path $Path
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT -and $fullPath -match "^([A-Za-z]):\\(.*)$") {
        $drive = $matches[1].ToUpperInvariant()
        $rest = $matches[2] -replace "\\", "/"
        return ("/{0}/{1}" -f $drive, $rest)
    }

    return ($fullPath -replace "\\", "/")
}

function Test-Gc179PdfHeader {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $false
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 5) {
            return $false
        }

        $bytes = New-Object byte[] 5
        [void]$stream.Read($bytes, 0, $bytes.Length)
        return ([System.Text.Encoding]::ASCII.GetString($bytes) -eq "%PDF-")
    }
    finally {
        $stream.Dispose()
    }
}

function New-Gc179WorkingPdf {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$WorkingPath
    )

    Copy-Item -LiteralPath $TemplatePath -Destination $WorkingPath -Force
    if (-not (Test-Gc179PdfHeader -Path $WorkingPath)) {
        throw "La copie de travail du PDF GC179 n'est pas un PDF valide."
    }
}

function Complete-Gc179WorkingPdf {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    if (-not (Test-Gc179PdfHeader -Path $WorkingPath)) {
        throw "Acrobat a produit un fichier invalide. Le modele GC179 original n'a pas ete modifie."
    }

    Move-Item -LiteralPath $WorkingPath -Destination $OutputPath -Force
}

function Invoke-Gc179WindowsAcrobat {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)]$FdfFiles,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    $acroApp = $null
    try {
        $acroApp = New-Object -ComObject AcroExch.App
    }
    catch {
        throw "Impossible de demarrer Acrobat via COM. Verifiez qu'Adobe Acrobat complet est installe sur ce poste."
    }

    $generated = @()
    try {
        foreach ($fdfFile in @($FdfFiles)) {
            $avDoc = $null
            $pdDoc = $null
            $outputPath = Get-Gc179OutputPath -FdfFile $fdfFile -OutputDirectory $OutputDirectory
            $workingPath = Get-Gc179WorkingPath -FdfFile $fdfFile -OutputDirectory $OutputDirectory
            try {
                if (Test-Path -Path $workingPath -PathType Leaf) {
                    Remove-Item -LiteralPath $workingPath -Force
                }
                New-Gc179WorkingPdf -TemplatePath $TemplatePath -WorkingPath $workingPath

                $avDoc = New-Object -ComObject AcroExch.AVDoc
                $opened = $avDoc.Open($workingPath, "")
                if (-not $opened) {
                    throw "Acrobat n'a pas pu ouvrir la copie de travail GC179."
                }

                $pdDoc = $avDoc.GetPDDoc()
                $jsObject = $pdDoc.GetJSObject()

                $jsObject.importAnFDF((ConvertTo-Gc179AcrobatPath -Path ([string]$fdfFile.FullName)))
                $saved = $pdDoc.Save(1, $workingPath)
                if (-not $saved) {
                    throw "Acrobat n'a pas pu sauvegarder la copie de travail GC179."
                }

                $avDoc.Close($true) | Out-Null
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($avDoc) | Out-Null } catch {}
                $avDoc = $null
                Complete-Gc179WorkingPdf -WorkingPath $workingPath -OutputPath $outputPath
                $generated += $outputPath
            }
            finally {
                if ($null -ne $avDoc) {
                    try { $avDoc.Close($true) | Out-Null } catch {}
                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($avDoc) | Out-Null } catch {}
                }
                if ($null -ne $pdDoc) {
                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($pdDoc) | Out-Null } catch {}
                }
                if (Test-Path -Path $workingPath -PathType Leaf) {
                    try { Remove-Item -LiteralPath $workingPath -Force } catch {}
                }
            }
        }
    }
    finally {
        try { $acroApp.Exit() | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($acroApp) | Out-Null } catch {}
    }

    return $generated
}

function Invoke-Gc179MacAcrobat {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)]$FdfFiles,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    $osascript = Get-Command -Name "osascript" -ErrorAction SilentlyContinue
    if ($null -eq $osascript) {
        throw "osascript est introuvable. Lancez ce script sur macOS ou utilisez l'import FDF manuel dans Acrobat."
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("var jobs = [];")
    foreach ($fdfFile in @($FdfFiles)) {
        $outputPath = Get-Gc179OutputPath -FdfFile $fdfFile -OutputDirectory $OutputDirectory
        $workingPath = Get-Gc179WorkingPath -FdfFile $fdfFile -OutputDirectory $OutputDirectory
        if (Test-Path -Path $workingPath -PathType Leaf) {
            Remove-Item -LiteralPath $workingPath -Force
        }
        New-Gc179WorkingPdf -TemplatePath $TemplatePath -WorkingPath $workingPath
        [void]$builder.AppendLine("jobs.push({ pdf: $(ConvertTo-Gc179JavaScriptString -Value (ConvertTo-Gc179AcrobatPath -Path $workingPath)), fdf: $(ConvertTo-Gc179JavaScriptString -Value (ConvertTo-Gc179AcrobatPath -Path ([string]$fdfFile.FullName))), output: $(ConvertTo-Gc179JavaScriptString -Value (ConvertTo-Gc179AcrobatPath -Path $workingPath)) });")
    }
    [void]$builder.AppendLine("for (var i = 0; i < jobs.length; i++) {")
    [void]$builder.AppendLine("  var doc = app.openDoc({ cPath: jobs[i].pdf, bHidden: true });")
    [void]$builder.AppendLine("  doc.importAnFDF(jobs[i].fdf);")
    [void]$builder.AppendLine("  doc.saveAs({ cPath: jobs[i].output });")
    [void]$builder.AppendLine("  doc.closeDoc(true);")
    [void]$builder.AppendLine("}")
    [void]$builder.AppendLine("app.alert('GC179 termine. ' + jobs.length + ' PDF genere(s).');")

    $runnerPath = Join-Path -Path $OutputDirectory -ChildPath "gc179-acrobat-runner.js"
    [System.IO.File]::WriteAllText($runnerPath, $builder.ToString(), [System.Text.Encoding]::UTF8)

    $script = @"
tell application "Adobe Acrobat"
  activate
  do script (read POSIX file "$runnerPath")
end tell
"@
    $script | & $osascript.Source | Out-Null

    $generated = @()
    foreach ($fdfFile in @($FdfFiles)) {
        $outputPath = Get-Gc179OutputPath -FdfFile $fdfFile -OutputDirectory $OutputDirectory
        $workingPath = Get-Gc179WorkingPath -FdfFile $fdfFile -OutputDirectory $OutputDirectory
        Complete-Gc179WorkingPdf -WorkingPath $workingPath -OutputPath $outputPath
        $generated += $outputPath
    }
    return $generated
}

$root = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$templatePath = Join-Path -Path $root -ChildPath "GC179.pdf"
$outputDirectory = Join-Path -Path $root -ChildPath "PDF-remplis"

if (-not (Test-Path -Path $templatePath -PathType Leaf)) {
    throw "GC179.pdf est introuvable dans le dossier extrait."
}

if (-not (Test-Path -Path $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$fdfFiles = @(Get-ChildItem -Path $root -Filter "gc179-*.fdf" | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)
if ($fdfFiles.Count -lt 1) {
    throw "Aucun fichier FDF GC179 n'a ete trouve dans le dossier extrait."
}

Write-Host "Traitement GC179: $($fdfFiles.Count) fichier(s) FDF."
$osName = Get-Gc179OperatingSystemName
if ($osName -eq "Windows") {
    $generated = @(Invoke-Gc179WindowsAcrobat -TemplatePath $templatePath -FdfFiles $fdfFiles -OutputDirectory $outputDirectory)
}
elseif ($osName -eq "MacOS") {
    $generated = @(Invoke-Gc179MacAcrobat -TemplatePath $templatePath -FdfFiles $fdfFiles -OutputDirectory $outputDirectory)
}
else {
    throw "Automatisation non supportee sur ce systeme. Utilisez Acrobat pour importer les FDF manuellement."
}

Write-Host ""
Write-Host "Termine. Fichiers generes:"
foreach ($path in $generated) {
    Write-Host " - $path"
}
'@
}

function New-Gc179AdobeAutomationCmd {
    return @'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GENERER-GC179.ps1"
echo.
pause
'@
}

function New-Gc179ExportInstructions {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey,
        [Parameter(Mandatory = $true)][int]$PartCount
    )

    return @"
Export GC179 - GEEM

Employe : $EmployeeCode
Mois    : $MonthKey

Ce ZIP contient:
- GC179.pdf : copie vierge du formulaire officiel incluse avec l'application.
- gc179-*.fdf : donnees exportees par l'application GEEM.
- GENERER-GC179.cmd : lancement rapide Windows.
- GENERER-GC179.ps1 : script PowerShell qui traite 1 FDF ou plusieurs FDF.
- GEEM_GC179.sequ : action Acrobat installee automatiquement par GEEM au demarrage de l'application.

Utilisation recommandee sur Windows:
1. Extrayez tout le contenu du ZIP dans un dossier local.
2. Fermez les anciens formulaires GC179 ouverts dans Acrobat.
3. Double-cliquez GENERER-GC179.cmd.
4. Les PDF remplis seront crees dans le dossier PDF-remplis.
5. Le fichier GC179.pdf du dossier extrait n'est pas modifie par le script.

Utilisation PowerShell directe:
1. Extrayez le ZIP.
2. Dans le dossier extrait, lancez:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GENERER-GC179.ps1

Pour PowerShell 7 / macOS:
   pwsh ./GENERER-GC179.ps1

Information Acrobat:
- L'application tente d'installer GEEM_GC179.sequ dans le dossier utilisateur Acrobat:
  Windows: AppData\Roaming\Adobe\Acrobat\DC\Sequences
  Mac:     Library/Application Support/Adobe/Acrobat/DC/Sequences
- Acrobat ne fournit pas de commande fiable pour ouvrir un PDF et lancer automatiquement une action .sequ depuis un navigateur.
- Pour aller vite, le fichier GENERER-GC179.cmd/ps1 pilote Acrobat directement et fonctionne pour un formulaire simple ou pour $PartCount formulaires.

Important:
- Gardez GC179.pdf, les FDF et les scripts dans le meme dossier extrait.
- Si vous avez deja un ancien ZIP avec un GC179.pdf impossible a ouvrir, retéléchargez l'export depuis GEEM.
- Si Acrobat ou les politiques du poste bloquent l'automatisation COM, ouvrez GC179.pdf dans Acrobat et importez les FDF manuellement.
- Les entrees rejetees ne sont pas exportees par GEEM.
"@
}

function New-Gc179ZipArchiveBytes {
    param(
        [Parameter(Mandatory = $true)]$Exports,
        $AdditionalEntries = @()
    )

    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    $memoryStream = New-Object System.IO.MemoryStream
    try {
        $zipArchive = New-Object System.IO.Compression.ZipArchive -ArgumentList $memoryStream, ([System.IO.Compression.ZipArchiveMode]::Create), $true
        try {
            foreach ($export in @($Exports)) {
                $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$export.Content)
                Add-Gc179ZipEntryBytes -ZipArchive $zipArchive -EntryName ([string]$export.FileName) -Bytes $bytes
            }

            foreach ($entry in @($AdditionalEntries)) {
                Add-Gc179ZipEntryBytes -ZipArchive $zipArchive -EntryName ([string]$entry.FileName) -Bytes ([byte[]]$entry.Bytes)
            }
        }
        finally {
            $zipArchive.Dispose()
        }

        return $memoryStream.ToArray()
    }
    finally {
        $memoryStream.Dispose()
    }
}

function New-Gc179FdfExportPackage {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$MonthKey
    )

    $monthParts = ConvertTo-Gc179MonthParts -MonthKey $MonthKey
    $entries = @(Get-Gc179ExportEntries -EmployeeCode $EmployeeCode -MonthKey $monthParts.MonthKey)
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

        $partExport = New-Gc179FdfExportPart -EmployeeCode $EmployeeCode -MonthParts $monthParts -Entries @($chunk.ToArray()) -PartNumber ($partIndex + 1) -PartCount $partCount
        [void]$exports.Add($partExport)
    }

    $safeEmployeeCode = ([string]$EmployeeCode) -replace "[^0-9A-Za-z_-]", "_"
    $templatePdfBytes = [System.IO.File]::ReadAllBytes((Get-Gc179TemplatePdfPath))
    $automationScriptBytes = [System.Text.Encoding]::UTF8.GetBytes((New-Gc179AdobeAutomationScript))
    $automationCmdBytes = [System.Text.Encoding]::ASCII.GetBytes((New-Gc179AdobeAutomationCmd))
    $sequenceBytes = [System.Text.Encoding]::UTF8.GetBytes((New-Gc179AcrobatSequenceContent))
    $instructionsBytes = [System.Text.Encoding]::UTF8.GetBytes((New-Gc179ExportInstructions -EmployeeCode $EmployeeCode -MonthKey $monthParts.MonthKey -PartCount $exports.Count))
    $additionalEntries = @(
        [PSCustomObject]@{
            FileName = "GC179.pdf"
            Bytes = $templatePdfBytes
        },
        [PSCustomObject]@{
            FileName = "GENERER-GC179.ps1"
            Bytes = $automationScriptBytes
        },
        [PSCustomObject]@{
            FileName = "GENERER-GC179.cmd"
            Bytes = $automationCmdBytes
        },
        [PSCustomObject]@{
            FileName = (Get-Gc179AcrobatSequenceFileName)
            Bytes = $sequenceBytes
        },
        [PSCustomObject]@{
            FileName = "LIRE-MOI-GC179.txt"
            Bytes = $instructionsBytes
        }
    )

    return [PSCustomObject]@{
        Bytes = (New-Gc179ZipArchiveBytes -Exports @($exports.ToArray()) -AdditionalEntries $additionalEntries)
        ContentType = "application/zip"
        FileName = ("gc179-{0}-{1}.zip" -f $safeEmployeeCode, $monthParts.MonthKey)
        EntryCount = $entries.Count
        PartCount = $exports.Count
    }
}
