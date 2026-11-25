[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectsPath,
    [string]$OutputPath,
    [datetime]$ReferenceDate = (Get-Date),
    [ValidateRange(1024, 65535)][int]$Port = 8091
)

$ErrorActionPreference = "Stop"
$sourceRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $sourceRoot "output/saphir-demo-departement" }
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $destination) { throw "The destination already exists. Choose a new directory: $destination" }
$projectCatalog = @(Get-Content -LiteralPath $ProjectsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
if ($projectCatalog.Count -lt 1 -or $projectCatalog.Count -gt 20) { throw "Expected 1 to 20 source projects." }
$seenCodes = @{}
foreach ($project in $projectCatalog) {
    $code = [string]$project.projectCode
    if ([string]::IsNullOrWhiteSpace($code) -or $seenCodes.ContainsKey($code)) {
        throw "The source contains a missing or duplicate project code."
    }
    $seenCodes[$code] = $true
}
$originalAdmins = @(foreach ($project in $projectCatalog) {
    @($project.admins) + @($project.backupAdmins) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }
})
$originalAdmins = @($originalAdmins | Select-Object -Unique)
if ($originalAdmins.Count -gt 5) { throw "This demo supports up to five source supervisor identities." }

function Write-DemoText {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

New-Item -ItemType Directory -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot "app") -Destination $destination -Recurse
foreach ($path in @("docs", "scripts/lib")) { New-Item -ItemType Directory -Path (Join-Path $destination $path) -Force | Out-Null }
Copy-Item -LiteralPath (Join-Path $sourceRoot "docs/GC179.pdf") -Destination (Join-Path $destination "docs")
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "lib/ServerControl.ps1") -Destination (Join-Path $destination "scripts/lib")
foreach ($name in @("Start-demo.ps1", "Demarrer-demo.command", "Demarrer-demo.cmd")) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "demo/$name") -Destination $destination
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    & chmod +x (Join-Path $destination "Demarrer-demo.command")
    if ($LASTEXITCODE -ne 0) { throw "Unable to make the macOS demo shortcut executable." }
}

$backend = Join-Path $destination "app/backend"
$url = "http://localhost:$Port/"
$demoConfig = @'
@{
    ListenerPrefix = "__DEMO_URL__"
    DataFolderPath = "../../data"
    Gc179LocalExportPath = "../../runtime/GC179"
    EnableDemoSeed = $false
    EnableGc179Import = $true
}
'@
Write-DemoText (Join-Path $backend "saphir-config.psd1") ($demoConfig.Replace("__DEMO_URL__", $url))

# Load only the isolated bundle's configuration. No source DATA is read.
. (Join-Path $backend "lib/AppContext.ps1")
. (Join-Path $backend "lib/CommonHelpers.ps1")
. (Join-Path $backend "services/AuthService.ps1")
. (Join-Path $backend "services/EntryService.ps1")
. (Join-Path $backend "services/CompensationGridService.ps1")
. (Join-Path $backend "services/OvertimeCostSnapshotService.ps1")

$demoIndex = Join-Path $destination "app/frontend/index.html"
$demoPage = [IO.File]::ReadAllText($demoIndex)
$badge = '<div class="brand-demo-note" style="font-size:.7rem;color:var(--label-secondary);white-space:normal">DÉMO · DONNÉES FICTIVES</div>'
$brand = '<div class="brand-title" data-i18n="brand.saphir">SAPHIR</div>'
Write-DemoText $demoIndex ($demoPage.Replace('<title>SAPHIR</title>', '<title>SAPHIR — Démo départementale</title>').Replace($brand, "$brand$badge"))
$demoI18n = Join-Path $destination "app/frontend/scripts/I18n.js"
Write-DemoText $demoI18n ([IO.File]::ReadAllText($demoI18n).Replace('"app.title": "SAPHIR"', '"app.title": "SAPHIR — Démo"'))

