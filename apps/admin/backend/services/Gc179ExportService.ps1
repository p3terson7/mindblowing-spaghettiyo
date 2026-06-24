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

function New-Gc179BatchAdobeScript {
    return @'
(function () {
  function geemGc179Pad2(value) {
    value = Number(value);
    if (value < 10) {
      return "0" + value;
    }

    return String(value);
  }

  function geemGc179GetBatchInfo(templatePath) {
    var slashIndex = Math.max(String(templatePath).lastIndexOf("/"), String(templatePath).lastIndexOf("\\"));
    var folderPath = "";
    var fileName = String(templatePath);

    if (slashIndex >= 0) {
      folderPath = String(templatePath).substring(0, slashIndex);
      fileName = String(templatePath).substring(slashIndex + 1);
    }

    var match = fileName.match(/^(gc179-.+-\d{4}-\d{2})-template-of-(\d+)\.pdf$/i);

    if (!match) {
      throw new Error("Ouvrez le PDF inclus dans le ZIP, nomme gc179-...-template-of-XX.pdf.");
    }

    return {
      templatePath: templatePath,
      folderPath: folderPath,
      baseName: match[1],
      partCount: Number(match[2])
    };
  }

  global.geemGc179RunBatch = app.trustedFunction(function (doc) {
    app.beginPriv();

    try {
      if (!doc) {
        throw new Error("Aucun PDF GC179 ouvert.");
      }

      if (!doc.path) {
        throw new Error("Aucun PDF GC179 ouvert.");
      }

      var info = geemGc179GetBatchInfo(doc.path);
      var templatePath = info.templatePath;
      var generatedCount = 0;

      for (var part = 1; part <= info.partCount; part++) {
        var partText = geemGc179Pad2(part);
        var totalText = geemGc179Pad2(info.partCount);
        var fdfPath = info.folderPath + "/" + info.baseName + "-part-" + partText + "-of-" + totalText + ".fdf";
        var outputPath = info.folderPath + "/" + info.baseName + "-filled-part-" + partText + "-of-" + totalText + ".pdf";
        var targetDoc = doc;

        if (part !== 1) {
          targetDoc = app.openDoc({ cPath: templatePath, bHidden: true });
        }

        targetDoc.importAnFDF(fdfPath);
        targetDoc.saveAs({ cPath: outputPath });
        generatedCount += 1;

        if (part !== 1) {
          targetDoc.closeDoc(true);
        }
      }

      app.alert("GC179 termine. " + generatedCount + " PDF genere(s) dans le dossier du ZIP extrait.");
    } catch (error) {
      app.alert("Erreur GC179 batch: " + error);
    }

    app.endPriv();
  });

  try {
    app.addMenuItem({
      cName: "geemGc179Batch",
      cUser: "GEEM - Generer GC179 batch",
      cParent: "File",
      cExec: "global.geemGc179RunBatch(event.target);",
      nPos: 0
    });
  } catch (error) {
    // Acrobat can throw if the menu already exists after a script reload.
  }
})();
'@
}

function New-Gc179BatchInstructions {
    param(
        [Parameter(Mandatory = $true)][string]$TemplateFileName,
        [Parameter(Mandatory = $true)][int]$PartCount
    )

    return @"
Export GC179 - traitement batch Adobe

Ce ZIP contient:
- $TemplateFileName : copie vierge du formulaire GC179.
- Les fichiers .fdf a importer dans le formulaire.
- GEEM_GC179_Batch.js : script Adobe Acrobat pour traiter toutes les parties automatiquement.

Installation du script Adobe, une seule fois:
1. Copiez GEEM_GC179_Batch.js dans le dossier JavaScripts d'Adobe Acrobat.
   Windows:
   C:\Users\VOTRE_NOM\AppData\Roaming\Adobe\Acrobat\DC\JavaScripts

   Mac:
   /Users/VOTRE_NOM/Library/Application Support/Adobe/Acrobat/DC/JavaScripts

2. Fermez completement Adobe Acrobat.
3. Rouvrez Adobe Acrobat.

Utilisation pour cet export:
1. Extrayez tout le contenu du ZIP dans un dossier local.
2. Ouvrez le PDF inclus:
   $TemplateFileName
3. Dans Acrobat, ouvrez le menu Fichier.
4. Cliquez sur:
   GEEM - Generer GC179 batch
5. Acrobat genere $PartCount PDF rempli(s) dans le meme dossier que le ZIP extrait.

Important:
- Ne deplacez pas les fichiers .fdf hors du dossier extrait avant de lancer le script.
- Le script utilise le nom du PDF inclus pour retrouver les FDF automatiquement.
- Aucun chemin de fichier n'a besoin d'etre entre manuellement.
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
    if ($exports.Count -eq 1) {
        $singleExport = $exports[0]
        return [PSCustomObject]@{
            Bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$singleExport.Content)
            ContentType = "application/vnd.fdf"
            FileName = [string]$singleExport.FileName
            EntryCount = $entries.Count
            PartCount = 1
        }
    }

    $templateFileName = "gc179-{0}-{1}-template-of-{2:D2}.pdf" -f $safeEmployeeCode, $monthParts.MonthKey, $exports.Count
    $templatePdfBytes = [System.IO.File]::ReadAllBytes((Get-Gc179TemplatePdfPath))
    $adobeScriptBytes = [System.Text.Encoding]::UTF8.GetBytes((New-Gc179BatchAdobeScript))
    $instructionsBytes = [System.Text.Encoding]::UTF8.GetBytes((New-Gc179BatchInstructions -TemplateFileName $templateFileName -PartCount $exports.Count))
    $additionalEntries = @(
        [PSCustomObject]@{
            FileName = $templateFileName
            Bytes = $templatePdfBytes
        },
        [PSCustomObject]@{
            FileName = "GEEM_GC179_Batch.js"
            Bytes = $adobeScriptBytes
        },
        [PSCustomObject]@{
            FileName = "LIRE-MOI-GC179-BATCH.txt"
            Bytes = $instructionsBytes
        }
    )

    return [PSCustomObject]@{
        Bytes = (New-Gc179ZipArchiveBytes -Exports @($exports.ToArray()) -AdditionalEntries $additionalEntries)
        ContentType = "application/zip"
        FileName = ("gc179-{0}-{1}-parts.zip" -f $safeEmployeeCode, $monthParts.MonthKey)
        EntryCount = $entries.Count
        PartCount = $exports.Count
    }
}
