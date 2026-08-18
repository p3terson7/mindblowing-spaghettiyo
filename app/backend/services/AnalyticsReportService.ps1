$projectCatalogModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.ProjectCatalog.psd1"
if ($null -eq (Get-Module -Name "Saphir.ProjectCatalog")) {
    Import-Module -Name $projectCatalogModuleManifest -ErrorAction Stop | Out-Null
}
Remove-Variable -Name projectCatalogModuleManifest -ErrorAction SilentlyContinue

$entryStateModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.EntryState.psd1"
if ($null -eq (Get-Module -Name "Saphir.EntryState")) {
    Import-Module -Name $entryStateModuleManifest -ErrorAction Stop | Out-Null
}
Remove-Variable -Name entryStateModuleManifest -ErrorAction SilentlyContinue

function Resolve-AnalyticsReportDateRange {
    param(
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::None
    $parsedStart = [DateTime]::MinValue
    $parsedEnd = [DateTime]::MinValue
    $hasStart = -not [string]::IsNullOrWhiteSpace([string]$StartDate)
    $hasEnd = -not [string]::IsNullOrWhiteSpace([string]$EndDate)

    if ($hasStart -and -not [DateTime]::TryParseExact(([string]$StartDate).Trim(), "yyyy-MM-dd", $culture, $styles, [ref]$parsedStart)) {
        throw (New-Object System.ArgumentException -ArgumentList "startDate must use yyyy-MM-dd.")
    }
    if ($hasEnd -and -not [DateTime]::TryParseExact(([string]$EndDate).Trim(), "yyyy-MM-dd", $culture, $styles, [ref]$parsedEnd)) {
        throw (New-Object System.ArgumentException -ArgumentList "endDate must use yyyy-MM-dd.")
    }
    if ($hasStart -and $hasEnd -and $parsedStart -gt $parsedEnd) {
        throw (New-Object System.ArgumentException -ArgumentList "startDate cannot be after endDate.")
    }

    return [PSCustomObject]@{
        StartText = if ($hasStart) { $parsedStart.ToString("yyyy-MM-dd", $culture) } else { "" }
        EndText   = if ($hasEnd) { $parsedEnd.ToString("yyyy-MM-dd", $culture) } else { "" }
        Start     = if ($hasStart) { $parsedStart.Date } else { $null }
        End       = if ($hasEnd) { $parsedEnd.Date } else { $null }
    }
}

function Resolve-AnalyticsReportLocale {
    param([AllowNull()][string]$Locale)

    $normalized = ([string]$Locale).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "en"
    }
    if ($normalized -ne "en" -and $normalized -ne "fr") {
        throw (New-Object System.ArgumentException -ArgumentList "locale must be en or fr.")
    }
    return $normalized
}

function Resolve-AnalyticsReportProjectCode {
    param([AllowNull()][string]$ProjectCode)

    $candidate = ([string]$ProjectCode).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return ""
    }
    if ($candidate.Length -gt 64 -or -not [regex]::IsMatch($candidate, '^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$')) {
        throw (New-Object System.ArgumentException -ArgumentList "projectCode is invalid.")
    }
    return $candidate
}

function ConvertTo-AnalyticsReportFileNameToken {
    param([AllowNull()][string]$Value)

    $candidate = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return ""
    }

    return ([regex]::Replace($candidate, '[^A-Za-z0-9._-]+', '-')).Trim("-"[0])
}

function Get-AnalyticsReportNormalizedStatus {
    param($Entry)

    $status = if ($null -ne $Entry -and $Entry.PSObject.Properties.Name -contains "status") {
        ([string]$Entry.status).Trim().ToLowerInvariant()
    }
    else {
        ""
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        return "pending"
    }
    if ($status -eq "approved" -or $status -eq "pending" -or $status -eq "rejected") {
        return $status
    }
    return "other"
}

function Get-AnalyticsReportEntryType {
    param($Entry)

    $entryType = if ($null -ne $Entry -and $Entry.PSObject.Properties.Name -contains "entryType") {
        ([string]$Entry.entryType).Trim().ToLowerInvariant()
    }
    else {
        ""
    }
    if ([string]::IsNullOrWhiteSpace($entryType)) {
        return "overtime"
    }
    return $entryType
}

function ConvertTo-AnalyticsReportDuration {
    param([AllowNull()][string]$Value)

    $duration = [TimeSpan]::Zero
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or
        -not [TimeSpan]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -or
        $duration.TotalSeconds -lt 0) {
        return [PSCustomObject]@{ Valid = $false; Seconds = 0 }
    }

    return [PSCustomObject]@{
        Valid   = $true
        Seconds = [int][math]::Round($duration.TotalSeconds)
    }
}

function Get-AnalyticsReportProjectColorKey {
    param(
        [AllowNull()][string]$ProjectCode,
        [AllowNull()][string]$ColorKey
    )

    $candidate = ([string]$ColorKey).Trim().ToLowerInvariant()
    if (Saphir.ProjectCatalog\Test-ProjectColorKey -ColorKey $candidate) {
        return $candidate
    }

    # Analytics historically hashed the code exactly as received, whereas the
    # catalog facade trims it. Preserve both conventions explicitly so this
    # refactor does not recolor malformed-but-readable legacy project codes.
    return (Saphir.ProjectCatalog\Get-ProjectColorKeyFromText -ProjectCodeText $ProjectCode)
}

function Test-AnalyticsReportForgottenClockOut {
    param($Entry)

    return (Saphir.EntryState\Test-EntryForgottenClockOut -Entry $Entry)
}