$firstMonth = $ReferenceDate.Date.AddDays(1 - $ReferenceDate.Day).AddMonths(-11)
$demoGrid = Get-Content -LiteralPath $compensationGridFile -Raw | ConvertFrom-Json
# Sample history can precede the first configured grid date. Extend only the
# synthetic copy's earliest band so the sample contains usable amounts.
foreach ($bandGroup in @($demoGrid.bands | Group-Object group, subGroup, level)) {
    $earliest = $bandGroup.Group | Sort-Object effectiveFrom | Select-Object -First 1
    if ([datetime]$earliest.effectiveFrom -gt $firstMonth) { $earliest.effectiveFrom = $firstMonth.ToString("yyyy-MM-dd") }
}
Write-JsonAtomic -Path $compensationGridFile -Value $demoGrid -Depth 12

$names = @(
    "Maëlle Verville", "Émile Durocher", "Nora Levasseur", "Sami Larivière", "Jade Pelletier", "Mathis Desrochers",
    "Élodie Desmarais", "Noé Bellemare", "Inès Laurent", "Milan Rivard", "Amina Delisle", "Théo Laramée",
    "Camille Dufresne", "Luc Delaunay", "Rania Boivin", "Nathan Charbonneau", "Sofia Masson", "Alex Marin",
    "Maya Fontaine", "Arthur Aubry", "Yasmine Renaud", "Hugo Valois", "Louise Chevalier", "Gabriel Maheu",
    "Lina Dupuis", "Antoine Savard", "Amélia Lemieux", "Isaac Normand", "Clara Benoît", "Adam Véronneau",
    "Zahra Dorion", "Léo Paquette", "Zoé Martel", "Nolan Ferron", "Léonie Désilets", "Milo Hébert",
    "Samira Bélanger", "Thomas Gravel", "Alice Fortier", "Édouard Perron"
)
$password = "DemoSAPHIR2026!"
$courses = @(
    @{ group = "CR"; subGroup = "04"; steps = 4 },
    @{ group = "AS"; subGroup = "03"; steps = 3 },
    @{ group = "AS"; subGroup = "04"; steps = 3 },
    @{ group = "IT"; subGroup = "02"; steps = 8 }
)
$users = @(for ($index = 0; $index -lt $names.Count; $index++) {
    $code = [string](880000001 + $index)
    $parts = $names[$index].Split(' ', 2)
    $course = $courses[$index % $courses.Count]
    $credential = New-PasswordCredential -Password $password
    [PSCustomObject]@{
        username = $code; employeeCode = $code; displayName = $names[$index]
        role = $(if ($index -eq 0) { "superAdmin" } elseif ($index -lt 6) { "admin" } else { "employee" })
        disabled = $false; mustChangePassword = $false
        passwordSalt = $credential.passwordSalt; passwordHash = $credential.passwordHash
        passwordIterations = $credential.passwordIterations; passwordAlgorithm = $credential.passwordAlgorithm
        timeEntryTypes = @(if ($index -eq 6) { "overtime"; "diverse" } else { "overtime" })
        gc179Profile = [PSCustomObject]@{
            givenName = $parts[0]; surname = $parts[1]; department = "Démonstration"
            group = $course.group; subGroup = $course.subGroup
            level = (1 + [int][math]::Floor($index / 4) % $course.steps).ToString("00")
            compressedWorkWeek = (($index % 5) -eq 2)
        }
    }
})
$supervisors = @($users | Where-Object role -eq admin)
$mappedAdmins = @{}
for ($index = 0; $index -lt $originalAdmins.Count; $index++) {
    $mappedAdmins[$originalAdmins[$index]] = $supervisors[$index].employeeCode
}
$demoProjects = @(
    @{ projectName = "Modernisation du portail"; sector = "Services numériques"; colorKey = "blue"; markerKey = "triangle" },
    @{ projectName = "Intégration des données"; sector = "Données"; colorKey = "teal"; markerKey = "square" },
    @{ projectName = "Revue des accès"; sector = "Sécurité"; colorKey = "amber"; markerKey = "diamond" },
    @{ projectName = "Tests de reprise"; sector = "Infrastructures"; colorKey = "green"; markerKey = "diamond" },
    @{ projectName = "Automatisation des rapports"; sector = "Opérations"; colorKey = "violet"; markerKey = "triangle" },
    @{ projectName = "Formation interne"; sector = "Services internes"; colorKey = "coral"; markerKey = "square" },
    @{ projectName = "Migration documentaire"; sector = "Information"; colorKey = "pink"; markerKey = "diamond" },
    @{ projectName = "Suivi de qualité"; sector = "Assurance qualité"; colorKey = "mint"; markerKey = "square" }
)
$projects = @(for ($index = 0; $index -lt $projectCatalog.Count; $index++) {
    $project = $projectCatalog[$index]
    $primary = @($project.admins | Where-Object { ([string]$_).Trim() } | ForEach-Object { $mappedAdmins[([string]$_).Trim()] })
    $backup = @($project.backupAdmins | Where-Object { ([string]$_).Trim() } | ForEach-Object { $mappedAdmins[([string]$_).Trim()] })
    if (-not $primary.Count) { $primary = @($supervisors[$index % $supervisors.Count].employeeCode) }
    [PSCustomObject]@{
        projectCode = [string]$project.projectCode; projectName = [string]$project.projectName; sector = [string]$project.sector
        colorKey = [string]$project.colorKey; markerKey = [string]$project.markerKey; archived = [bool]$project.archived
        admins = $primary; backupAdmins = @($backup | Where-Object { $_ -notin $primary })
    }
})
for ($index = 0; $projects.Count -lt 20; $index++) {
    $extra = $demoProjects[$index % $demoProjects.Count]
    $code = "DEMO-{0:00}" -f (1 + $index)
    if ($seenCodes.ContainsKey($code)) { continue }
    $projects += [PSCustomObject]@{
        projectCode = $code; projectName = $extra.projectName; sector = $extra.sector
        colorKey = $extra.colorKey; markerKey = $extra.markerKey; archived = $false
        admins = @($supervisors[$index % $supervisors.Count].employeeCode)
        backupAdmins = @($supervisors[($index + 1) % $supervisors.Count].employeeCode)
    }
}
$projectPool = @($projects | Where-Object { -not $_.archived })
if (-not $projectPool.Count) { throw "At least one active project is required." }
$employeeNames = [ordered]@{}
foreach ($user in $users) { $employeeNames[$user.employeeCode] = $user.displayName }
Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
Write-JsonAtomic -Path $projectsFile -Value $projects -Depth 8
Write-JsonAtomic -Path (Join-Path $sharedFolder "employeeNames.json") -Value ([PSCustomObject]$employeeNames)
Write-JsonAtomic -Path $sessionsFile -Value "[]"

