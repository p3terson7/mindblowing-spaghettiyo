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

function Resolve-AnalyticsReportMode {
    param([AllowNull()][string]$ReportMode)

    $normalized = ([string]$ReportMode).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "detailed"
    }
    if ($normalized -ne "detailed" -and $normalized -ne "department") {
        throw (New-Object System.ArgumentException -ArgumentList "reportMode must be detailed or department.")
    }
    return $normalized
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

function Get-AnalyticsReportProjectMarkerKey {
    param(
        [AllowNull()][string]$ProjectCode,
        [AllowNull()][string]$MarkerKey
    )

    $candidate = ([string]$MarkerKey).Trim().ToLowerInvariant()
    if (Saphir.ProjectCatalog\Test-ProjectMarkerKey -MarkerKey $candidate) {
        return $candidate
    }

    # Keep the same raw-text convention as the historical analytics color
    # fallback. Normal catalog projections use the trimmed default helper.
    return (Saphir.ProjectCatalog\Get-ProjectMarkerKeyFromText -ProjectCodeText $ProjectCode)
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
            subtitle = "Synthèse décisionnelle de l’utilisation des heures supplémentaires"
            snapshot = "Rapport autonome généré le"
            period = "Période"
            allData = "Toutes les données disponibles"
            officialBasis = "Les indicateurs principaux suivent le filtre Statut (approuvé par défaut). Le suivi des décisions compare tous les statuts de la même portée."
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
            scope = "Portée du rapport"
            scopeAll = "Toutes les données accessibles"
            selectedHours = "Heures sélectionnées"
            pendingHours = "Heures en attente"
            approvalRate = "Taux d’approbation"
            entries = "Entrées"
            activeEmployees = "Contributeurs actifs"
            activeProjects = "Projets actifs"
            decisionHighlights = "Points de discussion"
            topProject = "Projet principal"
            topEmployee = "Contributeur principal"
            projectConcentration = "Concentration des 3 principaux projets"
            pendingDecision = "Heures à décider"
            noActivity = "Aucune activité"
            projectShare = "Répartition par projet"
            projectShareHint = "Heures exactes, part du périmètre, contributeurs et volume en attente."
            projectShareScope = "La part conserve la même portée, même lorsqu’un seul projet est sélectionné."
            contributorShare = "Contributeurs principaux"
            contributorShareHint = "Top 10 selon les heures sélectionnées. Les barres représentent une part du total, sans décoration superflue."
            contributors = "Contributeurs"
            pending = "En attente"
            otherProjects = "Autres projets"
            projects = "projets"
            monthlyTrend = "Évolution mensuelle"
            monthlyTrendHint = "Heures exactes par mois pour la portée sélectionnée."
            employeeProject = "Employés × projets"
            workflow = "Suivi des décisions"
            workflowHint = "Tous les statuts pour la même portée, afin de visualiser le volume déjà approuvé et celui à traiter."
            paymentBreakdown = "Mode de compensation"
            paymentBreakdownHint = "Répartition des heures sélectionnées."
            drivers = "Motifs et codes d’heures supplémentaires"
            driversHint = "Les principaux codes utilisés dans la portée sélectionnée."
            reasons = "Codes raison"
            overtimeCodes = "Codes d’heures supp."
            appendix = "Annexe détaillée"
            appendixHint = "Matrice de répartition, qualité des données et liste des entrées utilisées pour appuyer la discussion."
            detail = "Données filtrées"
            date = "Date"
            duration = "Durée"
            overtimeCode = "Code supp."
            reasonCode = "Code raison"
            approved = "Approuvée"
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
        subtitle = "Decision-ready overview of overtime usage"
        snapshot = "Standalone report generated"
        period = "Period"
        allData = "All available data"
        officialBasis = "Primary indicators follow the Status filter (approved by default). Decision tracking compares every status in the same scope."
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
        scope = "Report scope"
        scopeAll = "All accessible data"
        selectedHours = "Selected hours"
        pendingHours = "Pending hours"
        approvalRate = "Approval rate"
        entries = "Entries"
        activeEmployees = "Active contributors"
        activeProjects = "Active projects"
        decisionHighlights = "Discussion points"
        topProject = "Leading project"
        topEmployee = "Leading contributor"
        projectConcentration = "Top three project concentration"
        pendingDecision = "Hours to decide"
        noActivity = "No activity"
        projectShare = "Project share"
        projectShareHint = "Exact hours, share of scope, contributors, and pending volume."
        projectShareScope = "The share keeps the same scope, even when one project is selected."
        contributorShare = "Leading contributors"
        contributorShareHint = "Top 10 by selected hours. Bars show share of the total without decorative patterns."
        contributors = "Contributors"
        pending = "Pending"
        otherProjects = "Other projects"
        projects = "projects"
        monthlyTrend = "Monthly trend"
        monthlyTrendHint = "Exact hours by month for the selected scope."
        employeeProject = "Employees × projects"
        workflow = "Decision tracking"
        workflowHint = "Every status in the same scope, to show approved work and work still to be decided."
        paymentBreakdown = "Compensation method"
        paymentBreakdownHint = "Breakdown of the selected hours."
        drivers = "Reasons and overtime codes"
        driversHint = "The leading codes used in the selected scope."
        reasons = "Reason codes"
        overtimeCodes = "Overtime codes"
        appendix = "Detailed appendix"
        appendixHint = "Allocation matrix, data quality, and the records used to support the discussion."
        detail = "Filtered data"
        date = "Date"
        duration = "Duration"
        overtimeCode = "Overtime code"
        reasonCode = "Reason code"
        approved = "Approved"
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

function Get-AnalyticsDepartmentReportUiStrings {
    param([Parameter(Mandatory = $true)][string]$Locale)

    if ($Locale -eq "fr") {
        return [PSCustomObject]@{
            title = "Portrait départemental des heures supplémentaires"
            subtitle = "Vue globale des heures supplémentaires par projet"
            snapshot = "Rapport autonome généré le"
            period = "Période"
            allData = "Toutes les données disponibles"
            scope = "Portée du rapport"
            scopeAll = "Tous les projets accessibles"
            selectedProject = "Projet sélectionné"
            approvedHours = "Heures approuvées"
            pendingHours = "Heures en attente"
            approvalRate = "Taux d’approbation"
            activeProjects = "Projets actifs"
            entries = "Entrées"
            decisionHighlights = "Points de discussion"
            topProject = "Projet principal"
            projectConcentration = "Concentration des 3 principaux projets"
            peakMonth = "Mois le plus chargé"
            pendingDecision = "Heures à décider"
            noActivity = "Aucune activité"
            projectPortfolio = "Répartition par projet"
            projectPortfolioHint = "Heures exactes, part du périmètre, entrées et volume en attente."
            project = "Projet"
            sector = "Secteur"
            approved = "Approuvée"
            pending = "En attente"
            rejected = "Rejetée"
            other = "Autre"
            projectShare = "Part"
            duration = "Durée"
            monthlyTrend = "Évolution mensuelle"
            monthlyTrendHint = "Heures approuvées par mois pour la portée sélectionnée."
            decisionTracking = "Suivi des décisions"
            decisionTrackingHint = "Les statuts couvrent tout le volume dans la même portée."
            paymentBreakdown = "Mode de compensation"
            paymentBreakdownHint = "Répartition du volume approuvé."
            sectorBreakdown = "Répartition par secteur"
            sectorBreakdownHint = "Heures approuvées selon le secteur du projet."
            drivers = "Motifs et codes d’heures supplémentaires"
            driversHint = "Codes les plus utilisés dans la portée sélectionnée."
            reasons = "Codes raison"
            overtimeCodes = "Codes d’heures supp."
            qualityTitle = "Points à vérifier dans les données"
            qualitySummary = "Certaines entrées ont été exclues des calculs parce qu’elles sont incomplètes ou invalides."
            qualityInvalidDate = "Dates invalides"
            qualityInvalidDuration = "Durées invalides"
            qualityIncompleteApproved = "Entrées approuvées sans punch-out valide"
            qualityUnknownEntryType = "Types d’entrée inconnus"
            qualityUnknownStatus = "Statuts inconnus"
            qualityMissingProject = "Références à un projet non répertorié"
            qualityDiverse = "Entrées Diverse exclues de l’overtime"
            qualityNone = "Aucun point à vérifier dans la période."
            aggregatedData = "Données agrégées par projet"
            aggregatedDataHint = "Chaque ligne regroupe les entrées de la période; aucune donnée individuelle n’est incluse."
            print = "Imprimer / PDF"
            exportCsv = "Exporter les données agrégées"
            noData = "Aucune donnée ne correspond à cette portée."
            cash = "En espèce"
            leave = "Congé"
            noSector = "Sans secteur"
            hours = "h"
        }
    }

    return [PSCustomObject]@{
        title = "Department overtime overview"
        subtitle = "Department-wide view of overtime by project"
        snapshot = "Standalone report generated"
        period = "Period"
        allData = "All available data"
        scope = "Report scope"
        scopeAll = "All accessible projects"
        selectedProject = "Selected project"
        approvedHours = "Approved hours"
        pendingHours = "Pending hours"
        approvalRate = "Approval rate"
        activeProjects = "Active projects"
        entries = "Entries"
        decisionHighlights = "Discussion points"
        topProject = "Leading project"
        projectConcentration = "Top three project concentration"
        peakMonth = "Busiest month"
        pendingDecision = "Hours to decide"
        noActivity = "No activity"
        projectPortfolio = "Project distribution"
        projectPortfolioHint = "Exact hours, share of scope, entries, and pending volume."
        project = "Project"
        sector = "Sector"
        approved = "Approved"
        pending = "Pending"
        rejected = "Rejected"
        other = "Other"
        projectShare = "Share"
        duration = "Duration"
        monthlyTrend = "Monthly trend"
        monthlyTrendHint = "Approved hours by month for the selected scope."
        decisionTracking = "Decision tracking"
        decisionTrackingHint = "Statuses cover every overtime record in the same scope."
        paymentBreakdown = "Compensation method"
        paymentBreakdownHint = "Breakdown of approved overtime."
        sectorBreakdown = "Sector distribution"
        sectorBreakdownHint = "Approved hours by project sector."
        drivers = "Reasons and overtime codes"
        driversHint = "Most-used codes in the selected scope."
        reasons = "Reason codes"
        overtimeCodes = "Overtime codes"
        qualityTitle = "Data items to review"
        qualitySummary = "Some records were excluded from calculations because they are incomplete or invalid."
        qualityInvalidDate = "Invalid dates"
        qualityInvalidDuration = "Invalid durations"
        qualityIncompleteApproved = "Approved entries without a valid punch-out"
        qualityUnknownEntryType = "Unknown entry types"
        qualityUnknownStatus = "Unknown statuses"
        qualityMissingProject = "References to an unlisted project"
        qualityDiverse = "Diverse entries excluded from overtime"
        qualityNone = "No data issues in the period."
        aggregatedData = "Aggregated project data"
        aggregatedDataHint = "Each row combines the period's entries; no individual data is included."
        print = "Print / PDF"
        exportCsv = "Export aggregated data"
        noData = "No data matches this scope."
        cash = "Cash"
        leave = "Leave"
        noSector = "No sector"
        hours = "h"
    }
}

function New-AnalyticsReportDepartmentAggregate {
    param([hashtable]$Dimensions = @{})

    $aggregate = [ordered]@{}
    foreach ($key in $Dimensions.Keys) {
        $aggregate[$key] = $Dimensions[$key]
    }
    foreach ($status in @("approved", "pending", "rejected", "other")) {
        $aggregate["$status`Seconds"] = [long]0
        $aggregate["$status`EntryCount"] = 0
    }
    $aggregate.totalSeconds = [long]0
    $aggregate.entryCount = 0
    return [PSCustomObject]$aggregate
}

function Add-AnalyticsReportDepartmentAggregateFact {
    param(
        [Parameter(Mandatory = $true)]$Aggregate,
        [Parameter(Mandatory = $true)]$Fact
    )

    $durationSeconds = [long]$Fact.durationSeconds
    $status = ([string]$Fact.status).Trim().ToLowerInvariant()
    if ($status -ne "approved" -and $status -ne "pending" -and $status -ne "rejected") {
        $status = "other"
    }
    $secondsProperty = "$status`Seconds"
    $entryCountProperty = "$status`EntryCount"

    $Aggregate.totalSeconds = [long]$Aggregate.totalSeconds + $durationSeconds
    $Aggregate.entryCount = [int]$Aggregate.entryCount + 1
    $Aggregate.$secondsProperty = [long]$Aggregate.$secondsProperty + $durationSeconds
    $Aggregate.$entryCountProperty = [int]$Aggregate.$entryCountProperty + 1
}

function Get-AnalyticsDepartmentReportModel {
    param([Parameter(Mandatory = $true)]$DetailedModel)

    $projectByCode = @{}
    foreach ($project in @($DetailedModel.projects)) {
        $projectByCode[[string]$project.projectCode] = $project
    }

    $sourceFacts = @($DetailedModel.facts)
    $defaultProject = [string]$DetailedModel.meta.defaultProject
    if (-not [string]::IsNullOrWhiteSpace($defaultProject)) {
        $sourceFacts = @($sourceFacts | Where-Object { [string]$_.projectCode -eq $defaultProject })
    }

    $projectTotals = @{}
    $monthTotals = @{}
    $sectorTotals = @{}
    $paymentTotals = @{}
    $reasonTotals = @{}
    $overtimeCodeTotals = @{}
    $statusTotals = @{}

    foreach ($fact in $sourceFacts) {
        $projectCode = [string]$fact.projectCode
        $project = if ($projectByCode.ContainsKey($projectCode)) { $projectByCode[$projectCode] } else { $null }
        $projectName = if ($null -ne $project -and -not [string]::IsNullOrWhiteSpace([string]$project.displayName)) { [string]$project.displayName } else { $projectCode }
        $sector = if ($null -ne $project) { [string]$project.sector } else { "" }
        $colorKey = if ($null -ne $project) { [string]$project.colorKey } else { Get-AnalyticsReportProjectColorKey -ProjectCode $projectCode }
        $markerKey = if ($null -ne $project) { [string]$project.markerKey } else { Get-AnalyticsReportProjectMarkerKey -ProjectCode $projectCode }
        $month = [string]$fact.month
        $payment = [string]$fact.payment
        $reasonCode = [string]$fact.reasonCode
        $overtimeCode = [string]$fact.overtimeCode
        $status = [string]$fact.status

        if (-not $projectTotals.ContainsKey($projectCode)) {
            $projectTotals[$projectCode] = New-AnalyticsReportDepartmentAggregate -Dimensions @{
                projectCode = $projectCode
                displayName = $projectName
                sector = $sector
                colorKey = $colorKey
                markerKey = $markerKey
            }
        }
        if (-not $monthTotals.ContainsKey($month)) {
            $monthTotals[$month] = New-AnalyticsReportDepartmentAggregate -Dimensions @{ month = $month }
        }
        if (-not $sectorTotals.ContainsKey($sector)) {
            $sectorTotals[$sector] = New-AnalyticsReportDepartmentAggregate -Dimensions @{ sector = $sector }
        }
        if (-not $paymentTotals.ContainsKey($payment)) {
            $paymentTotals[$payment] = New-AnalyticsReportDepartmentAggregate -Dimensions @{ payment = $payment }
        }
        if (-not $reasonTotals.ContainsKey($reasonCode)) {
            $reasonTotals[$reasonCode] = New-AnalyticsReportDepartmentAggregate -Dimensions @{ reasonCode = $reasonCode }
        }
        if (-not $overtimeCodeTotals.ContainsKey($overtimeCode)) {
            $overtimeCodeTotals[$overtimeCode] = New-AnalyticsReportDepartmentAggregate -Dimensions @{ overtimeCode = $overtimeCode }
        }
        if (-not $statusTotals.ContainsKey($status)) {
            $statusTotals[$status] = New-AnalyticsReportDepartmentAggregate -Dimensions @{ status = $status }
        }

        foreach ($aggregate in @(
            $projectTotals[$projectCode],
            $monthTotals[$month],
            $sectorTotals[$sector],
            $paymentTotals[$payment],
            $reasonTotals[$reasonCode],
            $overtimeCodeTotals[$overtimeCode],
            $statusTotals[$status]
        )) {
            Add-AnalyticsReportDepartmentAggregateFact -Aggregate $aggregate -Fact $fact
        }
    }

    $projectRows = @($projectTotals.Values | Sort-Object @{ Expression = { [long]$_.approvedSeconds }; Descending = $true }, @{ Expression = { [long]$_.totalSeconds }; Descending = $true }, displayName, projectCode)
    $monthRows = @($monthTotals.Values | Sort-Object month)
    $sectorRows = @($sectorTotals.Values | Sort-Object @{ Expression = { [long]$_.approvedSeconds }; Descending = $true }, sector)
    $paymentRows = @($paymentTotals.Values | Sort-Object @{ Expression = { [long]$_.approvedSeconds }; Descending = $true }, payment)
    $reasonRows = @($reasonTotals.Values | Sort-Object @{ Expression = { [long]$_.approvedSeconds }; Descending = $true }, reasonCode)
    $overtimeCodeRows = @($overtimeCodeTotals.Values | Sort-Object @{ Expression = { [long]$_.approvedSeconds }; Descending = $true }, overtimeCode)
    $statusRows = @($statusTotals.Values | Sort-Object status)

    $approvedSeconds = [long](($sourceFacts | Where-Object { [string]$_.status -eq "approved" } | Measure-Object -Property durationSeconds -Sum).Sum)
    $pendingSeconds = [long](($sourceFacts | Where-Object { [string]$_.status -eq "pending" } | Measure-Object -Property durationSeconds -Sum).Sum)
    $rejectedSeconds = [long](($sourceFacts | Where-Object { [string]$_.status -eq "rejected" } | Measure-Object -Property durationSeconds -Sum).Sum)
    $otherSeconds = [long](($sourceFacts | Where-Object { [string]$_.status -eq "other" } | Measure-Object -Property durationSeconds -Sum).Sum)

    return [PSCustomObject]@{
        meta = [PSCustomObject]@{
            schemaVersion = 1
            reportMode = "department"
            generatedAtUtc = [string]$DetailedModel.meta.generatedAtUtc
            locale = [string]$DetailedModel.meta.locale
            period = $DetailedModel.meta.period
            defaultProject = $defaultProject
            statusBasis = "closed-overtime"
        }
        ui = Get-AnalyticsDepartmentReportUiStrings -Locale ([string]$DetailedModel.meta.locale)
        summary = [PSCustomObject]@{
            approvedSeconds = $approvedSeconds
            pendingSeconds = $pendingSeconds
            rejectedSeconds = $rejectedSeconds
            otherSeconds = $otherSeconds
            approvedEntryCount = @($sourceFacts | Where-Object { [string]$_.status -eq "approved" }).Count
            pendingEntryCount = @($sourceFacts | Where-Object { [string]$_.status -eq "pending" }).Count
            rejectedEntryCount = @($sourceFacts | Where-Object { [string]$_.status -eq "rejected" }).Count
            otherEntryCount = @($sourceFacts | Where-Object { [string]$_.status -eq "other" }).Count
            entryCount = $sourceFacts.Count
            activeProjectCount = @($projectRows | Where-Object { [long]$_.totalSeconds -gt 0 }).Count
        }
        projects = $projectRows
        months = $monthRows
        sectors = $sectorRows
        payments = $paymentRows
        reasons = $reasonRows
        overtimeCodes = $overtimeCodeRows
        statuses = $statusRows
        quality = $DetailedModel.quality
    }
}

function Get-AnalyticsReportModel {
    param(
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate,
        [AllowNull()][string]$Locale,
        [AllowNull()][string]$ProjectCode,
        [AllowNull()][string]$ReportMode,
        [Parameter(Mandatory = $true)]$CurrentUser
    )

    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) {
        throw (New-Object System.UnauthorizedAccessException -ArgumentList "Manager access is required.")
    }

    $range = Resolve-AnalyticsReportDateRange -StartDate $StartDate -EndDate $EndDate
    $resolvedLocale = Resolve-AnalyticsReportLocale -Locale $Locale
    $resolvedProjectCode = Resolve-AnalyticsReportProjectCode -ProjectCode $ProjectCode
    $resolvedReportMode = Resolve-AnalyticsReportMode -ReportMode $ReportMode
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
            markerKey   = Get-AnalyticsReportProjectMarkerKey -ProjectCode $projectCode -MarkerKey $(if ($project.PSObject.Properties.Name -contains "markerKey") { [string]$project.markerKey } else { "" })
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
                    markerKey   = Get-AnalyticsReportProjectMarkerKey -ProjectCode $projectCode
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

    $detailedModel = [PSCustomObject]@{
        meta = [PSCustomObject]@{
            schemaVersion = 1
            reportMode = "detailed"
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

    if ($resolvedReportMode -eq "department") {
        return Get-AnalyticsDepartmentReportModel -DetailedModel $detailedModel
    }
    return $detailedModel
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
    :root{color-scheme:light;--bg:#fff;--panel:#fff;--text:#172033;--muted:#617084;--line:#dce3eb;--line-strong:#c5d0dc;--accent:#0868d7;--accent-dark:#064f9f;--accent-soft:#eaf3ff;--ink-soft:#eef2f6;--blue:#0868d7;--green:#16865a;--violet:#7558d8;--teal:#008994;--amber:#b56f00;--coral:#c43840;--pink:#b9477f;--indigo:#4f66c8;--graphite:#667085;--mint:#0f8f7a;--pending:#a96200;--rejected:#c43840}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased;-webkit-print-color-adjust:exact;print-color-adjust:exact}button,input,select{font:inherit;color:inherit}
    .page{width:min(1280px,calc(100% - 32px));margin:0 auto;padding:28px 0 48px}.hero{display:flex;justify-content:space-between;gap:24px;align-items:flex-start;padding:0 2px 18px}.eyebrow{font-size:.72rem;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:var(--accent)}h1{font-size:clamp(1.9rem,3vw,2.65rem);letter-spacing:-.04em;line-height:1.05;margin:.32rem 0}.subtitle,.meta,.hint{color:var(--muted)}.subtitle{font-size:1rem}.meta{font-size:.84rem;margin-top:.42rem}.report-meta{text-align:right;color:var(--muted);font-size:.82rem;line-height:1.6;white-space:nowrap}
    .scope-strip{display:flex;align-items:flex-start;gap:10px;padding:10px 13px;margin-bottom:12px;border:1px solid #cfe0f4;background:#f2f7fc;border-radius:9px;color:#42536a;font-size:.84rem}.scope-strip strong{color:var(--accent-dark);white-space:nowrap}.scope-strip span{min-width:0}
    .panel{background:var(--panel);border:1px solid var(--line);border-radius:11px;margin-bottom:12px}.filters{padding:14px;background:#fbfcfe}.filter-top{display:flex;gap:14px;align-items:end}.search-field{flex:1 1 320px}.filter-grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:10px;margin-top:10px}.field{min-width:0}.field label{display:block;font-size:.68rem;font-weight:800;letter-spacing:.07em;text-transform:uppercase;color:#57677a;margin:0 0 5px}.control{width:100%;min-height:38px;border:1px solid var(--line-strong);background:#fff;border-radius:7px;padding:8px 10px;transition:border-color .15s ease,box-shadow .15s ease}.control:hover{border-color:#90afd0}.control:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px rgba(8,104,215,.14)}input.control::placeholder{color:#8996a5}select.control{appearance:none;-webkit-appearance:none;cursor:pointer;padding-right:34px;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 16 16'%3E%3Cpath d='m4 6 4 4 4-4' fill='none' stroke='%23536273' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 10px center;background-size:16px}select.control option{background:#fff;color:var(--text)}
    .filter-actions{display:flex;gap:7px;align-items:center;flex-wrap:wrap}.button{min-height:38px;border:1px solid var(--line-strong);background:#fff;border-radius:7px;padding:8px 12px;font-weight:700;cursor:pointer;transition:border-color .15s ease,background-color .15s ease}.button:hover{border-color:#90afd0;background:#f3f7fb}.button:focus-visible{outline:none;box-shadow:0 0 0 3px rgba(8,104,215,.14)}.button.primary{background:var(--accent);border-color:var(--accent);color:#fff}.button.primary:hover{background:var(--accent-dark);border-color:var(--accent-dark)}.basis{margin:9px 1px 0;color:var(--muted);font-size:.8rem}
    .kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin:12px 0}.kpi{background:#fff;border:1px solid var(--line);border-radius:10px;padding:13px 14px;min-height:88px}.kpi:first-child{border-top:3px solid var(--accent)}.kpi-label{font-size:.68rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:800}.kpi-value{font-size:clamp(1.32rem,2.2vw,1.8rem);font-weight:760;letter-spacing:-.035em;margin-top:6px;font-variant-numeric:tabular-nums}.kpi-hint{color:var(--muted);font-size:.76rem;margin-top:2px}
    .section-head{display:flex;justify-content:space-between;gap:15px;align-items:end;padding:15px 16px 0}.section-head h2{margin:0;font-size:1rem;letter-spacing:-.012em}.section-head p{margin:3px 0 0;color:var(--muted);font-size:.8rem}.section-body{padding:13px 16px 16px}.executive-grid{display:grid;grid-template-columns:1.12fr .88fr;gap:12px;align-items:start}.analysis-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;align-items:start}
    .insight-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:9px}.insight-card{padding:11px;border:1px solid var(--line);border-radius:8px;background:#fbfcfe}.insight-label{display:block;color:var(--muted);font-size:.69rem;font-weight:800;letter-spacing:.06em;text-transform:uppercase}.insight-value{display:block;margin-top:5px;font-size:1.03rem;font-weight:760;letter-spacing:-.02em}.insight-detail{display:block;margin-top:2px;color:var(--muted);font-size:.78rem}
    .ranking-list{display:grid;gap:8px}.ranking-row{display:grid;grid-template-columns:minmax(170px,.9fr) minmax(150px,1.45fr) 104px;gap:11px;align-items:center;padding:8px 0;border-bottom:1px solid #edf0f4}.ranking-row:last-child{border-bottom:0}.ranking-row.is-selected{margin:0 -7px;padding:8px 7px;border-radius:7px;background:var(--accent-soft);border-bottom-color:transparent}.ranking-identity{min-width:0}.ranking-name{display:flex;align-items:center;gap:7px;min-width:0;font-weight:720}.ranking-name-text{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.ranking-meta{display:block;margin-top:2px;color:var(--muted);font-size:.75rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.project-marker{display:inline-block;flex:0 0 9px;width:9px;height:9px;background:var(--accent)}.project-marker.marker-circle{border-radius:50%}.project-marker.marker-square{border-radius:2px}.project-marker.marker-diamond{border-radius:1px;transform:rotate(45deg) scale(.8)}.project-marker.marker-triangle{clip-path:polygon(50% 0,100% 100%,0 100%)}.ranking-track{height:8px;background:var(--ink-soft);border-radius:999px;overflow:hidden}.ranking-fill{display:block;height:100%;min-width:2px;border-radius:inherit;background:var(--accent)}.ranking-row.project-row .ranking-fill{background:var(--project-color,var(--accent))}.ranking-value{text-align:right;font-variant-numeric:tabular-nums}.ranking-value strong{display:block;font-size:.91rem}.ranking-value span{display:block;color:var(--muted);font-size:.76rem}
    .trend{display:flex;align-items:end;gap:7px;height:170px;padding-top:18px;overflow-x:auto;border-bottom:1px solid var(--line)}.trend-item{display:flex;flex:1 0 64px;min-width:64px;height:100%;flex-direction:column;justify-content:end;align-items:center;gap:5px}.trend-value{font-size:.72rem;font-variant-numeric:tabular-nums;color:var(--muted)}.trend-track{width:30px;height:100px;display:flex;align-items:end;background:#f0f3f7;border-radius:4px 4px 0 0;overflow:hidden}.trend-bar{width:100%;min-height:2px;background:var(--accent);border-radius:4px 4px 0 0}.trend-label{font-size:.7rem;color:var(--muted);text-align:center;line-height:1.15;white-space:normal}
    .breakdown{display:grid;gap:7px}.breakdown-row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:center;padding:7px 0;border-bottom:1px solid #edf0f4}.breakdown-row:last-child{border-bottom:0}.breakdown-label{display:flex;align-items:center;min-width:0;font-weight:700}.breakdown-value{text-align:right;font-variant-numeric:tabular-nums}.breakdown-value strong{display:block;font-size:.9rem}.breakdown-value span{display:block;color:var(--muted);font-size:.75rem}.status-dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;background:var(--muted)}.status-dot.approved{background:var(--green)}.status-dot.pending{background:var(--pending)}.status-dot.rejected{background:var(--rejected)}
    .driver-columns{display:grid;grid-template-columns:1fr 1fr;gap:12px}.driver-column h3{margin:0 0 6px;font-size:.79rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}.driver-list{display:grid;gap:5px}.driver-item{display:flex;justify-content:space-between;gap:8px;padding:7px 0;border-bottom:1px solid #edf0f4;font-variant-numeric:tabular-nums}.driver-item:last-child{border-bottom:0}.driver-item strong{font-weight:730}.driver-item span{color:var(--muted);font-size:.78rem;text-align:right}
    .empty{padding:20px;text-align:center;color:var(--muted);background:#fafbfd;border:1px dashed var(--line-strong);border-radius:8px}.appendix{margin-top:12px;background:#fff;border:1px solid var(--line);border-radius:11px}.appendix>summary{cursor:pointer;padding:14px 16px;font-weight:760}.appendix>summary::marker{color:var(--accent)}.appendix-body{padding:0 12px 12px}.matrix-wrap,.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px}.matrix,.detail-table{width:100%;border-collapse:collapse;font-size:.8rem}.matrix th,.matrix td,.detail-table th,.detail-table td{border-bottom:1px solid var(--line);padding:8px 9px;text-align:left;white-space:nowrap}.matrix th,.detail-table th{position:sticky;top:0;background:#f4f7fa;z-index:1;font-size:.67rem;text-transform:uppercase;letter-spacing:.055em;color:#536273}.detail-table tbody tr:nth-child(even){background:#fafbfd}.detail-table tbody tr:hover{background:#f2f7fd}.matrix td:not(:first-child){text-align:center;font-variant-numeric:tabular-nums}.heat{border-radius:5px;background:var(--accent-soft)}.quality{border-color:#e3bd82;background:#fffdf8}.quality ul{margin:8px 0 0;padding-left:19px;color:var(--muted)}.quality[hidden]{display:none}.row-note{color:var(--muted);font-size:.78rem;margin-top:8px}
    @media(max-width:1050px){.filter-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.kpis{grid-template-columns:repeat(3,1fr)}.executive-grid,.analysis-grid{grid-template-columns:1fr}}@media(max-width:680px){.page{width:min(100% - 20px,1280px);padding-top:20px}.hero,.filter-top{display:block}.report-meta{text-align:left;white-space:normal;margin-top:9px}.filter-actions{margin-top:10px}.filter-grid{grid-template-columns:1fr 1fr}.kpis{grid-template-columns:1fr 1fr}.scope-strip{display:block}.scope-strip strong{display:block;margin-bottom:3px}.ranking-row{grid-template-columns:minmax(105px,1fr) minmax(80px,1fr) 72px;gap:7px}.ranking-meta{font-size:.68rem}.driver-columns{grid-template-columns:1fr}.section-head,.section-body{padding-left:12px;padding-right:12px}}@media print{@page{size:landscape;margin:11mm}body{background:#fff;color:#111}.page{width:100%;padding:0}.hero{padding-bottom:8px}.filters{display:none}.panel,.kpi,.appendix{box-shadow:none}.kpi,.insight-card{break-inside:avoid}.executive-grid,.analysis-grid{grid-template-columns:1fr 1fr}.ranking-row{break-inside:avoid}.appendix:not([open]){display:none}.table-wrap,.matrix-wrap{overflow:visible}.matrix th,.detail-table th{position:static}.matrix,.detail-table{font-size:7.5pt}.detail-table thead{display:table-header-group}.detail-table tr{break-inside:avoid}}
  </style>
</head>
<body>
  <main class="page">
    <header class="hero">
      <div><div class="eyebrow">SAPHIR</div><h1 id="reportTitle"></h1><div class="subtitle" id="reportSubtitle"></div></div>
      <div class="report-meta"><div id="reportPeriod"></div><div id="reportSnapshot"></div></div>
    </header>
    <div class="scope-strip"><strong id="scopeLabel"></strong><span id="scopeSummary"></span></div>
    <section class="panel filters" aria-label="Filters">
      <div class="filter-top">
        <div class="field search-field"><label id="searchLabel" for="searchFilter"></label><input class="control" id="searchFilter" type="search"></div>
        <div class="filter-actions"><button class="button" id="resetButton" type="button"></button><button class="button" id="printButton" type="button"></button><button class="button primary" id="csvButton" type="button"></button></div>
      </div>
      <div class="filter-grid">
        <div class="field"><label id="employeeLabel" for="employeeFilter"></label><select class="control" id="employeeFilter"></select></div>
        <div class="field"><label id="projectLabel" for="projectFilter"></label><select class="control" id="projectFilter"></select></div>
        <div class="field"><label id="sectorLabel" for="sectorFilter"></label><select class="control" id="sectorFilter"></select></div>
        <div class="field"><label id="statusLabel" for="statusFilter"></label><select class="control" id="statusFilter"></select></div>
        <div class="field"><label id="monthLabel" for="monthFilter"></label><select class="control" id="monthFilter"></select></div>
        <div class="field"><label id="paymentLabel" for="paymentFilter"></label><select class="control" id="paymentFilter"></select></div>
      </div>
      <p class="basis" id="basisText"></p>
    </section>
    <section class="kpis" aria-label="Summary">
      <article class="kpi"><div class="kpi-label" id="hoursKpiLabel"></div><div class="kpi-value" id="hoursKpi"></div></article>
      <article class="kpi"><div class="kpi-label" id="pendingHoursKpiLabel"></div><div class="kpi-value" id="pendingHoursKpi"></div></article>
      <article class="kpi"><div class="kpi-label" id="approvalRateKpiLabel"></div><div class="kpi-value" id="approvalRateKpi"></div></article>
      <article class="kpi"><div class="kpi-label" id="employeesKpiLabel"></div><div class="kpi-value" id="employeesKpi"></div></article>
      <article class="kpi"><div class="kpi-label" id="projectsKpiLabel"></div><div class="kpi-value" id="projectsKpi"></div></article>
    </section>
    <div class="executive-grid">
      <section class="panel"><div class="section-head"><div><h2 id="decisionHighlightsTitle"></h2></div></div><div class="section-body"><div class="insight-grid">
        <article class="insight-card"><span class="insight-label" id="topProjectLabel"></span><strong class="insight-value" id="topProjectValue"></strong><span class="insight-detail" id="topProjectDetail"></span></article>
        <article class="insight-card"><span class="insight-label" id="topEmployeeLabel"></span><strong class="insight-value" id="topEmployeeValue"></strong><span class="insight-detail" id="topEmployeeDetail"></span></article>
        <article class="insight-card"><span class="insight-label" id="concentrationLabel"></span><strong class="insight-value" id="concentrationValue"></strong><span class="insight-detail" id="concentrationDetail"></span></article>
        <article class="insight-card"><span class="insight-label" id="pendingDecisionLabel"></span><strong class="insight-value" id="pendingDecisionValue"></strong><span class="insight-detail" id="pendingDecisionDetail"></span></article>
      </div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="monthlyTrendTitle"></h2><p id="monthlyTrendHint"></p></div></div><div class="section-body"><div class="trend" id="monthlyTrend"></div></div></section>
    </div>
    <section class="panel"><div class="section-head"><div><h2 id="projectShareTitle"></h2><p id="projectShareHint"></p></div></div><div class="section-body"><div class="ranking-list" id="projectPortfolio"></div></div></section>
    <div class="analysis-grid">
      <section class="panel"><div class="section-head"><div><h2 id="contributorShareTitle"></h2><p id="contributorShareHint"></p></div></div><div class="section-body"><div class="ranking-list" id="employeeContributors"></div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="workflowTitle"></h2><p id="workflowHint"></p></div></div><div class="section-body"><div class="breakdown" id="statusBreakdown"></div></div></section>
    </div>
    <div class="analysis-grid">
      <section class="panel"><div class="section-head"><div><h2 id="paymentBreakdownTitle"></h2><p id="paymentBreakdownHint"></p></div></div><div class="section-body"><div class="breakdown" id="paymentBreakdown"></div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="driversTitle"></h2><p id="driversHint"></p></div></div><div class="section-body"><div class="driver-columns"><div class="driver-column"><h3 id="reasonsTitle"></h3><div class="driver-list" id="reasonDrivers"></div></div><div class="driver-column"><h3 id="overtimeCodesTitle"></h3><div class="driver-list" id="overtimeCodeDrivers"></div></div></div></div></section>
    </div>
    <details class="appendix" id="appendix"><summary><span id="appendixTitle"></span> <span class="hint" id="appendixHint"></span></summary><div class="appendix-body">
      <section class="panel quality" id="qualityPanel" hidden><div class="section-head"><div><h2 id="qualityTitle"></h2><p id="qualitySummary"></p></div></div><div class="section-body"><ul id="qualityList"></ul></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="matrixTitle"></h2><p id="matrixHint"></p></div></div><div class="section-body"><div class="matrix-wrap" id="matrixContainer"></div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="detailTitle"></h2></div></div><div class="section-body"><div class="table-wrap"><table class="detail-table"><thead id="detailHead"></thead><tbody id="detailBody"></tbody></table></div><div class="row-note" id="detailNote"></div></div></section>
    </div></details>
  </main>
  <script id="reportData" type="application/octet-stream">__REPORT_DATA_BASE64__</script>
  <script>
  (()=>{"use strict";
    const encoded=document.getElementById("reportData").textContent.trim(),bytes=Uint8Array.from(atob(encoded),c=>c.charCodeAt(0)),data=JSON.parse(new TextDecoder("utf-8").decode(bytes));
    const ui=data.ui,byId=id=>document.getElementById(id),employees=new Map(data.employees.map(item=>[item.reportEmployeeId,item])),projects=new Map(data.projects.map(item=>[item.projectCode,item]));
    const colors={blue:"var(--blue)",green:"var(--green)",violet:"var(--violet)",teal:"var(--teal)",amber:"var(--amber)",coral:"var(--coral)",pink:"var(--pink)",indigo:"var(--indigo)",graphite:"var(--graphite)",mint:"var(--mint)"};
    const normalize=value=>String(value||"").toLocaleLowerCase(data.meta.locale).normalize("NFD").replace(/[\u0300-\u036f]/g,"");
    const formatNumber=value=>new Intl.NumberFormat(data.meta.locale).format(Number(value||0));
    const formatHours=seconds=>{const hours=Number(seconds||0)/3600;return `${new Intl.NumberFormat(data.meta.locale,{minimumFractionDigits:hours%1?1:0,maximumFractionDigits:2}).format(hours)} ${ui.hours}`};
    const formatPercent=(value,total)=>total>0?new Intl.NumberFormat(data.meta.locale,{style:"percent",maximumFractionDigits:1}).format(Number(value||0)/total):"—";
    const statusLabel=value=>ui[value]||value||ui.other,paymentLabel=value=>ui[value]||value||"—";
    const projectLabel=project=>`${project.displayName||project.projectCode||"—"}${project.projectCode&&project.projectCode!==project.displayName?` (${project.projectCode})`:""}`;
    const employeeLabel=employee=>`${employee.displayName||"—"}${employee.archived?` (${ui.archived})`:""}`;
    function setText(id,value){const element=byId(id);if(element)element.textContent=value}
    function projectMarkerKey(project){return["circle","square","diamond","triangle"].includes(project&&project.markerKey)?project.markerKey:"circle"}
    function projectMarker(project){const marker=document.createElement("span");marker.className=`project-marker marker-${projectMarkerKey(project)}`;marker.style.background=colors[project&&project.colorKey]||"var(--accent)";marker.setAttribute("aria-hidden","true");return marker}
    function addOption(select,value,label){const option=document.createElement("option");option.value=value;option.textContent=label;select.appendChild(option)}
    function sortedUnique(values){return [...new Set(values.filter(Boolean))].sort((a,b)=>String(a).localeCompare(String(b),data.meta.locale,{sensitivity:"base"}))}
    function sum(facts){return facts.reduce((total,item)=>total+Number(item.durationSeconds||0),0)}
    function grouped(facts,keyFn){const map=new Map();facts.forEach(item=>{const key=keyFn(item);map.set(key,(map.get(key)||0)+Number(item.durationSeconds||0))});return map}
    function initializeText(){
      setText("reportTitle",ui.title);setText("reportSubtitle",ui.subtitle);setText("searchLabel",ui.search);byId("searchFilter").placeholder=ui.searchPlaceholder;
      setText("employeeLabel",ui.employee);setText("projectLabel",ui.project);setText("sectorLabel",ui.sector);setText("statusLabel",ui.status);setText("monthLabel",ui.month);setText("paymentLabel",ui.payment);
      setText("resetButton",ui.reset);setText("printButton",ui.print);setText("csvButton",ui.exportCsv);setText("basisText",ui.officialBasis);setText("scopeLabel",ui.scope);
      setText("hoursKpiLabel",ui.selectedHours);setText("pendingHoursKpiLabel",ui.pendingHours);setText("approvalRateKpiLabel",ui.approvalRate);setText("employeesKpiLabel",ui.activeEmployees);setText("projectsKpiLabel",ui.activeProjects);
      setText("decisionHighlightsTitle",ui.decisionHighlights);setText("topProjectLabel",ui.topProject);setText("topEmployeeLabel",ui.topEmployee);setText("concentrationLabel",ui.projectConcentration);setText("pendingDecisionLabel",ui.pendingDecision);
      setText("projectShareTitle",ui.projectShare);setText("projectShareHint",ui.projectShareHint);setText("contributorShareTitle",ui.contributorShare);setText("contributorShareHint",ui.contributorShareHint);setText("monthlyTrendTitle",ui.monthlyTrend);setText("monthlyTrendHint",ui.monthlyTrendHint);
      setText("workflowTitle",ui.workflow);setText("workflowHint",ui.workflowHint);setText("paymentBreakdownTitle",ui.paymentBreakdown);setText("paymentBreakdownHint",ui.paymentBreakdownHint);setText("driversTitle",ui.drivers);setText("driversHint",ui.driversHint);setText("reasonsTitle",ui.reasons);setText("overtimeCodesTitle",ui.overtimeCodes);
      setText("appendixTitle",ui.appendix);setText("appendixHint",ui.appendixHint);setText("matrixTitle",ui.employeeProject);setText("matrixHint",ui.limitedMatrix);setText("detailTitle",ui.detail);setText("qualityTitle",ui.qualityTitle);setText("qualitySummary",ui.qualitySummary);
      const period=data.meta.period.startDate||data.meta.period.endDate?`${ui.period}: ${data.meta.period.startDate||"…"} → ${data.meta.period.endDate||"…"}`:`${ui.period}: ${ui.allData}`;setText("reportPeriod",period);
      const generated=new Date(data.meta.generatedAtUtc);setText("reportSnapshot",`${ui.snapshot} ${new Intl.DateTimeFormat(data.meta.locale,{dateStyle:"medium",timeStyle:"short"}).format(generated)}`);
    }
    function initializeFilters(){
      const employeeSelect=byId("employeeFilter"),projectSelect=byId("projectFilter"),sectorSelect=byId("sectorFilter"),statusSelect=byId("statusFilter"),monthSelect=byId("monthFilter"),paymentSelect=byId("paymentFilter");
      addOption(employeeSelect,"",ui.allEmployees);data.employees.slice().sort((a,b)=>employeeLabel(a).localeCompare(employeeLabel(b),data.meta.locale,{sensitivity:"base"})).forEach(item=>addOption(employeeSelect,item.reportEmployeeId,employeeLabel(item)));
      addOption(projectSelect,"",ui.allProjects);data.projects.slice().sort((a,b)=>projectLabel(a).localeCompare(projectLabel(b),data.meta.locale,{sensitivity:"base"})).forEach(item=>addOption(projectSelect,item.projectCode,projectLabel(item)));projectSelect.value=data.meta.defaultProject||"";
      addOption(sectorSelect,"",ui.allSectors);sortedUnique(data.projects.map(item=>item.sector||ui.noSector)).forEach(value=>addOption(sectorSelect,value,value));
      addOption(statusSelect,"",ui.allStatuses);["approved","pending","rejected","other"].forEach(value=>addOption(statusSelect,value,statusLabel(value)));statusSelect.value=data.meta.defaultStatus||"approved";
      addOption(monthSelect,"",ui.allMonths);sortedUnique(data.facts.map(item=>item.month)).forEach(value=>addOption(monthSelect,value,formatMonth(value)));
      addOption(paymentSelect,"",ui.allPayments);sortedUnique(data.facts.map(item=>item.payment)).forEach(value=>addOption(paymentSelect,value,paymentLabel(value)));
    }
    function getState(){return{search:normalize(byId("searchFilter").value),employee:byId("employeeFilter").value,project:byId("projectFilter").value,sector:byId("sectorFilter").value,status:byId("statusFilter").value,month:byId("monthFilter").value,payment:byId("paymentFilter").value}}
    function matches(fact,state,options={}){const employee=employees.get(fact.employeeRef)||{},project=projects.get(fact.projectCode)||{};if(!options.ignoreEmployee&&state.employee&&fact.employeeRef!==state.employee)return false;if(!options.ignoreProject&&state.project&&fact.projectCode!==state.project)return false;if(state.sector&&(project.sector||ui.noSector)!==state.sector)return false;if(!options.ignoreStatus&&state.status&&fact.status!==state.status)return false;if(state.month&&fact.month!==state.month)return false;if(state.payment&&fact.payment!==state.payment)return false;if(state.search){const haystack=normalize([employee.displayName,project.projectCode,project.displayName,project.sector,fact.overtimeCode,fact.reasonCode,statusLabel(fact.status),paymentLabel(fact.payment)].join(" "));if(!state.search.split(/\s+/).every(token=>haystack.includes(token)))return false}return true}
    function formatMonth(month){const match=/^(\d{4})-(\d{2})$/.exec(String(month||""));if(!match)return String(month||"");return new Intl.DateTimeFormat(data.meta.locale,{month:"short",year:"numeric"}).format(new Date(Date.UTC(Number(match[1]),Number(match[2])-1,1)))}
    function empty(container){container.replaceChildren();const node=document.createElement("div");node.className="empty";node.textContent=ui.noData;container.appendChild(node)}
    function renderScope(state){const parts=[];if(state.employee)parts.push(`${ui.employee}: ${employeeLabel(employees.get(state.employee)||{})}`);if(state.project)parts.push(`${ui.project}: ${projectLabel(projects.get(state.project)||{})}`);if(state.sector)parts.push(`${ui.sector}: ${state.sector}`);if(state.status)parts.push(`${ui.status}: ${statusLabel(state.status)}`);if(state.month)parts.push(`${ui.month}: ${formatMonth(state.month)}`);if(state.payment)parts.push(`${ui.payment}: ${paymentLabel(state.payment)}`);if(state.search)parts.push(`${ui.search}: ${byId("searchFilter").value.trim()}`);setText("scopeSummary",parts.length?parts.join(" · "):ui.scopeAll)}
    function renderKpis(facts,workflowFacts){const positiveFacts=facts.filter(item=>Number(item.durationSeconds||0)>0),approved=workflowFacts.filter(item=>item.status==="approved"),pending=workflowFacts.filter(item=>item.status==="pending"),rejected=workflowFacts.filter(item=>item.status==="rejected"),decided=sum(approved)+sum(rejected);setText("hoursKpi",formatHours(sum(facts)));setText("pendingHoursKpi",formatHours(sum(pending)));setText("approvalRateKpi",formatPercent(sum(approved),decided));setText("employeesKpi",formatNumber(new Set(positiveFacts.map(item=>item.employeeRef)).size));setText("projectsKpi",formatNumber(new Set(positiveFacts.map(item=>item.projectCode)).size))}
    function aggregate(facts,keyFn){const rows=new Map();facts.forEach(fact=>{const key=keyFn(fact),row=rows.get(key)||{key,total:0,entries:0,employees:new Set(),projects:new Set()};row.total+=Number(fact.durationSeconds||0);row.entries++;row.employees.add(fact.employeeRef);row.projects.add(fact.projectCode);rows.set(key,row)});return [...rows.values()]}
    function renderRankingRow(container,row,total,options={}){const wrapper=document.createElement("div"),identity=document.createElement("div"),name=document.createElement("div"),nameText=document.createElement("span"),meta=document.createElement("span"),track=document.createElement("div"),fill=document.createElement("span"),value=document.createElement("div"),hours=document.createElement("strong"),share=document.createElement("span");wrapper.className=`ranking-row${options.project?" project-row":""}${options.selected?" is-selected":""}`;identity.className="ranking-identity";name.className="ranking-name";nameText.className="ranking-name-text";nameText.textContent=options.label;name.title=options.label;if(options.project)name.appendChild(projectMarker(options.project));name.appendChild(nameText);meta.className="ranking-meta";meta.textContent=options.meta;identity.append(name,meta);track.className="ranking-track";fill.className="ranking-fill";fill.style.width=`${total?Math.max(0,row.total/total*100):0}%`;if(options.project)fill.style.setProperty("--project-color",colors[options.project.colorKey]||"var(--accent)");track.appendChild(fill);value.className="ranking-value";hours.textContent=formatHours(row.total);share.textContent=formatPercent(row.total,total);value.append(hours,share);wrapper.append(identity,track,value);container.appendChild(wrapper)}
    function renderProjectPortfolio(scopeFacts,workflowScopeFacts,state){const container=byId("projectPortfolio"),total=sum(scopeFacts),pendingByProject=grouped(workflowScopeFacts.filter(item=>item.status==="pending"),item=>item.projectCode),rows=aggregate(scopeFacts,item=>item.projectCode).filter(row=>row.total>0).sort((a,b)=>b.total-a.total);container.replaceChildren();if(!rows.length){empty(container);return}const selected=state.project,visible=rows.slice(0,10),selectedRow=rows.find(row=>row.key===selected);if(selectedRow&&!visible.includes(selectedRow))visible.push(selectedRow);const visibleKeys=new Set(visible.map(row=>row.key));visible.forEach(row=>{const project=projects.get(row.key)||{projectCode:row.key,displayName:row.key};const pendingHours=pendingByProject.get(row.key)||0,meta=`${formatNumber(row.employees.size)} ${ui.contributors.toLocaleLowerCase(data.meta.locale)} · ${formatNumber(row.entries)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}${pendingHours?` · ${ui.pending}: ${formatHours(pendingHours)}`:""}`;renderRankingRow(container,row,total,{project,label:projectLabel(project),meta,selected:row.key===selected})});const otherRows=rows.filter(row=>!visibleKeys.has(row.key));if(otherRows.length){const other={key:"__other__",total:otherRows.reduce((value,row)=>value+row.total,0),entries:otherRows.reduce((value,row)=>value+row.entries,0),employees:new Set(otherRows.flatMap(row=>[...row.employees]))},pendingHours=otherRows.reduce((value,row)=>value+Number(pendingByProject.get(row.key)||0),0),meta=`${formatNumber(other.employees.size)} ${ui.contributors.toLocaleLowerCase(data.meta.locale)} · ${formatNumber(other.entries)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}${pendingHours?` · ${ui.pending}: ${formatHours(pendingHours)}`:""}`;renderRankingRow(container,other,total,{label:ui.otherProjects,meta})}setText("projectShareHint",`${ui.projectShareHint} ${ui.projectShareScope}`)}
    function renderEmployeeContributors(facts){const container=byId("employeeContributors"),total=sum(facts),rows=aggregate(facts,item=>item.employeeRef).filter(row=>row.total>0).sort((a,b)=>b.total-a.total).slice(0,10);container.replaceChildren();if(!rows.length){empty(container);return}rows.forEach(row=>{const employee=employees.get(row.key)||{},meta=`${formatNumber(row.projects.size)} ${ui.projects} · ${formatNumber(row.entries)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`;renderRankingRow(container,row,total,{label:employeeLabel(employee),meta})})}
    function renderInsights(facts,projectScopeFacts,workflowFacts){const projectRows=aggregate(projectScopeFacts,item=>item.projectCode).filter(row=>row.total>0).sort((a,b)=>b.total-a.total),employeeRows=aggregate(facts,item=>item.employeeRef).filter(row=>row.total>0).sort((a,b)=>b.total-a.total),projectTotal=sum(projectScopeFacts),employeeTotal=sum(facts),topProject=projectRows[0],topEmployee=employeeRows[0],topThree=projectRows.slice(0,3).reduce((value,row)=>value+row.total,0),pending=workflowFacts.filter(item=>item.status==="pending"),pendingHours=sum(pending);setText("topProjectValue",topProject?projectLabel(projects.get(topProject.key)||{projectCode:topProject.key,displayName:topProject.key}):ui.noActivity);setText("topProjectDetail",topProject?`${formatHours(topProject.total)} · ${formatPercent(topProject.total,projectTotal)}`:"—");setText("topEmployeeValue",topEmployee?employeeLabel(employees.get(topEmployee.key)||{}):ui.noActivity);setText("topEmployeeDetail",topEmployee?`${formatHours(topEmployee.total)} · ${formatPercent(topEmployee.total,employeeTotal)}`:"—");setText("concentrationValue",formatPercent(topThree,projectTotal));setText("concentrationDetail",`${formatNumber(Math.min(3,projectRows.length))} ${ui.projects}`);setText("pendingDecisionValue",formatHours(pendingHours));setText("pendingDecisionDetail",`${formatNumber(pending.length)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`)}
    function getPeriodMonths(facts){const start=data.meta.period.startDate,end=data.meta.period.endDate;if(!/^\d{4}-\d{2}-\d{2}$/.test(start||"")||!/^\d{4}-\d{2}-\d{2}$/.test(end||""))return sortedUnique(facts.map(item=>item.month));const cursor=new Date(`${start}T00:00:00Z`),last=new Date(`${end}T00:00:00Z`),months=[];cursor.setUTCDate(1);last.setUTCDate(1);while(cursor<=last&&months.length<120){months.push(`${cursor.getUTCFullYear()}-${String(cursor.getUTCMonth()+1).padStart(2,"0")}`);cursor.setUTCMonth(cursor.getUTCMonth()+1)}return months}
    function renderTrend(facts){const container=byId("monthlyTrend"),totals=grouped(facts,item=>item.month),months=getPeriodMonths(facts),rows=months.map(month=>[month,totals.get(month)||0]),max=Math.max(1,...rows.map(row=>row[1]));container.replaceChildren();if(!facts.length){empty(container);return}rows.forEach(([month,total])=>{const item=document.createElement("div"),value=document.createElement("div"),track=document.createElement("div"),bar=document.createElement("div"),label=document.createElement("div");item.className="trend-item";value.className="trend-value";value.textContent=formatHours(total);track.className="trend-track";bar.className="trend-bar";bar.style.height=`${Math.max(2,total/max*100)}%`;track.appendChild(bar);label.className="trend-label";label.textContent=formatMonth(month);item.title=`${formatMonth(month)}: ${formatHours(total)}`;item.append(value,track,label);container.appendChild(item)})}
    function renderBreakdown(container,items,labelFn,showStatus=false){container.replaceChildren();const active=items.map(([key,facts])=>({key,facts,total:sum(facts)})).filter(item=>item.total>0);if(!active.length){empty(container);return}const total=active.reduce((value,item)=>value+item.total,0);active.forEach(item=>{const row=document.createElement("div"),label=document.createElement("div"),value=document.createElement("div"),hours=document.createElement("strong"),share=document.createElement("span");row.className="breakdown-row";label.className="breakdown-label";if(showStatus){const dot=document.createElement("span");dot.className=`status-dot ${item.key}`;label.appendChild(dot)}label.appendChild(document.createTextNode(labelFn(item.key)));value.className="breakdown-value";hours.textContent=formatHours(item.total);share.textContent=`${formatPercent(item.total,total)} · ${formatNumber(item.facts.length)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`;value.append(hours,share);row.append(label,value);container.appendChild(row)})}
    function renderDrivers(container,facts,keyFn){container.replaceChildren();const total=sum(facts),rows=aggregate(facts,keyFn).filter(row=>row.total>0).sort((a,b)=>b.total-a.total).slice(0,5);if(!rows.length){empty(container);return}rows.forEach(row=>{const item=document.createElement("div"),label=document.createElement("strong"),value=document.createElement("span");item.className="driver-item";label.textContent=row.key||"—";value.textContent=`${formatHours(row.total)} · ${formatPercent(row.total,total)}`;item.append(label,value);container.appendChild(item)})}
    function renderMatrix(facts){const container=byId("matrixContainer"),employeeTotals=grouped(facts,item=>item.employeeRef),projectTotals=grouped(facts,item=>item.projectCode),employeeKeys=[...employeeTotals.keys()].sort((a,b)=>employeeTotals.get(b)-employeeTotals.get(a)).slice(0,25),projectKeys=[...projectTotals.keys()].sort((a,b)=>projectTotals.get(b)-projectTotals.get(a)).slice(0,12);container.replaceChildren();if(!employeeKeys.length||!projectKeys.length){empty(container);return}const table=document.createElement("table"),head=document.createElement("thead"),headRow=document.createElement("tr"),corner=document.createElement("th");table.className="matrix";corner.textContent=ui.employee;headRow.appendChild(corner);projectKeys.forEach(key=>{const th=document.createElement("th"),project=projects.get(key)||{};th.append(projectMarker(project),document.createTextNode(` ${project.displayName||key}`));headRow.appendChild(th)});head.appendChild(headRow);const body=document.createElement("tbody"),pairTotals=new Map();facts.forEach(item=>{const key=`${item.employeeRef}\u0000${item.projectCode}`;pairTotals.set(key,(pairTotals.get(key)||0)+Number(item.durationSeconds||0))});const max=Math.max(1,...pairTotals.values());employeeKeys.forEach(employeeKey=>{const row=document.createElement("tr"),name=document.createElement("th");name.textContent=(employees.get(employeeKey)||{}).displayName||"—";row.appendChild(name);projectKeys.forEach(projectKey=>{const seconds=pairTotals.get(`${employeeKey}\u0000${projectKey}`)||0,cell=document.createElement("td");cell.textContent=seconds?formatHours(seconds):"—";if(seconds){cell.className="heat";cell.style.background=`color-mix(in srgb,var(--accent) ${Math.max(10,seconds/max*65)}%,transparent)`}row.appendChild(cell)});body.appendChild(row)});table.append(head,body);container.appendChild(table)}
    function renderDetails(facts){const head=byId("detailHead"),body=byId("detailBody"),columns=[ui.employee,ui.project,ui.sector,ui.date,ui.status,ui.duration,ui.payment,ui.overtimeCode,ui.reasonCode];head.replaceChildren();body.replaceChildren();const row=document.createElement("tr");columns.forEach(label=>{const th=document.createElement("th");th.textContent=label;row.appendChild(th)});head.appendChild(row);const sorted=facts.slice().sort((a,b)=>b.date.localeCompare(a.date)||(employees.get(a.employeeRef)||{}).displayName.localeCompare((employees.get(b.employeeRef)||{}).displayName,data.meta.locale)),visible=sorted.slice(0,500);visible.forEach(fact=>{const employee=employees.get(fact.employeeRef)||{},project=projects.get(fact.projectCode)||{},tr=document.createElement("tr"),values=[employee.displayName||"—",projectLabel(project),project.sector||ui.noSector,fact.date,statusLabel(fact.status),formatHours(fact.durationSeconds),paymentLabel(fact.payment),fact.overtimeCode||"—",fact.reasonCode||"—"];values.forEach((value,index)=>{const td=document.createElement("td");if(index===1){td.append(projectMarker(project),document.createTextNode(` ${value}`))}else if(index===4){const dot=document.createElement("span");dot.className=`status-dot ${fact.status}`;td.append(dot,document.createTextNode(value))}else td.textContent=value;tr.appendChild(td)});body.appendChild(tr)});setText("detailNote",ui.showingRows.replace("{shown}",visible.length).replace("{total}",sorted.length))}
    function renderQuality(){const labels={invalidDateCount:ui.qualityInvalidDate,invalidDurationCount:ui.qualityInvalidDuration,incompleteApprovedCount:ui.qualityIncompleteApproved,unknownEntryTypeCount:ui.qualityUnknownEntryType,unknownStatusCount:ui.qualityUnknownStatus,missingProjectCount:ui.qualityMissingProject,diverseEntryCount:ui.qualityDiverse},entries=Object.entries(data.quality).filter(([,value])=>Number(value)>0),panel=byId("qualityPanel"),list=byId("qualityList");panel.hidden=!entries.length;list.replaceChildren();entries.forEach(([key,value])=>{const item=document.createElement("li");item.textContent=`${labels[key]||key}: ${formatNumber(value)}`;list.appendChild(item)})}
    function render(){const state=getState(),facts=data.facts.filter(item=>matches(item,state)),projectScopeFacts=data.facts.filter(item=>matches(item,state,{ignoreProject:true})),workflowFacts=data.facts.filter(item=>matches(item,state,{ignoreStatus:true})),workflowProjectScopeFacts=data.facts.filter(item=>matches(item,state,{ignoreProject:true,ignoreStatus:true}));renderScope(state);renderKpis(facts,workflowFacts);renderInsights(facts,projectScopeFacts,workflowFacts);renderProjectPortfolio(projectScopeFacts,workflowProjectScopeFacts,state);renderEmployeeContributors(facts);renderTrend(facts);renderBreakdown(byId("statusBreakdown"),["approved","pending","rejected","other"].map(key=>[key,workflowFacts.filter(item=>item.status===key)]),statusLabel,true);renderBreakdown(byId("paymentBreakdown"),sortedUnique(facts.map(item=>item.payment)).map(key=>[key,facts.filter(item=>item.payment===key)]),paymentLabel);renderDrivers(byId("reasonDrivers"),facts,item=>item.reasonCode||"—");renderDrivers(byId("overtimeCodeDrivers"),facts,item=>item.overtimeCode||"—");renderMatrix(facts);renderDetails(facts)}
    function csvCell(value){let text=String(value??"");if(/^[=+\-@]/.test(text))text=`'${text}`;return `"${text.replace(/"/g,'""')}"`}
    function exportCsv(){const state=getState(),facts=data.facts.filter(item=>matches(item,state)),header=[ui.employee,ui.project,ui.sector,ui.date,ui.status,ui.duration,ui.payment,ui.overtimeCode,ui.reasonCode],rows=facts.map(fact=>{const employee=employees.get(fact.employeeRef)||{},project=projects.get(fact.projectCode)||{};return[employee.displayName||"",project.displayName||fact.projectCode,project.sector||"",fact.date,statusLabel(fact.status),Number(fact.durationSeconds||0)/3600,paymentLabel(fact.payment),fact.overtimeCode||"",fact.reasonCode||""]});const csv="\ufeff"+[header,...rows].map(row=>row.map(csvCell).join(",")).join("\r\n"),blob=new Blob([csv],{type:"text/csv;charset=utf-8"}),url=URL.createObjectURL(blob),link=document.createElement("a");link.href=url;link.download="saphir-analytics-filtered.csv";link.click();setTimeout(()=>URL.revokeObjectURL(url),0)}
    initializeText();initializeFilters();renderQuality();["searchFilter","employeeFilter","projectFilter","sectorFilter","statusFilter","monthFilter","paymentFilter"].forEach(id=>byId(id).addEventListener(id==="searchFilter"?"input":"change",render));byId("resetButton").addEventListener("click",()=>{["searchFilter","employeeFilter","sectorFilter","monthFilter","paymentFilter"].forEach(id=>byId(id).value="");byId("projectFilter").value=data.meta.defaultProject||"";byId("statusFilter").value=data.meta.defaultStatus||"approved";render()});byId("printButton").addEventListener("click",()=>window.print());byId("csvButton").addEventListener("click",exportCsv);render();
  })();
  </script>
</body>
</html>
'@
}

function Get-AnalyticsDepartmentReportHtmlTemplate {
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
    :root{color-scheme:light;--bg:#fff;--panel:#fff;--text:#172033;--muted:#617084;--line:#dce3eb;--strong-line:#c5d0dc;--accent:#0868d7;--accent-dark:#064f9f;--accent-soft:#eaf3ff;--blue:#0868d7;--green:#16865a;--violet:#7558d8;--teal:#008994;--amber:#b56f00;--coral:#c43840;--pink:#b9477f;--indigo:#4f66c8;--graphite:#667085;--mint:#0f8f7a;--pending:#a96200;--rejected:#c43840}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased;-webkit-print-color-adjust:exact;print-color-adjust:exact}button{font:inherit;color:inherit}.page{width:min(1280px,calc(100% - 32px));margin:0 auto;padding:28px 0 44px}.hero{display:flex;justify-content:space-between;gap:24px;align-items:flex-start;padding:0 2px 17px}.eyebrow{font-size:.72rem;font-weight:800;letter-spacing:.14em;text-transform:uppercase;color:var(--accent)}h1{font-size:clamp(1.9rem,3vw,2.6rem);letter-spacing:-.04em;line-height:1.05;margin:.32rem 0}.subtitle,.meta,.hint{color:var(--muted)}.subtitle{font-size:1rem}.meta{font-size:.84rem;margin-top:.42rem}.report-meta{text-align:right;color:var(--muted);font-size:.82rem;line-height:1.6;white-space:nowrap}.scope-strip{display:flex;align-items:flex-start;gap:10px;padding:10px 13px;margin-bottom:12px;border:1px solid #cfe0f4;background:#f2f7fc;border-radius:9px;color:#42536a;font-size:.84rem}.scope-strip strong{color:var(--accent-dark);white-space:nowrap}.scope-strip span{min-width:0}.actions{display:flex;justify-content:flex-end;gap:8px;margin:-3px 0 12px}.button{min-height:36px;border:1px solid var(--strong-line);background:#fff;border-radius:7px;padding:7px 11px;font-weight:700;cursor:pointer}.button:hover{border-color:#90afd0;background:#f3f7fb}.button.primary{background:var(--accent);border-color:var(--accent);color:#fff}.button.primary:hover{background:var(--accent-dark);border-color:var(--accent-dark)}.button:focus-visible{outline:none;box-shadow:0 0 0 3px rgba(8,104,215,.14)}
    .kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin:12px 0}.kpi{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:13px 14px;min-height:88px}.kpi:first-child{border-top:3px solid var(--accent)}.kpi-label{font-size:.68rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:800}.kpi-value{font-size:clamp(1.32rem,2.2vw,1.8rem);font-weight:760;letter-spacing:-.035em;margin-top:6px;font-variant-numeric:tabular-nums}.kpi-hint{color:var(--muted);font-size:.76rem;margin-top:2px}.panel{border:1px solid var(--line);border-radius:11px;background:var(--panel);margin-bottom:12px}.section-head{display:flex;justify-content:space-between;gap:15px;align-items:end;padding:15px 16px 0}.section-head h2{margin:0;font-size:1rem;letter-spacing:-.012em}.section-head p{margin:3px 0 0;color:var(--muted);font-size:.8rem}.section-body{padding:13px 16px 16px}.two-col{display:grid;grid-template-columns:1fr 1fr;gap:12px;align-items:start}.insight-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:9px}.insight-card{padding:11px;border:1px solid var(--line);border-radius:8px;background:#fbfcfe}.insight-label{display:block;color:var(--muted);font-size:.69rem;font-weight:800;letter-spacing:.06em;text-transform:uppercase}.insight-value{display:block;margin-top:5px;font-size:1.03rem;font-weight:760;letter-spacing:-.02em}.insight-detail{display:block;margin-top:2px;color:var(--muted);font-size:.78rem}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px}.data-table{width:100%;border-collapse:collapse;font-size:.82rem}.data-table th,.data-table td{border-bottom:1px solid var(--line);padding:9px 10px;text-align:left;white-space:nowrap}.data-table th{background:#f4f7fa;font-size:.67rem;text-transform:uppercase;letter-spacing:.055em;color:#536273}.data-table td.num,.data-table th.num{text-align:right;font-variant-numeric:tabular-nums}.data-table tbody tr:last-child td{border-bottom:0}.data-table tbody tr:hover{background:#f7faff}.project-name{display:flex;align-items:center;gap:7px;font-weight:720}.project-marker{display:inline-block;flex:0 0 9px;width:9px;height:9px;background:var(--accent)}.project-marker.marker-circle{border-radius:50%}.project-marker.marker-square{border-radius:2px}.project-marker.marker-diamond{border-radius:1px;transform:rotate(45deg) scale(.8)}.project-marker.marker-triangle{clip-path:polygon(50% 0,100% 100%,0 100%)}.trend{display:flex;align-items:end;gap:7px;height:180px;padding-top:18px;overflow-x:auto;border-bottom:1px solid var(--line)}.trend-item{display:flex;flex:1 0 70px;min-width:70px;height:100%;flex-direction:column;justify-content:end;align-items:center;gap:5px}.trend-value{font-size:.72rem;font-variant-numeric:tabular-nums;color:var(--muted)}.trend-track{width:32px;height:106px;display:flex;align-items:end;background:#f0f3f7;border-radius:4px 4px 0 0;overflow:hidden}.trend-bar{width:100%;min-height:2px;background:var(--accent);border-radius:4px 4px 0 0}.trend-label{font-size:.7rem;color:var(--muted);text-align:center;line-height:1.15;white-space:normal}.breakdown{display:grid;gap:7px}.breakdown-row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:center;padding:7px 0;border-bottom:1px solid #edf0f4}.breakdown-row:last-child{border-bottom:0}.breakdown-label{display:flex;align-items:center;min-width:0;font-weight:700}.breakdown-value{text-align:right;font-variant-numeric:tabular-nums}.breakdown-value strong{display:block;font-size:.9rem}.breakdown-value span{display:block;color:var(--muted);font-size:.75rem}.status-dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;background:var(--muted)}.status-dot.approved{background:var(--green)}.status-dot.pending{background:var(--pending)}.status-dot.rejected{background:var(--rejected)}.driver-columns{display:grid;grid-template-columns:1fr 1fr;gap:12px}.driver-column h3{margin:0 0 6px;font-size:.79rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}.driver-list{display:grid;gap:5px}.driver-item{display:flex;justify-content:space-between;gap:8px;padding:7px 0;border-bottom:1px solid #edf0f4;font-variant-numeric:tabular-nums}.driver-item:last-child{border-bottom:0}.driver-item strong{font-weight:730}.driver-item span{color:var(--muted);font-size:.78rem;text-align:right}.quality{border-color:#e3bd82;background:#fffdf8}.quality ul{margin:8px 0 0;padding-left:19px;color:var(--muted)}.quality[hidden]{display:none}.empty{padding:20px;text-align:center;color:var(--muted);background:#fafbfd;border:1px dashed var(--strong-line);border-radius:8px}
    @media(max-width:980px){.kpis{grid-template-columns:repeat(3,1fr)}.insight-grid{grid-template-columns:repeat(2,1fr)}.two-col{grid-template-columns:1fr}}@media(max-width:680px){.page{width:min(100% - 20px,1280px);padding-top:20px}.hero{display:block}.report-meta{text-align:left;white-space:normal;margin-top:9px}.actions{justify-content:flex-start;flex-wrap:wrap}.kpis{grid-template-columns:1fr 1fr}.scope-strip{display:block}.scope-strip strong{display:block;margin-bottom:3px}.driver-columns{grid-template-columns:1fr}.section-head,.section-body{padding-left:12px;padding-right:12px}}@media print{@page{size:landscape;margin:11mm}body{background:#fff;color:#111}.page{width:100%;padding:0}.hero{padding-bottom:8px}.actions{display:none}.panel,.kpi{box-shadow:none}.kpi,.insight-card,.panel{break-inside:avoid}.table-wrap{overflow:visible}.data-table{font-size:7.5pt}.data-table thead{display:table-header-group}.data-table tr{break-inside:avoid}}
  </style>
</head>
<body>
  <main class="page">
    <header class="hero">
      <div><div class="eyebrow">SAPHIR</div><h1 id="reportTitle"></h1><div class="subtitle" id="reportSubtitle"></div></div>
      <div class="report-meta"><div id="reportPeriod"></div><div id="reportSnapshot"></div></div>
    </header>
    <div class="scope-strip"><strong id="scopeLabel"></strong><span id="scopeSummary"></span></div>
    <div class="actions"><button class="button" type="button" id="printButton"></button><button class="button primary" type="button" id="csvButton"></button></div>
    <section class="kpis" aria-label="Summary">
      <article class="kpi"><div class="kpi-label" id="approvedHoursLabel"></div><div class="kpi-value" id="approvedHoursValue"></div><div class="kpi-hint" id="approvedHoursHint"></div></article>
      <article class="kpi"><div class="kpi-label" id="pendingHoursLabel"></div><div class="kpi-value" id="pendingHoursValue"></div><div class="kpi-hint" id="pendingHoursHint"></div></article>
      <article class="kpi"><div class="kpi-label" id="approvalRateLabel"></div><div class="kpi-value" id="approvalRateValue"></div><div class="kpi-hint" id="approvalRateHint"></div></article>
      <article class="kpi"><div class="kpi-label" id="activeProjectsLabel"></div><div class="kpi-value" id="activeProjectsValue"></div><div class="kpi-hint" id="activeProjectsHint"></div></article>
      <article class="kpi"><div class="kpi-label" id="entriesLabel"></div><div class="kpi-value" id="entriesValue"></div><div class="kpi-hint" id="entriesHint"></div></article>
    </section>
    <section class="panel"><div class="section-head"><div><h2 id="decisionHighlightsTitle"></h2></div></div><div class="section-body"><div class="insight-grid">
      <article class="insight-card"><span class="insight-label" id="topProjectLabel"></span><strong class="insight-value" id="topProjectValue"></strong><span class="insight-detail" id="topProjectDetail"></span></article>
      <article class="insight-card"><span class="insight-label" id="concentrationLabel"></span><strong class="insight-value" id="concentrationValue"></strong><span class="insight-detail" id="concentrationDetail"></span></article>
      <article class="insight-card"><span class="insight-label" id="peakMonthLabel"></span><strong class="insight-value" id="peakMonthValue"></strong><span class="insight-detail" id="peakMonthDetail"></span></article>
      <article class="insight-card"><span class="insight-label" id="pendingDecisionLabel"></span><strong class="insight-value" id="pendingDecisionValue"></strong><span class="insight-detail" id="pendingDecisionDetail"></span></article>
    </div></div></section>
    <section class="panel"><div class="section-head"><div><h2 id="projectPortfolioTitle"></h2><p id="projectPortfolioHint"></p></div></div><div class="section-body"><div class="table-wrap"><table class="data-table"><thead id="projectTableHead"></thead><tbody id="projectTableBody"></tbody></table></div></div></section>
    <div class="two-col">
      <section class="panel"><div class="section-head"><div><h2 id="monthlyTrendTitle"></h2><p id="monthlyTrendHint"></p></div></div><div class="section-body"><div class="trend" id="monthlyTrend"></div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="decisionTrackingTitle"></h2><p id="decisionTrackingHint"></p></div></div><div class="section-body"><div class="breakdown" id="statusBreakdown"></div></div></section>
    </div>
    <div class="two-col">
      <section class="panel"><div class="section-head"><div><h2 id="paymentBreakdownTitle"></h2><p id="paymentBreakdownHint"></p></div></div><div class="section-body"><div class="breakdown" id="paymentBreakdown"></div></div></section>
      <section class="panel"><div class="section-head"><div><h2 id="sectorBreakdownTitle"></h2><p id="sectorBreakdownHint"></p></div></div><div class="section-body"><div class="breakdown" id="sectorBreakdown"></div></div></section>
    </div>
    <section class="panel"><div class="section-head"><div><h2 id="driversTitle"></h2><p id="driversHint"></p></div></div><div class="section-body"><div class="driver-columns"><div class="driver-column"><h3 id="reasonsTitle"></h3><div class="driver-list" id="reasonDrivers"></div></div><div class="driver-column"><h3 id="overtimeCodesTitle"></h3><div class="driver-list" id="overtimeCodeDrivers"></div></div></div></div></section>
    <section class="panel quality" id="qualityPanel" hidden><div class="section-head"><div><h2 id="qualityTitle"></h2><p id="qualitySummary"></p></div></div><div class="section-body"><ul id="qualityList"></ul></div></section>
  </main>
  <script id="reportData" type="application/octet-stream">__REPORT_DATA_BASE64__</script>
  <script>
  (() => {
    "use strict";
    const encoded = document.getElementById("reportData").textContent.trim();
    const bytes = Uint8Array.from(atob(encoded), character => character.charCodeAt(0));
    const data = JSON.parse(new TextDecoder("utf-8").decode(bytes));
    const ui = data.ui;
    const byId = id => document.getElementById(id);
    const colors = { blue:"var(--blue)", green:"var(--green)", violet:"var(--violet)", teal:"var(--teal)", amber:"var(--amber)", coral:"var(--coral)", pink:"var(--pink)", indigo:"var(--indigo)", graphite:"var(--graphite)", mint:"var(--mint)" };
    const setText = (id, value) => { const node = byId(id); if (node) node.textContent = value == null ? "" : String(value); };
    const formatNumber = value => new Intl.NumberFormat(data.meta.locale).format(Number(value || 0));
    const formatHours = seconds => { const hours = Number(seconds || 0) / 3600; return `${new Intl.NumberFormat(data.meta.locale, { minimumFractionDigits: hours % 1 ? 1 : 0, maximumFractionDigits: 2 }).format(hours)} ${ui.hours}`; };
    const formatPercent = (value, total) => `${new Intl.NumberFormat(data.meta.locale, { style:"percent", minimumFractionDigits: total && value / total < .1 && value ? 1 : 0, maximumFractionDigits:1 }).format(total ? Number(value || 0) / Number(total) : 0)}`;
    const formatMonth = value => /^\d{4}-\d{2}$/.test(String(value || "")) ? new Intl.DateTimeFormat(data.meta.locale, { month:"short", year:"numeric", timeZone:"UTC" }).format(new Date(`${value}-01T00:00:00Z`)) : String(value || "—");
    const statusLabel = value => ({ approved:ui.approved, pending:ui.pending, rejected:ui.rejected, other:ui.other })[value] || ui.other;
    const paymentLabel = value => ({ cash:ui.cash, leave:ui.leave })[value] || String(value || "—");
    const projectLabel = project => project.displayName && project.displayName !== project.projectCode ? `${project.projectCode} — ${project.displayName}` : (project.displayName || project.projectCode || "—");
    const marker = project => { const node = document.createElement("span"); node.className = `project-marker marker-${project.markerKey || "circle"}`; node.style.background = colors[project.colorKey] || "var(--accent)"; return node; };
    const empty = container => { const node = document.createElement("div"); node.className = "empty"; node.textContent = ui.noData; container.replaceChildren(node); };
    const createCell = (row, value, className = "") => { const cell = document.createElement("td"); cell.className = className; cell.textContent = value; row.appendChild(cell); return cell; };
    const sum = (rows, property) => rows.reduce((total, row) => total + Number(row[property] || 0), 0);
    function renderBreakdown(containerId, rows, labelFn, options = {}) {
      const container = byId(containerId); container.replaceChildren();
      const active = rows.filter(row => Number(row.totalSeconds || 0) > 0);
      if (!active.length) { empty(container); return; }
      const total = sum(active, "totalSeconds");
      active.forEach(row => {
        const item = document.createElement("div"), label = document.createElement("div"), value = document.createElement("div"), hours = document.createElement("strong"), share = document.createElement("span");
        item.className = "breakdown-row"; label.className = "breakdown-label"; value.className = "breakdown-value";
        if (options.status) { const dot = document.createElement("span"); dot.className = `status-dot ${row.status}`; label.appendChild(dot); }
        label.appendChild(document.createTextNode(labelFn(row)));
        hours.textContent = formatHours(row.totalSeconds); share.textContent = `${formatPercent(row.totalSeconds, total)} · ${formatNumber(row.entryCount)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`;
        value.append(hours, share); item.append(label, value); container.appendChild(item);
      });
    }
    function renderDrivers(containerId, rows, property) {
      const container = byId(containerId); container.replaceChildren();
      const active = rows.filter(row => Number(row.approvedSeconds || 0) > 0).slice(0, 6);
      if (!active.length) { empty(container); return; }
      const total = Number(data.summary.approvedSeconds || 0);
      active.forEach(row => { const item = document.createElement("div"), label = document.createElement("strong"), value = document.createElement("span"); item.className = "driver-item"; label.textContent = row[property] || "—"; value.textContent = `${formatHours(row.approvedSeconds)} · ${formatPercent(row.approvedSeconds, total)}`; item.append(label, value); container.appendChild(item); });
    }
    function renderProjectTable() {
      const head = byId("projectTableHead"), body = byId("projectTableBody"), rows = data.projects.filter(row => Number(row.totalSeconds || 0) > 0), approvedTotal = Number(data.summary.approvedSeconds || 0);
      head.replaceChildren(); body.replaceChildren();
      const headerRow = document.createElement("tr"); [ui.project, ui.sector, ui.approved, ui.projectShare, ui.entries, ui.pending].forEach((label, index) => { const cell = document.createElement("th"); cell.textContent = label; if (index > 1) cell.className = "num"; headerRow.appendChild(cell); }); head.appendChild(headerRow);
      if (!rows.length) { const row = document.createElement("tr"), cell = document.createElement("td"); cell.colSpan = 6; cell.className = "empty"; cell.textContent = ui.noData; row.appendChild(cell); body.appendChild(row); return; }
      rows.forEach(project => { const row = document.createElement("tr"), projectCell = document.createElement("td"), identity = document.createElement("span"); identity.className = "project-name"; identity.append(marker(project), document.createTextNode(projectLabel(project))); projectCell.appendChild(identity); row.appendChild(projectCell); createCell(row, project.sector || ui.noSector); createCell(row, formatHours(project.approvedSeconds), "num"); createCell(row, formatPercent(project.approvedSeconds, approvedTotal), "num"); createCell(row, formatNumber(project.entryCount), "num"); createCell(row, formatHours(project.pendingSeconds), "num"); body.appendChild(row); });
    }
    function renderTrend() {
      const container = byId("monthlyTrend"), rows = data.months || []; container.replaceChildren();
      if (!rows.length) { empty(container); return; }
      const max = Math.max(1, ...rows.map(row => Number(row.approvedSeconds || 0)));
      rows.forEach(row => { const item = document.createElement("div"), value = document.createElement("div"), track = document.createElement("div"), bar = document.createElement("div"), label = document.createElement("div"); item.className = "trend-item"; value.className = "trend-value"; value.textContent = formatHours(row.approvedSeconds); track.className = "trend-track"; bar.className = "trend-bar"; bar.style.height = `${Math.max(2, Number(row.approvedSeconds || 0) / max * 100)}%`; track.appendChild(bar); label.className = "trend-label"; label.textContent = formatMonth(row.month); item.title = `${formatMonth(row.month)}: ${formatHours(row.approvedSeconds)}`; item.append(value, track, label); container.appendChild(item); });
    }
    function renderInsights() {
      const projects = data.projects.filter(row => Number(row.approvedSeconds || 0) > 0), approvedTotal = Number(data.summary.approvedSeconds || 0), topProject = projects[0], topThree = sum(projects.slice(0, 3), "approvedSeconds"), months = (data.months || []).filter(row => Number(row.approvedSeconds || 0) > 0).sort((left, right) => Number(right.approvedSeconds || 0) - Number(left.approvedSeconds || 0)), peak = months[0];
      setText("topProjectValue", topProject ? projectLabel(topProject) : ui.noActivity); setText("topProjectDetail", topProject ? `${formatHours(topProject.approvedSeconds)} · ${formatPercent(topProject.approvedSeconds, approvedTotal)}` : "—");
      setText("concentrationValue", formatPercent(topThree, approvedTotal)); setText("concentrationDetail", `${formatNumber(Math.min(3, projects.length))} ${ui.activeProjects.toLocaleLowerCase(data.meta.locale)}`);
      setText("peakMonthValue", peak ? formatMonth(peak.month) : ui.noActivity); setText("peakMonthDetail", peak ? formatHours(peak.approvedSeconds) : "—");
      setText("pendingDecisionValue", formatHours(data.summary.pendingSeconds)); setText("pendingDecisionDetail", `${formatNumber(data.summary.pendingEntryCount)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`);
    }
    function renderQuality() {
      const labels = { invalidDateCount:ui.qualityInvalidDate, invalidDurationCount:ui.qualityInvalidDuration, incompleteApprovedCount:ui.qualityIncompleteApproved, unknownEntryTypeCount:ui.qualityUnknownEntryType, unknownStatusCount:ui.qualityUnknownStatus, missingProjectCount:ui.qualityMissingProject, diverseEntryCount:ui.qualityDiverse };
      const entries = Object.entries(data.quality || {}).filter(([, value]) => Number(value) > 0), panel = byId("qualityPanel"), list = byId("qualityList"); panel.hidden = !entries.length; list.replaceChildren(); entries.forEach(([key, value]) => { const item = document.createElement("li"); item.textContent = `${labels[key] || key}: ${formatNumber(value)}`; list.appendChild(item); });
    }
    function csvCell(value) { let text = String(value == null ? "" : value); if (/^[=+\-@]/.test(text)) text = `'${text}`; return `"${text.replace(/"/g, '""')}"`; }
    function exportCsv() {
      const total = Number(data.summary.approvedSeconds || 0), header = [ui.project, ui.sector, ui.approved, ui.projectShare, ui.entries, ui.pending], rows = data.projects.filter(project => Number(project.totalSeconds || 0) > 0).map(project => [projectLabel(project), project.sector || ui.noSector, Number(project.approvedSeconds || 0) / 3600, formatPercent(project.approvedSeconds, total), project.entryCount, Number(project.pendingSeconds || 0) / 3600]);
      const csv = "\ufeff" + [header, ...rows].map(row => row.map(csvCell).join(",")).join("\r\n"), blob = new Blob([csv], { type:"text/csv;charset=utf-8" }), url = URL.createObjectURL(blob), link = document.createElement("a"); link.href = url; link.download = "saphir-analytics-department-projects.csv"; link.click(); setTimeout(() => URL.revokeObjectURL(url), 0);
    }
    const period = data.meta.period || {}, periodText = period.startDate || period.endDate ? `${period.startDate || "…"} — ${period.endDate || "…"}` : ui.allData, selectedProject = data.meta.defaultProject ? data.projects.find(project => project.projectCode === data.meta.defaultProject) : null;
    setText("reportTitle", ui.title); setText("reportSubtitle", ui.subtitle); setText("reportPeriod", `${ui.period}: ${periodText}`); setText("reportSnapshot", `${ui.snapshot} ${new Intl.DateTimeFormat(data.meta.locale, { dateStyle:"medium", timeStyle:"short" }).format(new Date(data.meta.generatedAtUtc))}`); setText("scopeLabel", ui.scope); setText("scopeSummary", selectedProject ? `${ui.selectedProject}: ${projectLabel(selectedProject)}` : ui.scopeAll);
    setText("printButton", ui.print); setText("csvButton", ui.exportCsv); setText("approvedHoursLabel", ui.approvedHours); setText("approvedHoursValue", formatHours(data.summary.approvedSeconds)); setText("approvedHoursHint", `${formatNumber(data.summary.approvedEntryCount)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`); setText("pendingHoursLabel", ui.pendingHours); setText("pendingHoursValue", formatHours(data.summary.pendingSeconds)); setText("pendingHoursHint", `${formatNumber(data.summary.pendingEntryCount)} ${ui.entries.toLocaleLowerCase(data.meta.locale)}`); setText("approvalRateLabel", ui.approvalRate); setText("approvalRateValue", formatPercent(data.summary.approvedSeconds, Number(data.summary.approvedSeconds || 0) + Number(data.summary.rejectedSeconds || 0))); setText("approvalRateHint", `${formatHours(data.summary.rejectedSeconds)} ${ui.rejected.toLocaleLowerCase(data.meta.locale)}`); setText("activeProjectsLabel", ui.activeProjects); setText("activeProjectsValue", formatNumber(data.summary.activeProjectCount)); setText("activeProjectsHint", ui.scopeAll); setText("entriesLabel", ui.entries); setText("entriesValue", formatNumber(data.summary.entryCount)); setText("entriesHint", ui.duration);
    setText("decisionHighlightsTitle", ui.decisionHighlights); setText("topProjectLabel", ui.topProject); setText("concentrationLabel", ui.projectConcentration); setText("peakMonthLabel", ui.peakMonth); setText("pendingDecisionLabel", ui.pendingDecision); setText("projectPortfolioTitle", ui.projectPortfolio); setText("projectPortfolioHint", `${ui.projectPortfolioHint} ${ui.aggregatedDataHint}`); setText("monthlyTrendTitle", ui.monthlyTrend); setText("monthlyTrendHint", ui.monthlyTrendHint); setText("decisionTrackingTitle", ui.decisionTracking); setText("decisionTrackingHint", ui.decisionTrackingHint); setText("paymentBreakdownTitle", ui.paymentBreakdown); setText("paymentBreakdownHint", ui.paymentBreakdownHint); setText("sectorBreakdownTitle", ui.sectorBreakdown); setText("sectorBreakdownHint", ui.sectorBreakdownHint); setText("driversTitle", ui.drivers); setText("driversHint", ui.driversHint); setText("reasonsTitle", ui.reasons); setText("overtimeCodesTitle", ui.overtimeCodes); setText("qualityTitle", ui.qualityTitle); setText("qualitySummary", ui.qualitySummary);
    renderInsights(); renderProjectTable(); renderTrend(); renderBreakdown("statusBreakdown", data.statuses || [], row => statusLabel(row.status), { status:true }); renderBreakdown("paymentBreakdown", data.payments || [], row => paymentLabel(row.payment)); renderBreakdown("sectorBreakdown", data.sectors || [], row => row.sector || ui.noSector); renderDrivers("reasonDrivers", data.reasons || [], "reasonCode"); renderDrivers("overtimeCodeDrivers", data.overtimeCodes || [], "overtimeCode"); renderQuality(); byId("printButton").addEventListener("click", () => window.print()); byId("csvButton").addEventListener("click", exportCsv);
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
    $template = if ([string]$Model.meta.reportMode -eq "department") {
        Get-AnalyticsDepartmentReportHtmlTemplate
    }
    else {
        Get-AnalyticsReportHtmlTemplate
    }
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
        [AllowNull()][string]$ReportMode,
        [Parameter(Mandatory = $true)]$CurrentUser
    )

    $model = Get-AnalyticsReportModel -StartDate $StartDate -EndDate $EndDate -Locale $Locale -ProjectCode $ProjectCode -ReportMode $ReportMode -CurrentUser $CurrentUser
    $html = ConvertTo-AnalyticsReportHtml -Model $model
    $rangeLabel = if ($model.meta.period.startDate -or $model.meta.period.endDate) {
        "{0}_{1}" -f $(if ($model.meta.period.startDate) { $model.meta.period.startDate } else { "start" }), $(if ($model.meta.period.endDate) { $model.meta.period.endDate } else { "end" })
    }
    else {
        "all"
    }

    $projectFileNameToken = ConvertTo-AnalyticsReportFileNameToken -Value ([string]$model.meta.defaultProject)
    $projectFileNamePart = if ([string]::IsNullOrWhiteSpace($projectFileNameToken)) { "" } else { "-$projectFileNameToken" }
    $reportModeFileNamePart = if ([string]$model.meta.reportMode -eq "department") { "-department" } else { "" }

    return [PSCustomObject]@{
        Html     = $html
        FileName = "saphir-analytics{0}{1}-{2}-{3}.html" -f $reportModeFileNamePart, $projectFileNamePart, $rangeLabel, [string]$model.meta.locale
        Model    = $model
    }
}