function Get-AnalyticsReportUiStrings {
    param([Parameter(Mandatory = $true)][string]$Locale)

    if ($Locale -eq "fr") {
        return [PSCustomObject]@{
            title = "Analyse des heures supplémentaires"
            subtitle = "Vue d’ensemble interactive de l’utilisation des heures supplémentaires"
            snapshot = "Rapport autonome — instantané généré le"
            period = "Période"
            allData = "Toutes les données disponibles"
            officialBasis = "Les graphiques affichent les entrées approuvées par défaut. Les entrées en attente et rejetées peuvent être activées avec le filtre Statut."
            search = "Recherche"
            searchPlaceholder = "Rechercher un employé, un projet, un secteur ou un code"
            employee = "Employé"
            allEmployees = "Tous les employés"
            project = "Projet"
            allProjects = "Tous les projets"
            sector = "Secteur"
            allSectors = "Tous les secteurs"
            status = "Statut"
            allStatuses = "Tous les statuts"
            month = "Mois"
            allMonths = "Tous les mois"
            payment = "Paiement"
            allPayments = "Tous les paiements"
            reset = "Réinitialiser"
            print = "Imprimer / PDF"
            exportCsv = "Exporter le CSV filtré"
            selectedHours = "Heures sélectionnées"
            entries = "Entrées"
            activeEmployees = "Employés avec activité"
            activeProjects = "Projets utilisés"
            medianEmployee = "Médiane par employé"
            trackedEmployees = "employés dans le rapport"
            employeeUsage = "Heures par employé"
            employeeUsageHint = "Toutes les personnes sont affichées, y compris celles à zéro heure pour les filtres choisis."
            projectUsage = "Heures par projet"
            monthlyTrend = "Évolution mensuelle"
            employeeProject = "Employés × projets"
            workflow = "Répartition par statut"
            paymentBreakdown = "Répartition par paiement"
            detail = "Données filtrées"
            date = "Date"
            duration = "Durée"
            overtimeCode = "Code supp."
            reasonCode = "Code raison"
            approved = "Approuvée"
            pending = "En attente"
            rejected = "Rejetée"
            other = "Autre"
            cash = "En espèce"
            leave = "Congé"
            noData = "Aucune donnée ne correspond aux filtres."
            zeroHours = "0 h"
            archived = "archivé"
            unknownProject = "Projet non répertorié"
            noSector = "Sans secteur"
            qualityTitle = "Points à vérifier dans les données"
            qualitySummary = "Certaines anciennes entrées ont été exclues des calculs parce qu’elles sont incomplètes ou invalides."
            qualityInvalidDate = "Dates invalides"
            qualityInvalidDuration = "Durées invalides"
            qualityIncompleteApproved = "Entrées approuvées sans punch-out valide"
            qualityUnknownEntryType = "Types d’entrée inconnus"
            qualityUnknownStatus = "Statuts inconnus"
            qualityMissingProject = "Références à un projet non répertorié"
            qualityDiverse = "Entrées Diverse exclues de l’overtime"
            showingRows = "Affichage de {shown} sur {total} lignes"
            limitedMatrix = "La matrice montre les 25 employés et 12 projets les plus actifs pour garder une lecture confortable. Utilisez les filtres pour préciser la vue."
            hours = "h"
        }
    }

    return [PSCustomObject]@{
        title = "Overtime analytics"
        subtitle = "Interactive overview of overtime usage"
        snapshot = "Standalone report — snapshot generated"
        period = "Period"
        allData = "All available data"
        officialBasis = "Charts show approved entries by default. Pending and rejected entries can be enabled with the Status filter."
        search = "Search"
        searchPlaceholder = "Search an employee, project, sector, or code"
        employee = "Employee"
        allEmployees = "All employees"
        project = "Project"
        allProjects = "All projects"
        sector = "Sector"
        allSectors = "All sectors"
        status = "Status"
        allStatuses = "All statuses"
        month = "Month"
        allMonths = "All months"
        payment = "Payment"
        allPayments = "All payment methods"
        reset = "Reset"
        print = "Print / PDF"
        exportCsv = "Export filtered CSV"
        selectedHours = "Selected hours"
        entries = "Entries"
        activeEmployees = "Employees with activity"
        activeProjects = "Projects used"
        medianEmployee = "Median per employee"
        trackedEmployees = "employees in report"
        employeeUsage = "Hours by employee"
        employeeUsageHint = "Everyone is shown, including people with zero hours for the selected filters."
        projectUsage = "Hours by project"
        monthlyTrend = "Monthly trend"
        employeeProject = "Employees × projects"
        workflow = "Status breakdown"
        paymentBreakdown = "Payment breakdown"
        detail = "Filtered data"
        date = "Date"
        duration = "Duration"
        overtimeCode = "Overtime code"
        reasonCode = "Reason code"
        approved = "Approved"
        pending = "Pending"
        rejected = "Rejected"
        other = "Other"
        cash = "Cash"
        leave = "Leave"
        noData = "No data matches the filters."
        zeroHours = "0 h"
        archived = "archived"
        unknownProject = "Unlisted project"
        noSector = "No sector"
        qualityTitle = "Data items to review"
        qualitySummary = "Some older entries were excluded from calculations because they are incomplete or invalid."
        qualityInvalidDate = "Invalid dates"
        qualityInvalidDuration = "Invalid durations"
        qualityIncompleteApproved = "Approved entries without a valid punch-out"
        qualityUnknownEntryType = "Unknown entry types"
        qualityUnknownStatus = "Unknown statuses"
        qualityMissingProject = "References to an unlisted project"
        qualityDiverse = "Diverse entries excluded from overtime"
        showingRows = "Showing {shown} of {total} rows"
        limitedMatrix = "The matrix shows the 25 most active employees and 12 most active projects for readability. Use filters to narrow the view."
        hours = "h"
    }
}