function New-DemoEntry {
    param($Employee, $Project, [datetime]$Start, [int]$Minutes, [string]$EntryStatus, [string]$Schedule, [string]$Comment, [string]$Payment = "cash", [string]$Type = "overtime")
    $dateText = $Start.ToString("yyyy-MM-dd")
    $exactIn = $Start.ToString("HH:mm:ss")
    $exactOut = if ($Minutes) { $Start.AddMinutes($Minutes).ToString("HH:mm:ss") } else { $null }
    $punchIn = Convert-ToNearestQuarterHourText -Date $dateText -TimeText $exactIn
    $punchOut = if ($exactOut) { Convert-ToNearestQuarterHourText -Date $dateText -TimeText $exactOut } else { $null }
    $credit = if ($exactOut) { (Get-QuarterHourCreditSummary -Date $dateText -PunchIn $exactIn -PunchOut $exactOut).creditedOvertime } else { $null }
    $manager = if ($Employee.role -eq "employee") { $users | Where-Object employeeCode -eq $Project.admins[0] | Select-Object -First 1 } else { $users[0] }
    $note = if ($EntryStatus -eq "rejected") { "Préciser le dossier visé avant de faire corriger cette entrée." } else { "" }
    $overtimeCode = switch ($Start.DayOfWeek) { "Saturday" { "261" }; "Sunday" { "262" }; default { "260" } }
    return [PSCustomObject]@{
        entryId = New-EntryIdentifier; name = $Employee.displayName; date = $dateText
        entryType = $Type; projectCode = $(if ($Type -eq "diverse") { "" } else { $Project.projectCode })
        punchIn = $punchIn; punchOut = $punchOut; exactPunchIn = $exactIn; exactPunchOut = $exactOut
        overtime = $credit; overtimeCalculationRule = "quarter-10m-v1"; status = $EntryStatus; workSchedule = $Schedule; workScheduleSource = "manual"
        overtimeCode = $(if ($Type -eq "diverse") { "" } else { $overtimeCode }); reasonCode = "D"
        paymentOption = $Payment; workComment = $Comment
        diverseReason = $(if ($Type -eq "diverse") { "Soutien ponctuel à la formation" } else { "" })
        diverseSummary = $(if ($Type -eq "diverse") { $Comment } else { "" })
        message = $note
        messageAuthorName = $(if ($note) { $manager.displayName } else { "" })
        messageAuthorUsername = $(if ($note) { $manager.username } else { "" })
    }
}

