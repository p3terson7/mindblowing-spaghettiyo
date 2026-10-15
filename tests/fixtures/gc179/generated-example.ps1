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

function Write-Gc179Log {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host ("[GC179] {0}" -f $Message)
}

function Invoke-Gc179Operation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        return (& $ScriptBlock)
    }
    catch {
        throw ("{0} a echoue. {1}" -f $Name, $_.Exception.Message)
    }
}

function Invoke-Gc179FdfImport {
    param(
        [Parameter(Mandatory = $true)]$JsObject,
        [Parameter(Mandatory = $true)][string]$FdfPath
    )

    $fullPath = ConvertTo-Gc179FullPath -Path $FdfPath
    $acrobatPath = ConvertTo-Gc179AcrobatPath -Path $FdfPath
    $attempts = @($fullPath, $acrobatPath)
    $lastError = $null

    foreach ($candidate in $attempts) {
        try {
            $JsObject.importAnFDF([string]$candidate)
            return
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    throw ("Acrobat n'a pas pu importer le FDF. Chemin Windows: {0}. Chemin Acrobat: {1}. Derniere erreur: {2}" -f $fullPath, $acrobatPath, $lastError)
}

function Save-Gc179PDDoc {
    param(
        [Parameter(Mandatory = $true)]$PDDoc,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = ConvertTo-Gc179FullPath -Path $Path
    $acrobatPath = ConvertTo-Gc179AcrobatPath -Path $Path
    $attempts = @($fullPath, $acrobatPath)
    $lastError = $null

    foreach ($candidate in $attempts) {
        try {
            $saved = $PDDoc.Save(1, [string]$candidate)
            if ($saved) {
                return
            }

            $lastError = "Acrobat a retourne False."
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    throw ("Acrobat n'a pas pu sauvegarder le PDF. Chemin Windows: {0}. Chemin Acrobat: {1}. Derniere erreur: {2}" -f $fullPath, $acrobatPath, $lastError)
}

function Invoke-Gc179WindowsFdfFallback {
    param(
        [Parameter(Mandatory = $true)]$FdfFiles
    )

    Write-Gc179Log "Mode secours: ouverture des FDF dans Acrobat/Windows. Sauvegardez chaque PDF ouvert au besoin."
    foreach ($fdfFile in @($FdfFiles)) {
        Write-Gc179Log ("Ouverture FDF: {0}" -f $fdfFile.Name)
        try {
            Start-Process -FilePath ([string]$fdfFile.FullName) | Out-Null
        }
        catch {
            Write-Warning ("Impossible d'ouvrir automatiquement {0}. Double-cliquez ce fichier manuellement ou ouvrez-le avec Adobe Acrobat. {1}" -f $fdfFile.Name, $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 800
    }
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
        Write-Gc179Log "Initialisation Acrobat COM."
        $acroApp = Invoke-Gc179Operation -Name "Creation AcroExch.App" -ScriptBlock {
            New-Object -ComObject AcroExch.App
        }
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
                Write-Gc179Log ("Traitement: {0}" -f $fdfFile.Name)
                if (Test-Path -Path $workingPath -PathType Leaf) {
                    Remove-Item -LiteralPath $workingPath -Force
                }
                New-Gc179WorkingPdf -TemplatePath $TemplatePath -WorkingPath $workingPath

                $avDoc = Invoke-Gc179Operation -Name "Creation AcroExch.AVDoc" -ScriptBlock {
                    New-Object -ComObject AcroExch.AVDoc
                }
                $openPath = ConvertTo-Gc179FullPath -Path $workingPath
                $openTitle = [System.IO.Path]::GetFileName($openPath)
                Write-Gc179Log ("Ouverture copie PDF: {0}" -f $openPath)
                $opened = Invoke-Gc179Operation -Name "Ouverture PDF par Acrobat" -ScriptBlock {
                    $avDoc.Open([string]$openPath, [string]$openTitle)
                }
                if (-not $opened) {
                    throw "Acrobat n'a pas pu ouvrir la copie de travail GC179."
                }

                $pdDoc = Invoke-Gc179Operation -Name "Lecture PDDoc" -ScriptBlock {
                    $avDoc.GetPDDoc()
                }
                $jsObject = Invoke-Gc179Operation -Name "Lecture JSObject Acrobat" -ScriptBlock {
                    $pdDoc.GetJSObject()
                }

                Write-Gc179Log ("Import FDF: {0}" -f $fdfFile.FullName)
                Invoke-Gc179Operation -Name "Import FDF" -ScriptBlock {
                    Invoke-Gc179FdfImport -JsObject $jsObject -FdfPath ([string]$fdfFile.FullName)
                } | Out-Null
                Write-Gc179Log ("Sauvegarde copie PDF: {0}" -f $workingPath)
                Invoke-Gc179Operation -Name "Sauvegarde PDF" -ScriptBlock {
                    Save-Gc179PDDoc -PDDoc $pdDoc -Path $workingPath
                }

                $avDoc.Close($true) | Out-Null
                try {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($avDoc) | Out-Null
                }
                catch {
                }
                $avDoc = $null
                Complete-Gc179WorkingPdf -WorkingPath $workingPath -OutputPath $outputPath
                $generated += $outputPath
            }
            finally {
                if ($null -ne $avDoc) {
                    try {
                        $avDoc.Close($true) | Out-Null
                    }
                    catch {
                    }

                    try {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($avDoc) | Out-Null
                    }
                    catch {
                    }
                }
                if ($null -ne $pdDoc) {
                    try {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($pdDoc) | Out-Null
                    }
                    catch {
                    }
                }
                if (Test-Path -Path $workingPath -PathType Leaf) {
                    try {
                        Remove-Item -LiteralPath $workingPath -Force
                    }
                    catch {
                    }
                }
            }
        }
    }
    finally {
        try {
            $acroApp.Exit() | Out-Null
        }
        catch {
        }

        try {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($acroApp) | Out-Null
        }
        catch {
        }
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
    try {
        $generated = @(Invoke-Gc179WindowsAcrobat -TemplatePath $templatePath -FdfFiles $fdfFiles -OutputDirectory $outputDirectory)
    }
    catch {
        Write-Warning ("Automatisation Acrobat impossible: {0}" -f $_.Exception.Message)
        Invoke-Gc179WindowsFdfFallback -FdfFiles $fdfFiles
        Write-Host ""
        Write-Host "Mode secours lance. Acrobat devrait ouvrir les FDF avec GC179.pdf et les donnees importees."
        Write-Host "Si Windows demande une application, choisissez Adobe Acrobat."
        exit 0
    }
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