function Get-AnalyticsReportModel {
    param(
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate,
        [AllowNull()][string]$Locale,
        [AllowNull()][string]$ProjectCode,
        [Parameter(Mandatory = $true)]$CurrentUser
    )

    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) {
        throw (New-Object System.UnauthorizedAccessException -ArgumentList "Manager access is required.")
    }

    $range = Resolve-AnalyticsReportDateRange -StartDate $StartDate -EndDate $EndDate
    $resolvedLocale = Resolve-AnalyticsReportLocale -Locale $Locale
    $resolvedProjectCode = Resolve-AnalyticsReportProjectCode -ProjectCode $ProjectCode
    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser

    if (-not [string]::IsNullOrWhiteSpace($resolvedProjectCode) -and -not $accessModel.ProjectCodeSet.ContainsKey($resolvedProjectCode)) {
        if ($isSuperAdmin) {
            throw (New-Object System.Collections.Generic.KeyNotFoundException -ArgumentList "Project with code $resolvedProjectCode was not found.")
        }
        throw (New-Object System.UnauthorizedAccessException -ArgumentList "You do not have access to project $resolvedProjectCode.")
    }

    $projectMap = @{}
    $projectsList = New-Object System.Collections.ArrayList

    foreach ($project in @($accessModel.Projects | Sort-Object projectCode)) {
        $projectCode = ([string]$project.projectCode).Trim()
        if ([string]::IsNullOrWhiteSpace($projectCode)) {
            continue
        }
        $projectName = if ($project.PSObject.Properties.Name -contains "projectName") { ([string]$project.projectName).Trim() } else { "" }
        $sector = if ($project.PSObject.Properties.Name -contains "sector") { ([string]$project.sector).Trim() } else { "" }
        $projectRecord = [PSCustomObject]@{
            projectCode = $projectCode
            displayName = if ([string]::IsNullOrWhiteSpace($projectName)) { $projectCode } else { $projectName }
            sector      = $sector
            colorKey    = Get-AnalyticsReportProjectColorKey -ProjectCode $projectCode -ColorKey $(if ($project.PSObject.Properties.Name -contains "colorKey") { [string]$project.colorKey } else { "" })
            archived    = Test-ProjectArchived -Project $project
        }
        $projectMap[$projectCode] = $projectRecord
        [void]$projectsList.Add($projectRecord)
    }

    $factsList = New-Object System.Collections.ArrayList
    $employeeCandidates = New-Object System.Collections.ArrayList
    $quality = [ordered]@{
        invalidDateCount        = 0
        invalidDurationCount    = 0
        incompleteApprovedCount = 0
        unknownEntryTypeCount   = 0
        unknownStatusCount      = 0
        missingProjectCount     = 0
        diverseEntryCount       = 0
    }
    $seenEmployeeCodes = @{}
    $employeeSequence = 0

    $employeeUsers = @(Get-Users | Where-Object { Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode "" } | Sort-Object displayName, username)
    foreach ($user in $employeeUsers) {
        $employeeCode = (Get-UserEmployeeCodeValue -UserRecord $user).Trim()
        if ([string]::IsNullOrWhiteSpace($employeeCode) -or $seenEmployeeCodes.ContainsKey($employeeCode)) {
            continue
        }
        $seenEmployeeCodes[$employeeCode] = $true
        $employeeSequence++
        $reportEmployeeId = "employee-{0:d4}" -f $employeeSequence
        $displayName = if ($user.PSObject.Properties.Name -contains "displayName") { ([string]$user.displayName).Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = [string](Get-EmployeeName $employeeCode)
        }
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = "Employee $employeeSequence"
        }
        $isArchived = $user.PSObject.Properties.Name -contains "disabled" -and [bool]$user.disabled
        $employeeFactCountBefore = $factsList.Count
        $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode

        foreach ($entry in @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)) {
            if ($null -eq $entry) {
                continue
            }
            $entryDate = Get-EntryDateOrNull -Entry $entry
            if ($null -eq $entryDate) {
                $quality.invalidDateCount++
                continue
            }
            if ($null -ne $range.Start -and $entryDate.Date -lt $range.Start) {
                continue
            }
            if ($null -ne $range.End -and $entryDate.Date -gt $range.End) {
                continue
            }

            $entryType = Get-AnalyticsReportEntryType -Entry $entry
            if ($entryType -eq "diverse") {
                $quality.diverseEntryCount++
                continue
            }
            if ($entryType -ne "overtime") {
                $quality.unknownEntryTypeCount++
                continue
            }

            $status = Get-AnalyticsReportNormalizedStatus -Entry $entry
            if ($status -eq "other") {
                $quality.unknownStatusCount++
            }
            $hasPunchOut = $entry.PSObject.Properties.Name -contains "punchOut" -and -not [string]::IsNullOrWhiteSpace([string]$entry.punchOut)
            $isForgotten = Test-AnalyticsReportForgottenClockOut -Entry $entry
            if (-not $hasPunchOut -or $isForgotten) {
                if ($status -eq "approved") {
                    $quality.incompleteApprovedCount++
                }
                continue
            }

            $duration = ConvertTo-AnalyticsReportDuration -Value ([string]$entry.overtime)
            if (-not [bool]$duration.Valid) {
                $quality.invalidDurationCount++
                continue
            }

            $projectCode = if ($entry.PSObject.Properties.Name -contains "projectCode") { ([string]$entry.projectCode).Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($projectCode)) {
                $projectCode = "__unassigned__"
            }

            if (-not $projectMap.ContainsKey($projectCode)) {
                # Current admins can view the full department. If project visibility
                # becomes restricted later, only a super administrator may retain an
                # entry whose deleted project can no longer be authorized by code.
                if (-not $isSuperAdmin -and $accessModel.ProjectCodes.Count -ne (Get-Projects).Count) {
                    continue
                }
                $quality.missingProjectCount++
                $unknownProject = [PSCustomObject]@{
                    projectCode = $projectCode
                    displayName = if ($projectCode -eq "__unassigned__") { "—" } else { $projectCode }
                    sector      = ""
                    colorKey    = Get-AnalyticsReportProjectColorKey -ProjectCode $projectCode
                    archived    = $true
                }
                $projectMap[$projectCode] = $unknownProject
                [void]$projectsList.Add($unknownProject)
            }

            $payment = if ($entry.PSObject.Properties.Name -contains "paymentOption") { ([string]$entry.paymentOption).Trim().ToLowerInvariant() } else { "" }
            if ([string]::IsNullOrWhiteSpace($payment)) {
                $payment = "cash"
            }
            [void]$factsList.Add([PSCustomObject]@{
                employeeRef    = $reportEmployeeId
                projectCode    = $projectCode
                date           = $entryDate.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
                month          = $entryDate.ToString("yyyy-MM", [System.Globalization.CultureInfo]::InvariantCulture)
                durationSeconds = [int]$duration.Seconds
                status         = $status
                payment        = $payment
                overtimeCode   = if ($entry.PSObject.Properties.Name -contains "overtimeCode") { ([string]$entry.overtimeCode).Trim() } else { "" }
                reasonCode     = if ($entry.PSObject.Properties.Name -contains "reasonCode") { ([string]$entry.reasonCode).Trim() } else { "" }
            })
        }

        $employeeHasFacts = $factsList.Count -gt $employeeFactCountBefore
        if (-not $isArchived -or $employeeHasFacts) {
            [void]$employeeCandidates.Add([PSCustomObject]@{
                reportEmployeeId = $reportEmployeeId
                displayName      = $displayName
                archived         = [bool]$isArchived
            })
        }
    }

    $facts = @($factsList.ToArray())
    $employees = @($employeeCandidates.ToArray())
    $approvedFacts = @($facts | Where-Object { [string]$_.status -eq "approved" })
    $pendingFacts = @($facts | Where-Object { [string]$_.status -eq "pending" })
    $rejectedFacts = @($facts | Where-Object { [string]$_.status -eq "rejected" })
    $approvedSeconds = [long](($approvedFacts | Measure-Object -Property durationSeconds -Sum).Sum)
    $pendingSeconds = [long](($pendingFacts | Measure-Object -Property durationSeconds -Sum).Sum)
    $rejectedSeconds = [long](($rejectedFacts | Measure-Object -Property durationSeconds -Sum).Sum)

    return [PSCustomObject]@{
        meta = [PSCustomObject]@{
            schemaVersion = 1
            generatedAtUtc = [DateTime]::UtcNow.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
            locale = $resolvedLocale
            period = [PSCustomObject]@{ startDate = $range.StartText; endDate = $range.EndText }
            defaultStatus = "approved"
            defaultProject = $resolvedProjectCode
            statusBasis = "closed-overtime"
        }
        ui = Get-AnalyticsReportUiStrings -Locale $resolvedLocale
        employees = $employees
        projects = @($projectsList.ToArray() | Sort-Object displayName, projectCode)
        facts = $facts
        summary = [PSCustomObject]@{
            approvedSeconds = $approvedSeconds
            pendingSeconds = $pendingSeconds
            rejectedSeconds = $rejectedSeconds
            approvedEntryCount = $approvedFacts.Count
            pendingEntryCount = $pendingFacts.Count
            rejectedEntryCount = $rejectedFacts.Count
            trackedEmployeeCount = $employees.Count
        }
        quality = [PSCustomObject]$quality
    }
}