$random = [Random]::new(441179)
$comments = @("Validation des livrables.", "Vérifications avant la mise en service.", "Soutien pendant une période de pointe.", "Mise à jour des dossiers et suivi.", "Préparation et contrôle de qualité.")
$durations = @(45, 60, 75, 90, 120, 150, 180, 210)
$season = @(0, -1, 0, 1, 1, 0, 2, 1, -1, 0, 2, 1)
$history = [Collections.Generic.List[object]]::new()
$allEntries = [Collections.Generic.List[object]]::new()
for ($person = 0; $person -lt $users.Count; $person++) {
    $employee = $users[$person]
    $list = [Collections.Generic.List[object]]::new()
    $schedule = if ($employee.gc179Profile.compressedWorkWeek) { "compressed" } else { "regular" }
    for ($month = 0; $month -lt 12; $month++) {
        $startMonth = $firstMonth.AddMonths($month)
        $days = if ($month -eq 11) { [Math]::Max(1, $ReferenceDate.Day - 1) } else { [datetime]::DaysInMonth($startMonth.Year, $startMonth.Month) }
        $count = [Math]::Min($days, 3 + ($person % 3) + $season[$month] + $random.Next(0, 2))
        for ($index = 0; $index -lt $count; $index++) {
            $blockStart = [int][Math]::Floor($index * $days / $count)
            $blockEnd = [int][Math]::Floor(($index + 1) * $days / $count)
            $day = $startMonth.AddDays($random.Next($blockStart, $blockEnd))
            $start = $day.AddHours($random.Next(15, 20)).AddMinutes(15 * $random.Next(0, 4) + $random.Next(0, 4))
            $projectIndex = if ($index -eq 0 -or $random.Next(100) -lt 65) { $person % $projectPool.Count } else { $random.Next($projectPool.Count) }
            $roll = $random.Next(100)
            $status = if ($month -eq 11 -and $roll -lt 37) { "pending" } elseif ($roll -gt 94) { "rejected" } else { "approved" }
            $payment = if ($random.Next(100) -lt 24) { "leave" } else { "cash" }
            $entry = New-DemoEntry $employee $projectPool[$projectIndex] $start $durations[$random.Next($durations.Count)] $status $schedule $comments[$random.Next($comments.Count)] -Payment $payment
            $list.Add($entry)
            if ($month -ge 8 -and $index -eq 0) {
                $actor = $users[0]
                $history.Add([PSCustomObject]@{
                    action = $(if ($status -eq "approved") { "Approved" } elseif ($status -eq "rejected") { "Rejected" } else { "Add" })
                    employee = $employee.displayName; targetEmployee = $employee.displayName; employeeCode = $employee.employeeCode
                    projectCode = $entry.projectCode; entryId = $entry.entryId
                    author = $actor.displayName; authorUsername = $actor.username; authorRole = $actor.role
                    message = "Entrée de démonstration — dossier $([Net.WebUtility]::HtmlEncode($entry.projectCode))."
                    timestamp = $start.AddHours(5).ToString("yyyy-MM-dd HH:mm:ss")
                })
            }
        }
    }
    if ($person -eq 6) { # Employee used in the walkthrough.
        $endOfLastMonth = $firstMonth.AddMonths(11).AddDays(-2)
        $list.Add((New-DemoEntry $employee $projectPool[0] $endOfLastMonth.AddHours(21) 60 "rejected" $schedule "Suivi du dossier avant fermeture."))
        $list.Add((New-DemoEntry $employee $projectPool[0] $ReferenceDate.Date.AddDays(-1).AddHours(8) 495 "approved" $schedule "Appui à la formation et validation des guides." -Type "diverse"))
        # Always leave a valid monthly GC179 sample for the demo employee.
        $list.Add((New-DemoEntry $employee $projectPool[0] $ReferenceDate.Date.AddDays(-1).AddHours(20) 90 "approved" $schedule "Vérification du dossier avant fermeture."))
    }
    if ($person -eq 7) {
        $list.Add((New-DemoEntry $employee $projectPool[0] $ReferenceDate.Date.AddDays(-1).AddHours(14).AddMinutes(4) 4 "pending" $schedule "Pointage court de démonstration."))
    }
    if ($person -eq 8) {
        $forgotten = New-DemoEntry $employee $projectPool[1] $ReferenceDate.Date.AddDays(-1).AddHours(22) 0 "pending" $schedule ""
        Set-EntryForgottenClockOutReview -Entry $forgotten -AttemptDate $ReferenceDate.ToString("yyyy-MM-dd") -AttemptTime "08:00:00"
        $list.Add($forgotten)
    }
    $records = @($list.ToArray() | Sort-Object date, punchIn)
    Set-ApprovedEntryCompensationSnapshots -EmployeeCode $employee.employeeCode -EmployeeUser $employee -Entries $records | Out-Null
    Write-JsonAtomic -Path (Join-Path $sharedFolder "$($employee.employeeCode)_data.json") -Value $records -Depth 14
    $allEntries.AddRange([object[]]$records)
}
Write-JsonAtomic -Path $historyFile -Value @($history.ToArray() | Sort-Object timestamp -Descending) -Depth 8