function Get-AnalyticsReportHtmlTemplate {
    return @'
<!doctype html>
<html lang="__LANG__">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
  <title>__TITLE__</title>
  <style>
    :root{color-scheme:light;--bg:#fff;--panel:#fff;--panel-solid:#fff;--text:#172033;--muted:#607080;--line:#d9e1ea;--line-strong:#bdc9d7;--accent:#0868d7;--accent-hover:#0758b6;--accent-soft:#eaf3ff;--focus:rgba(8,104,215,.2);--shadow:0 4px 16px rgba(30,55,85,.07);--blue:#0868d7;--green:#16865a;--violet:#6c50c7;--teal:#008994;--amber:#b56f00;--coral:#c43840;--pink:#b9477f;--indigo:#4766c7;--graphite:#667085;--mint:#0f8f7a;--pending:#a96200;--rejected:#c43840}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
    button,input,select{font:inherit;color:inherit}
    .page{width:min(1440px,calc(100% - 40px));margin:0 auto;padding:38px 0 64px}
    .hero{display:flex;justify-content:space-between;gap:28px;align-items:flex-start;padding:0 2px 24px;border-bottom:1px solid var(--line);margin-bottom:22px}
    .eyebrow{font-size:.75rem;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:var(--accent)}
    h1{font-size:clamp(2rem,3vw,3rem);letter-spacing:-.042em;line-height:1.08;margin:.38rem 0 .45rem}
    .subtitle{font-size:1.05rem}.subtitle,.meta,.hint{color:var(--muted)}.meta{font-size:.9rem;margin-top:.55rem}
    .snapshot-pill{border:1px solid var(--line);background:#f8fafc;border-radius:999px;padding:9px 14px;white-space:nowrap;color:#435264;font-size:.86rem}
    .panel{background:var(--panel);border:1px solid var(--line);border-radius:15px;box-shadow:var(--shadow);margin-bottom:18px}
    .filters{padding:18px 20px;background:#fbfcfe;border-color:var(--line-strong)}
    .filter-grid{display:grid;grid-template-columns:minmax(250px,2fr) repeat(5,minmax(135px,1fr));gap:13px}
    .field{min-width:0}.field label{display:block;font-size:.72rem;font-weight:800;letter-spacing:.075em;text-transform:uppercase;color:#536273;margin:0 0 7px}
    .control{width:100%;min-height:44px;border:1px solid var(--line-strong);background-color:#fff;border-radius:10px;padding:10px 12px;box-shadow:0 1px 2px rgba(20,40,70,.04);transition:border-color .16s ease,box-shadow .16s ease,background-color .16s ease}
    .control:hover{border-color:#91afd2;background-color:#fcfdff}.control:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--focus)}
    input.control::placeholder{color:#8794a3}
    select.control{appearance:none;-webkit-appearance:none;cursor:pointer;padding-right:40px;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 16 16'%3E%3Cpath d='m4 6 4 4 4-4' fill='none' stroke='%23536273' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 13px center;background-size:16px}
    select.control:hover{background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 16 16'%3E%3Cpath d='m4 6 4 4 4-4' fill='none' stroke='%230868d7' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E")}
    select.control option{background:#fff;color:var(--text);font-weight:500}
    .filter-actions{display:flex;gap:9px;align-items:center;flex-wrap:wrap;margin-top:16px;padding-top:15px;border-top:1px solid var(--line)}
    .button{min-height:40px;border:1px solid var(--line-strong);background:#fff;border-radius:10px;padding:9px 15px;font-weight:700;cursor:pointer;transition:border-color .16s ease,background-color .16s ease,box-shadow .16s ease,transform .16s ease}
    .button:hover{border-color:#91afd2;background:#f4f8fd;transform:translateY(-1px)}.button:focus-visible{outline:none;box-shadow:0 0 0 3px var(--focus)}.button.primary{background:var(--accent);border-color:var(--accent);color:#fff}.button.primary:hover{background:var(--accent-hover);border-color:var(--accent-hover)}
    .basis{margin:11px 0 0;color:var(--muted);font-size:.86rem}
    .kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin:18px 0}.kpi{position:relative;overflow:hidden;background:#fff;border:1px solid var(--line);border-radius:13px;padding:17px 17px 16px;min-height:108px}.kpi:before{content:"";position:absolute;inset:0 auto 0 0;width:3px;background:var(--accent)}.kpi-label{font-size:.73rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:800}.kpi-value{font-size:clamp(1.45rem,2.5vw,2.15rem);font-weight:760;letter-spacing:-.035em;margin-top:9px;font-variant-numeric:tabular-nums}.kpi-hint{color:var(--muted);font-size:.8rem;margin-top:3px}
    .section-head{display:flex;justify-content:space-between;gap:16px;align-items:end;padding:19px 20px 0}.section-head h2{margin:0;font-size:1.08rem;letter-spacing:-.012em}.section-head p{margin:4px 0 0;color:var(--muted);font-size:.85rem}.section-body{padding:17px 20px 20px}.two-col{display:grid;grid-template-columns:1fr 1fr;gap:18px}
    .bar-list{display:grid;gap:12px;max-height:600px;overflow:auto;padding-right:5px}.bar-row{display:grid;grid-template-columns:minmax(140px,220px) minmax(180px,1fr) 78px;gap:12px;align-items:center}.bar-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:650}.bar-track{height:16px;background:#edf2f7;border-radius:999px;overflow:hidden;display:flex}.bar-segment{height:100%;min-width:0}.bar-value{text-align:right;font-variant-numeric:tabular-nums;font-weight:700}.empty{padding:28px;text-align:center;color:var(--muted);background:#fafbfd;border:1px dashed var(--line-strong);border-radius:11px}
    .trend{display:flex;align-items:end;gap:8px;height:230px;padding-top:20px;overflow-x:auto}.trend-item{display:flex;flex:1 0 48px;min-width:48px;height:100%;flex-direction:column;justify-content:end;align-items:center;gap:7px}.trend-value{font-size:.72rem;font-variant-numeric:tabular-nums;color:var(--muted)}.trend-bar{width:min(34px,80%);min-height:2px;background:linear-gradient(180deg,var(--accent),var(--violet));border-radius:7px 7px 2px 2px}.trend-label{font-size:.72rem;color:var(--muted);white-space:nowrap}
    .breakdown{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.breakdown-card{background:#fafbfd;border:1px solid var(--line);border-radius:11px;padding:14px}.breakdown-card strong{display:block;font-size:1.25rem;margin-top:4px;font-variant-numeric:tabular-nums}.breakdown-card span{color:var(--muted);font-size:.8rem}
    .matrix-wrap,.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:11px}.matrix,.detail-table{width:100%;border-collapse:collapse;font-size:.84rem}.matrix th,.matrix td,.detail-table th,.detail-table td{border-bottom:1px solid var(--line);padding:10px 11px;text-align:left;white-space:nowrap}.matrix th,.detail-table th{position:sticky;top:0;background:#f4f7fa;z-index:1;font-size:.71rem;text-transform:uppercase;letter-spacing:.055em;color:#536273}.detail-table tbody tr:nth-child(even){background:#fafbfd}.detail-table tbody tr:hover{background:#f2f7fd}.matrix td:not(:first-child){text-align:center;font-variant-numeric:tabular-nums}.heat{border-radius:6px;background:var(--accent-soft)}
    .quality{border-color:#e3bd82;background:#fffdf8}.quality ul{margin:10px 0 0;padding-left:20px;color:var(--muted)}.quality[hidden]{display:none}.row-note{color:var(--muted);font-size:.82rem;margin-top:10px}.status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;background:var(--muted)}.status-dot.approved{background:var(--green)}.status-dot.pending{background:var(--pending)}.status-dot.rejected{background:var(--rejected)}
    @media(max-width:1100px){.filter-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.filter-grid .search-field{grid-column:1/-1}.kpis{grid-template-columns:repeat(3,1fr)}.two-col{grid-template-columns:1fr}}
    @media(max-width:680px){.page{width:min(100% - 20px,1440px);padding-top:20px}.hero{display:block}.snapshot-pill{display:inline-block;margin-top:14px;white-space:normal}.filter-grid{grid-template-columns:1fr}.kpis{grid-template-columns:1fr 1fr}.bar-row{grid-template-columns:minmax(100px,1fr) 1.4fr 62px}.section-body,.section-head{padding-left:15px;padding-right:15px}}
    @media print{body{background:#fff;color:#111}.page{width:100%;padding:0}.hero{padding-bottom:12px}.panel,.kpi{box-shadow:none;break-inside:avoid}.filters,.filter-actions,.snapshot-pill{display:none}.two-col{grid-template-columns:1fr 1fr}.bar-list{max-height:none;overflow:visible}.table-wrap,.matrix-wrap{overflow:visible}.detail-table{font-size:8pt}}
  </style>
</head>
<body>
  <main class="page">
    <header class="hero">
      <div><div class="eyebrow">SAPHIR</div><h1 id="reportTitle"></h1><div class="subtitle" id="reportSubtitle"></div><div class="meta" id="reportPeriod"></div></div>
      <div class="snapshot-pill" id="reportSnapshot"></div>
    </header>
    <section class="panel filters" aria-label="Filters">
      <div class="filter-grid">
        <div class="field search-field"><label id="searchLabel" for="searchFilter"></label><input class="control" id="searchFilter" type="search"></div>
        <div class="field"><label id="employeeLabel" for="employeeFilter"></label><select class="control" id="employeeFilter"></select></div>
        <div class="field"><label id="projectLabel" for="projectFilter"></label><select class="control" id="projectFilter"></select></div>
        <div class="field"><label id="sectorLabel" for="sectorFilter"></label><select class="control" id="sectorFilter"></select></div>
        <div class="field"><label id="statusLabel" for="statusFilter"></label><select class="control" id="statusFilter"></select></div>
        <div class="field"><label id="monthLabel" for="monthFilter"></label><select class="control" id="monthFilter"></select></div>
        <div class="field"><label id="paymentLabel" for="paymentFilter"></label><select class="control" id="paymentFilter"></select></div>
      </div>
      <div class="filter-actions"><button class="button" id="resetButton" type="button"></button><button class="button" id="printButton" type="button"></button><button class="button primary" id="csvButton" type="button"></button></div>
      <p class="basis" id="basisText"></p>
    </section>
    <section class="kpis" aria-label="Summary">
      <article class="kpi"><div class="kpi-label" id="hoursKpiLabel"></div><div class="kpi-value" id="hoursKpi"></div></article>
      <article class="kpi"><div class="kpi-label" id="entriesKpiLabel"></div><div class="kpi-value" id="entriesKpi"></div></article>
      <article class="kpi"><div class="kpi-label" id="employeesKpiLabel"></div><div class="kpi-value" id="employeesKpi"></div><div class="kpi-hint" id="employeesKpiHint"></div></article>
      <article class="kpi"><div class="kpi-label" id="projectsKpiLabel"></div><div class="kpi-value" id="projectsKpi"></div></article>
      <article class="kpi"><div class="kpi-label" id="medianKpiLabel"></div><div class="kpi-value" id="medianKpi"></div></article>
    </section>
    <section class="panel quality" id="qualityPanel" hidden><div class="section-head"><div><h2 id="qualityTitle"></h2><p id="qualitySummary"></p></div></div><div class="section-body"><ul id="qualityList"></ul></div></section>
    <div class="two-col">
      <section class="panel"><div class="section-head"><div><h2 id="employeeUsageTitle"></h2><p id="employeeUsageHint"></p></div></div><div class="section-body"><div class="bar-list" id="employeeBars"></div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="projectUsageTitle"></h2></div></div><div class="section-body"><div class="bar-list" id="projectBars"></div></div></section>
    </div>
    <section class="panel"><div class="section-head"><div><h2 id="monthlyTrendTitle"></h2></div></div><div class="section-body"><div class="trend" id="monthlyTrend"></div></div></section>
    <div class="two-col">
      <section class="panel"><div class="section-head"><div><h2 id="workflowTitle"></h2></div></div><div class="section-body"><div class="breakdown" id="statusBreakdown"></div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="paymentBreakdownTitle"></h2></div></div><div class="section-body"><div class="breakdown" id="paymentBreakdown"></div></div></section>
    </div>
    <section class="panel"><div class="section-head"><div><h2 id="matrixTitle"></h2><p id="matrixHint"></p></div></div><div class="section-body"><div class="matrix-wrap" id="matrixContainer"></div></div></section>
    <section class="panel"><div class="section-head"><div><h2 id="detailTitle"></h2></div></div><div class="section-body"><div class="table-wrap"><table class="detail-table"><thead id="detailHead"></thead><tbody id="detailBody"></tbody></table></div><div class="row-note" id="detailNote"></div></div></section>
  </main>
  <script id="reportData" type="application/octet-stream">__REPORT_DATA_BASE64__</script>
  <script>
  (()=>{"use strict";
    const encoded=document.getElementById("reportData").textContent.trim();
    const bytes=Uint8Array.from(atob(encoded),c=>c.charCodeAt(0));
    const data=JSON.parse(new TextDecoder("utf-8").decode(bytes));
    const ui=data.ui,byId=id=>document.getElementById(id),employees=new Map(data.employees.map(item=>[item.reportEmployeeId,item])),projects=new Map(data.projects.map(item=>[item.projectCode,item]));
    const colors={blue:"var(--blue)",green:"var(--green)",violet:"var(--violet)",teal:"var(--teal)",amber:"var(--amber)",coral:"var(--coral)",pink:"var(--pink)",indigo:"var(--indigo)",graphite:"var(--graphite)",mint:"var(--mint)"};
    const normalize=value=>String(value||"").toLocaleLowerCase(data.meta.locale).normalize("NFD").replace(/[\u0300-\u036f]/g,"");
    const formatHours=seconds=>{const hours=Number(seconds||0)/3600;return `${new Intl.NumberFormat(data.meta.locale,{minimumFractionDigits:hours%1?1:0,maximumFractionDigits:2}).format(hours)} ${ui.hours}`};
    const statusLabel=value=>ui[value]||value||ui.other;
    const paymentLabel=value=>ui[value]||value||"—";
    function setText(id,value){byId(id).textContent=value}
    function addOption(select,value,label){const option=document.createElement("option");option.value=value;option.textContent=label;select.appendChild(option)}
    function sortedUnique(values){return [...new Set(values.filter(Boolean))].sort((a,b)=>String(a).localeCompare(String(b),data.meta.locale,{sensitivity:"base"}))}
    function initializeText(){
      setText("reportTitle",ui.title);setText("reportSubtitle",ui.subtitle);setText("searchLabel",ui.search);byId("searchFilter").placeholder=ui.searchPlaceholder;
      setText("employeeLabel",ui.employee);setText("projectLabel",ui.project);setText("sectorLabel",ui.sector);setText("statusLabel",ui.status);setText("monthLabel",ui.month);setText("paymentLabel",ui.payment);
      setText("resetButton",ui.reset);setText("printButton",ui.print);setText("csvButton",ui.exportCsv);setText("basisText",ui.officialBasis);
      setText("hoursKpiLabel",ui.selectedHours);setText("entriesKpiLabel",ui.entries);setText("employeesKpiLabel",ui.activeEmployees);setText("projectsKpiLabel",ui.activeProjects);setText("medianKpiLabel",ui.medianEmployee);
      setText("employeeUsageTitle",ui.employeeUsage);setText("employeeUsageHint",ui.employeeUsageHint);setText("projectUsageTitle",ui.projectUsage);setText("monthlyTrendTitle",ui.monthlyTrend);setText("workflowTitle",ui.workflow);setText("paymentBreakdownTitle",ui.paymentBreakdown);setText("matrixTitle",ui.employeeProject);setText("matrixHint",ui.limitedMatrix);setText("detailTitle",ui.detail);
      setText("qualityTitle",ui.qualityTitle);setText("qualitySummary",ui.qualitySummary);
      const period=data.meta.period.startDate||data.meta.period.endDate?`${ui.period}: ${data.meta.period.startDate||"…"} → ${data.meta.period.endDate||"…"}`:`${ui.period}: ${ui.allData}`;setText("reportPeriod",period);
      const generated=new Date(data.meta.generatedAtUtc);setText("reportSnapshot",`${ui.snapshot} ${new Intl.DateTimeFormat(data.meta.locale,{dateStyle:"medium",timeStyle:"short"}).format(generated)}`);
    }
    function initializeFilters(){
      const employeeSelect=byId("employeeFilter"),projectSelect=byId("projectFilter"),sectorSelect=byId("sectorFilter"),statusSelect=byId("statusFilter"),monthSelect=byId("monthFilter"),paymentSelect=byId("paymentFilter");
      addOption(employeeSelect,"",ui.allEmployees);data.employees.slice().sort((a,b)=>a.displayName.localeCompare(b.displayName,data.meta.locale,{sensitivity:"base"})).forEach(item=>addOption(employeeSelect,item.reportEmployeeId,`${item.displayName}${item.archived?` (${ui.archived})`:""}`));
      addOption(projectSelect,"",ui.allProjects);data.projects.slice().sort((a,b)=>a.displayName.localeCompare(b.displayName,data.meta.locale,{sensitivity:"base"})).forEach(item=>addOption(projectSelect,item.projectCode,`${item.displayName}${item.projectCode!==item.displayName?` (${item.projectCode})`:""}`));
      projectSelect.value=data.meta.defaultProject||"";
      addOption(sectorSelect,"",ui.allSectors);sortedUnique(data.projects.map(item=>item.sector||ui.noSector)).forEach(value=>addOption(sectorSelect,value,value));
      addOption(statusSelect,"",ui.allStatuses);["approved","pending","rejected","other"].forEach(value=>addOption(statusSelect,value,statusLabel(value)));statusSelect.value=data.meta.defaultStatus||"approved";
      addOption(monthSelect,"",ui.allMonths);sortedUnique(data.facts.map(item=>item.month)).forEach(value=>addOption(monthSelect,value,value));
      addOption(paymentSelect,"",ui.allPayments);sortedUnique(data.facts.map(item=>item.payment)).forEach(value=>addOption(paymentSelect,value,paymentLabel(value)));
    }
    function getState(){return{search:normalize(byId("searchFilter").value),employee:byId("employeeFilter").value,project:byId("projectFilter").value,sector:byId("sectorFilter").value,status:byId("statusFilter").value,month:byId("monthFilter").value,payment:byId("paymentFilter").value}}
    function matches(fact,state,ignoreStatus=false){const employee=employees.get(fact.employeeRef)||{},project=projects.get(fact.projectCode)||{};if(state.employee&&fact.employeeRef!==state.employee)return false;if(state.project&&fact.projectCode!==state.project)return false;if(state.sector&&(project.sector||ui.noSector)!==state.sector)return false;if(!ignoreStatus&&state.status&&fact.status!==state.status)return false;if(state.month&&fact.month!==state.month)return false;if(state.payment&&fact.payment!==state.payment)return false;if(state.search){const haystack=normalize([employee.displayName,project.projectCode,project.displayName,project.sector,fact.overtimeCode,fact.reasonCode,statusLabel(fact.status),paymentLabel(fact.payment)].join(" "));if(!state.search.split(/\s+/).every(token=>haystack.includes(token)))return false}return true}
    function empty(container){container.replaceChildren();const node=document.createElement("div");node.className="empty";node.textContent=ui.noData;container.appendChild(node)}
    function sum(facts){return facts.reduce((total,item)=>total+Number(item.durationSeconds||0),0)}
    function grouped(facts,keyFn){const map=new Map();facts.forEach(item=>{const key=keyFn(item);map.set(key,(map.get(key)||0)+Number(item.durationSeconds||0))});return map}
    function renderKpis(facts){const total=sum(facts),employeeTotals=[...grouped(facts,item=>item.employeeRef).values()].sort((a,b)=>a-b),middle=Math.floor(employeeTotals.length/2),median=employeeTotals.length?(employeeTotals.length%2?employeeTotals[middle]:(employeeTotals[middle-1]+employeeTotals[middle])/2):0;setText("hoursKpi",formatHours(total));setText("entriesKpi",new Intl.NumberFormat(data.meta.locale).format(facts.length));setText("employeesKpi",new Set(facts.map(item=>item.employeeRef)).size);setText("employeesKpiHint",`${data.employees.length} ${ui.trackedEmployees}`);setText("projectsKpi",new Set(facts.map(item=>item.projectCode)).size);setText("medianKpi",formatHours(median))}
    function renderBars(container,facts,kind){
      container.replaceChildren();const source=kind==="employee"?data.employees:data.projects,identity=kind==="employee"?item=>item.reportEmployeeId:item=>item.projectCode,label=kind==="employee"?item=>`${item.displayName}${item.archived?` (${ui.archived})`:""}`:item=>`${item.displayName}${item.projectCode!==item.displayName?` (${item.projectCode})`:""}`;
      const totals=grouped(facts,item=>kind==="employee"?item.employeeRef:item.projectCode),rows=source.map(item=>({item,key:identity(item),total:totals.get(identity(item))||0})).filter(row=>{const state=getState();if(kind==="employee"&&state.employee&&row.key!==state.employee)return false;if(kind==="project"&&state.project&&row.key!==state.project)return false;if(kind==="project"&&state.sector&&(row.item.sector||ui.noSector)!==state.sector)return false;if(!state.search)return true;if(row.total>0)return true;const rowSearch=normalize([label(row.item),row.item.projectCode].join(" "));return state.search.split(/\s+/).every(token=>rowSearch.includes(token))}).sort((a,b)=>b.total-a.total||label(a.item).localeCompare(label(b.item),data.meta.locale,{sensitivity:"base"}));
      if(!rows.length){empty(container);return}const max=Math.max(1,...rows.map(row=>row.total));rows.forEach(row=>{const wrapper=document.createElement("div");wrapper.className="bar-row";const name=document.createElement("div");name.className="bar-label";name.textContent=label(row.item);name.title=label(row.item);const track=document.createElement("div");track.className="bar-track";
        if(kind==="employee"){const segments=grouped(facts.filter(item=>item.employeeRef===row.key),item=>item.projectCode);[...segments.entries()].sort((a,b)=>b[1]-a[1]).forEach(([projectCode,value])=>{const project=projects.get(projectCode)||{},segment=document.createElement("span");segment.className="bar-segment";segment.style.width=`${value/max*100}%`;segment.style.background=colors[project.colorKey]||"var(--accent)";segment.title=`${project.displayName||projectCode}: ${formatHours(value)}`;track.appendChild(segment)})}else{const segment=document.createElement("span");segment.className="bar-segment";segment.style.width=`${row.total/max*100}%`;segment.style.background=colors[row.item.colorKey]||"var(--accent)";track.appendChild(segment)}
        const value=document.createElement("div");value.className="bar-value";value.textContent=formatHours(row.total);wrapper.append(name,track,value);container.appendChild(wrapper)})
    }
    function renderTrend(facts){const container=byId("monthlyTrend"),totals=grouped(facts,item=>item.month);container.replaceChildren();if(!totals.size){empty(container);return}const rows=[...totals.entries()].sort((a,b)=>a[0].localeCompare(b[0])),max=Math.max(1,...rows.map(row=>row[1]));rows.forEach(([month,total])=>{const item=document.createElement("div");item.className="trend-item";const value=document.createElement("div");value.className="trend-value";value.textContent=formatHours(total);const bar=document.createElement("div");bar.className="trend-bar";bar.style.height=`${Math.max(2,total/max*175)}px`;const label=document.createElement("div");label.className="trend-label";label.textContent=month;item.append(value,bar,label);container.appendChild(item)})}
    function renderBreakdown(container,items,labelFn){container.replaceChildren();if(!items.length){empty(container);return}items.forEach(([key,facts])=>{const card=document.createElement("div");card.className="breakdown-card";const label=document.createElement("span"),strong=document.createElement("strong"),hint=document.createElement("span");label.textContent=labelFn(key);strong.textContent=formatHours(sum(facts));hint.textContent=`${facts.length} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`;card.append(label,strong,hint);container.appendChild(card)})}
    function renderMatrix(facts){const container=byId("matrixContainer"),employeeTotals=grouped(facts,item=>item.employeeRef),projectTotals=grouped(facts,item=>item.projectCode),employeeKeys=[...employeeTotals.keys()].sort((a,b)=>employeeTotals.get(b)-employeeTotals.get(a)).slice(0,25),projectKeys=[...projectTotals.keys()].sort((a,b)=>projectTotals.get(b)-projectTotals.get(a)).slice(0,12);container.replaceChildren();if(!employeeKeys.length||!projectKeys.length){empty(container);return}const table=document.createElement("table");table.className="matrix";const head=document.createElement("thead"),headRow=document.createElement("tr"),corner=document.createElement("th");corner.textContent=ui.employee;headRow.appendChild(corner);projectKeys.forEach(key=>{const th=document.createElement("th");th.textContent=(projects.get(key)||{}).displayName||key;headRow.appendChild(th)});head.appendChild(headRow);const body=document.createElement("tbody"),pairTotals=new Map();facts.forEach(item=>{const key=`${item.employeeRef}\u0000${item.projectCode}`;pairTotals.set(key,(pairTotals.get(key)||0)+Number(item.durationSeconds||0))});const max=Math.max(1,...pairTotals.values());employeeKeys.forEach(employeeKey=>{const row=document.createElement("tr"),name=document.createElement("th");name.textContent=(employees.get(employeeKey)||{}).displayName||"—";row.appendChild(name);projectKeys.forEach(projectKey=>{const seconds=pairTotals.get(`${employeeKey}\u0000${projectKey}`)||0,cell=document.createElement("td");cell.textContent=seconds?formatHours(seconds):"—";if(seconds){cell.className="heat";cell.style.background=`color-mix(in srgb,var(--accent) ${Math.max(10,seconds/max*65)}%,transparent)`}row.appendChild(cell)});body.appendChild(row)});table.append(head,body);container.appendChild(table)}
    function renderDetails(facts){const head=byId("detailHead"),body=byId("detailBody"),columns=[ui.employee,ui.project,ui.sector,ui.date,ui.status,ui.duration,ui.payment,ui.overtimeCode,ui.reasonCode];head.replaceChildren();body.replaceChildren();const row=document.createElement("tr");columns.forEach(label=>{const th=document.createElement("th");th.textContent=label;row.appendChild(th)});head.appendChild(row);const sorted=facts.slice().sort((a,b)=>b.date.localeCompare(a.date)||(employees.get(a.employeeRef)||{}).displayName.localeCompare((employees.get(b.employeeRef)||{}).displayName,data.meta.locale)),visible=sorted.slice(0,500);visible.forEach(fact=>{const employee=employees.get(fact.employeeRef)||{},project=projects.get(fact.projectCode)||{},projectLabel=`${project.displayName||fact.projectCode}${project.projectCode&&project.projectCode!==project.displayName?` (${project.projectCode})`:""}`,tr=document.createElement("tr"),values=[employee.displayName||"—",projectLabel,project.sector||ui.noSector,fact.date,statusLabel(fact.status),formatHours(fact.durationSeconds),paymentLabel(fact.payment),fact.overtimeCode||"—",fact.reasonCode||"—"];values.forEach((value,index)=>{const td=document.createElement("td");if(index===4){const dot=document.createElement("span");dot.className=`status-dot ${fact.status}`;td.append(dot,document.createTextNode(value))}else td.textContent=value;tr.appendChild(td)});body.appendChild(tr)});setText("detailNote",ui.showingRows.replace("{shown}",visible.length).replace("{total}",sorted.length))}
    function renderQuality(){const labels={invalidDateCount:ui.qualityInvalidDate,invalidDurationCount:ui.qualityInvalidDuration,incompleteApprovedCount:ui.qualityIncompleteApproved,unknownEntryTypeCount:ui.qualityUnknownEntryType,unknownStatusCount:ui.qualityUnknownStatus,missingProjectCount:ui.qualityMissingProject,diverseEntryCount:ui.qualityDiverse},entries=Object.entries(data.quality).filter(([,value])=>Number(value)>0),panel=byId("qualityPanel"),list=byId("qualityList");panel.hidden=!entries.length;list.replaceChildren();entries.forEach(([key,value])=>{const item=document.createElement("li");item.textContent=`${labels[key]||key}: ${new Intl.NumberFormat(data.meta.locale).format(value)}`;list.appendChild(item)})}
    function render(){const state=getState(),facts=data.facts.filter(item=>matches(item,state,false)),workflowFacts=data.facts.filter(item=>matches(item,state,true));renderKpis(facts);renderBars(byId("employeeBars"),facts,"employee");renderBars(byId("projectBars"),facts,"project");renderTrend(facts);renderBreakdown(byId("statusBreakdown"),["approved","pending","rejected","other"].map(key=>[key,workflowFacts.filter(item=>item.status===key)]),statusLabel);renderBreakdown(byId("paymentBreakdown"),sortedUnique(facts.map(item=>item.payment)).map(key=>[key,facts.filter(item=>item.payment===key)]),paymentLabel);renderMatrix(facts);renderDetails(facts)}
    function csvCell(value){let text=String(value??"");if(/^[=+\-@]/.test(text))text=`'${text}`;return `"${text.replace(/"/g,'""')}"`}
    function exportCsv(){const state=getState(),facts=data.facts.filter(item=>matches(item,state,false)),header=[ui.employee,ui.project,ui.sector,ui.date,ui.status,ui.duration,ui.payment,ui.overtimeCode,ui.reasonCode],rows=facts.map(fact=>{const employee=employees.get(fact.employeeRef)||{},project=projects.get(fact.projectCode)||{};return[employee.displayName||"",project.displayName||fact.projectCode,project.sector||"",fact.date,statusLabel(fact.status),Number(fact.durationSeconds||0)/3600,paymentLabel(fact.payment),fact.overtimeCode||"",fact.reasonCode||""]});const csv="\ufeff"+[header,...rows].map(row=>row.map(csvCell).join(",")).join("\r\n"),blob=new Blob([csv],{type:"text/csv;charset=utf-8"}),url=URL.createObjectURL(blob),link=document.createElement("a");link.href=url;link.download="saphir-analytics-filtered.csv";link.click();setTimeout(()=>URL.revokeObjectURL(url),0)}
    initializeText();initializeFilters();renderQuality();["searchFilter","employeeFilter","projectFilter","sectorFilter","statusFilter","monthFilter","paymentFilter"].forEach(id=>byId(id).addEventListener(id==="searchFilter"?"input":"change",render));byId("resetButton").addEventListener("click",()=>{["searchFilter","employeeFilter","sectorFilter","monthFilter","paymentFilter"].forEach(id=>byId(id).value="");byId("projectFilter").value=data.meta.defaultProject||"";byId("statusFilter").value=data.meta.defaultStatus||"approved";render()});byId("printButton").addEventListener("click",()=>window.print());byId("csvButton").addEventListener("click",exportCsv);render();
  })();
  </script>
</body>
</html>
'@
}

function ConvertTo-AnalyticsReportHtml {
    param([Parameter(Mandatory = $true)]$Model)

    $json = ConvertTo-Json -InputObject $Model -Depth 8 -Compress
    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    $template = Get-AnalyticsReportHtmlTemplate
    $html = $template.Replace("__LANG__", [string]$Model.meta.locale)
    $html = $html.Replace("__TITLE__", [string]$Model.ui.title)
    $html = $html.Replace("__REPORT_DATA_BASE64__", $base64)
    return $html
}

function New-AnalyticsReportExport {
    param(
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate,
        [AllowNull()][string]$Locale,
        [AllowNull()][string]$ProjectCode,
        [Parameter(Mandatory = $true)]$CurrentUser
    )

    $model = Get-AnalyticsReportModel -StartDate $StartDate -EndDate $EndDate -Locale $Locale -ProjectCode $ProjectCode -CurrentUser $CurrentUser
    $html = ConvertTo-AnalyticsReportHtml -Model $model
    $rangeLabel = if ($model.meta.period.startDate -or $model.meta.period.endDate) {
        "{0}_{1}" -f $(if ($model.meta.period.startDate) { $model.meta.period.startDate } else { "start" }), $(if ($model.meta.period.endDate) { $model.meta.period.endDate } else { "end" })
    }
    else {
        "all"
    }

    $projectFileNameToken = ConvertTo-AnalyticsReportFileNameToken -Value ([string]$model.meta.defaultProject)
    $projectFileNamePart = if ([string]::IsNullOrWhiteSpace($projectFileNameToken)) { "" } else { "-$projectFileNameToken" }

    return [PSCustomObject]@{
        Html     = $html
        FileName = "saphir-analytics{0}-{1}-{2}.html" -f $projectFileNamePart, $rangeLabel, [string]$model.meta.locale
        Model    = $model
    }
}