$entries = $allEntries.ToArray()
$months = @($entries | Group-Object { $_.date.Substring(0, 7) } | Sort-Object Name)
$amountCount = @($entries | Where-Object { $_.compensationSnapshot.snapshotStatus -eq "final" }).Count
if ($months.Count -ne 12 -or $users.Count -ne 40 -or $projects.Count -ne 20 -or $amountCount -lt 1) {
    throw "Incomplete sample: expected 40 employees, 20 projects, 12 months and calculated amounts."
}
$period = "$($months[0].Name) à $($months[-1].Name)"
Write-DemoText (Join-Path $destination "LIRE-MOI.txt") @"
SAPHIR — Démonstration départementale hors ligne

Mac : ouvrir Demarrer-demo.command (PowerShell 7 requis).
Windows : extraire le dossier au complet, puis ouvrir Demarrer-demo.cmd.
Adresse : $url
Le dossier data est local à cette copie. Ne pas utiliser ces chiffres pour la paie.

Comptes fictifs — mot de passe commun : $password
  880000001  Super admin — vue d’ensemble et toutes les données
  880000002  Admin (pas super admin) — projets et révision limités à ses affectations
  880000007  Employée — calendrier, temps divers et export GC179

$($users.Count) employés | $($projects.Count) projets ($($projectCatalog.Count) du fichier fourni) | $($entries.Count) entrées
Période : $period. $amountCount montants calculés à partir de la grille de démo.

Parcours suggéré :
  1. Super admin : Vue d’ensemble, puis Révision et l’onglet À vérifier.
  2. Projets : élargir la période au-delà de Ce mois-ci et ouvrir un projet.
  3. Personnel : ouvrir Élodie Desmarais et afficher son calendrier.
  4. Compte employé : Calendrier et GC179. Acrobat est requis pour ouvrir le formulaire ;
     le résultat de l’export donne le chemin pour récupérer les fichiers même sans Acrobat.

Pour arrêter : relancer le raccourci ou Start-demo.ps1 avec -Stop depuis un terminal.
"@
Write-Host "Démo prête : $destination"
Write-Host "40 employés, 20 projets, $($entries.Count) entrées ($period), $amountCount montants. URL : $url"
