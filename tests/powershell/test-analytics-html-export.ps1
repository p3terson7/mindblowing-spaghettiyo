$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', got '{2}'." -f $Message, $Expected, $Actual)
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/AnalyticsReportService.ps1")

$script:ReportProjects = @(
    [PSCustomObject]@{ projectCode = "P1"; projectName = "Projet </script><img src=x onerror=alert(1)>"; sector = "Ops"; colorKey = "mint"; archived = $false },
    [PSCustomObject]@{ projectCode = "ARCH"; projectName = "Ancien"; sector = "Archives"; archived = $true }
)
$script:ReportUsers = @(
    [PSCustomObject]@{ username = "000000001"; employeeCode = "000000001"; displayName = "Alice </script><img src=x onerror=alert(1)>"; role = "employee"; disabled = $false },
    [PSCustomObject]@{ username = "000000002"; employeeCode = "000000002"; displayName = "Benoît"; role = "employee"; disabled = $true },
    [PSCustomObject]@{ username = "000000003"; employeeCode = "000000003"; displayName = "Chloé"; role = "employee"; disabled = $false }
)

function New-TestEntry {
    param(
        [string]$Date,
        [string]$Overtime,
        [string]$Status = "approved",
        [string]$ProjectCode = "P1",
        [AllowNull()][string]$PunchOut = "18:00:00",
        [AllowNull()][string]$EntryType = "overtime",
        [bool]$Forgotten = $false
    )
    $entry = [PSCustomObject]@{
        date = $Date; punchIn = "17:00:00"; punchOut = $PunchOut; overtime = $Overtime
        status = $Status; projectCode = $ProjectCode; paymentOption = "cash"
        overtimeCode = "260"; reasonCode = "D"; forgottenClockOut = $Forgotten
    }
    if ($null -ne $EntryType) {
        $entry | Add-Member -NotePropertyName entryType -NotePropertyValue $EntryType
    }
    return $entry
}

$script:ReportEntries = @{
    "000000001" = @(
        (New-TestEntry -Date "2026-01-01" -Overtime "10:00:00"),
        (New-TestEntry -Date "2026-01-31" -Overtime "16:00:00"),
        (New-TestEntry -Date "2026-01-15" -Overtime "01:00:00" -Status " APPROVED " -EntryType $null),
        (New-TestEntry -Date "2026-01-15" -Overtime "02:00:00" -Status "pending"),
        (New-TestEntry -Date "2026-01-15" -Overtime "01:00:00" -Status "rejected"),
        (New-TestEntry -Date "2026-01-15" -Overtime "05:00:00" -EntryType "diverse"),
        (New-TestEntry -Date "2026-01-15" -Overtime "01:00:00" -PunchOut $null),
        (New-TestEntry -Date "2026-01-15" -Overtime "01:00:00" -EntryType "future-type"),
        (New-TestEntry -Date "not-a-date" -Overtime "01:00:00"),
        (New-TestEntry -Date "2026-01-15" -Overtime "broken"),
        (New-TestEntry -Date "2025-12-31" -Overtime "20:00:00"),
        (New-TestEntry -Date "2026-01-20" -Overtime "02:00:00" -ProjectCode "MISSING")
    )
    "000000002" = @((New-TestEntry -Date "2026-01-20" -Overtime "03:00:00" -ProjectCode "ARCH"))
    "000000003" = @()
}

function Test-CurrentUserManager { param($CurrentUser) return $true }
function Test-CurrentUserSuperAdmin { param($CurrentUser) return ([string]$CurrentUser.role -eq "superAdmin") }
function Test-ProjectArchived { param($Project) return ($Project.PSObject.Properties.Name -contains "archived" -and [bool]$Project.archived) }
function Get-Projects { return @($script:ReportProjects) }
function Get-ProjectAccessModelForCurrentUser {
    param($CurrentUser)
    $visibleProjects = if ([string]$CurrentUser.role -eq "restrictedAdmin") {
        @($script:ReportProjects | Where-Object { [string]$_.projectCode -eq "ARCH" })
    }
    else {
        @($script:ReportProjects)
    }
    $set = @{}; $visibleProjects | ForEach-Object { $set[[string]$_.projectCode] = $true }
    return [PSCustomObject]@{ Projects = $visibleProjects; ProjectCodes = @($set.Keys); ProjectCodeSet = $set }
}
function Get-Users { return @($script:ReportUsers) }
function Test-EmployeeUserRecord { param($UserRecord, [string]$EmployeeCode) return -not [string]::IsNullOrWhiteSpace([string]$UserRecord.employeeCode) }
function Get-UserEmployeeCodeValue { param($UserRecord) return [string]$UserRecord.employeeCode }
function Get-EmployeeName { param([string]$EmployeeCode) return $EmployeeCode }
function Get-EmployeeDataFilePath { param([string]$EmployeeCode) return $EmployeeCode }
function Get-CachedEmployeeEntriesForFile { param([string]$DataFile) return @($script:ReportEntries[$DataFile]) }
function Get-EntryDateOrNull {
    param($Entry)
    $value = [DateTime]::MinValue
    if ([DateTime]::TryParseExact([string]$Entry.date, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$value)) {
        return $value
    }
    return $null
}

$invalidDateRejected = $false
try { Resolve-AnalyticsReportDateRange -StartDate "01/01/2026" | Out-Null } catch [System.ArgumentException] { $invalidDateRejected = $true }
Assert-True $invalidDateRejected "Non-ISO report dates must be rejected."
$reverseRangeRejected = $false
try { Resolve-AnalyticsReportDateRange -StartDate "2026-02-01" -EndDate "2026-01-01" | Out-Null } catch [System.ArgumentException] { $reverseRangeRejected = $true }
Assert-True $reverseRangeRejected "A reversed report range must be rejected."
$invalidLocaleRejected = $false
try { Resolve-AnalyticsReportLocale -Locale "fr-CA" | Out-Null } catch [System.ArgumentException] { $invalidLocaleRejected = $true }
Assert-True $invalidLocaleRejected "The report route contract only accepts fr or en."

$currentUser = [PSCustomObject]@{ role = "superAdmin" }
$model = Get-AnalyticsReportModel -StartDate "2026-01-01" -EndDate "2026-01-31" -Locale "fr" -CurrentUser $currentUser
Assert-Equal 115200 $model.summary.approvedSeconds "Approved overtime total is incorrect."
Assert-Equal 5 $model.summary.approvedEntryCount "Approved entry count is incorrect."
Assert-Equal 7200 $model.summary.pendingSeconds "Pending duration should remain available as a separate workflow fact."
Assert-Equal 3600 $model.summary.rejectedSeconds "Rejected duration should remain available as a separate workflow fact."
Assert-Equal 3 @($model.employees).Count "Active zero-hour employees and archived employees with history must be retained."
Assert-Equal 1 $model.quality.diverseEntryCount "Diverse activity must be excluded from overtime and counted separately."
Assert-Equal 1 $model.quality.incompleteApprovedCount "Approved entries without a punch-out must be flagged."
Assert-Equal 1 $model.quality.unknownEntryTypeCount "Unknown time entry types must be flagged."
Assert-Equal 1 $model.quality.invalidDateCount "Invalid dates must be flagged."
Assert-Equal 1 $model.quality.invalidDurationCount "Invalid durations must be flagged."
Assert-Equal 1 $model.quality.missingProjectCount "Historical entries for a missing project must use a fallback project."
Assert-True (@($model.projects | Where-Object { $_.projectCode -eq "MISSING" }).Count -eq 1) "The missing project fallback was not added."
Assert-Equal "mint" ($model.projects | Where-Object { $_.projectCode -eq "P1" } | Select-Object -First 1).colorKey "The analytics model ignored the persisted project color."
Assert-True (@($model.facts | Where-Object { $_.date -eq "2025-12-31" }).Count -eq 0) "The start bound was not inclusive and strict."
Assert-True (@($model.facts | Where-Object { $_.date -eq "2026-01-01" }).Count -eq 1) "The start date should be included."
Assert-True (@($model.facts | Where-Object { $_.date -eq "2026-01-31" }).Count -eq 1) "The end date should be included."
Assert-Equal "" $model.meta.defaultProject "The department-wide report must not acquire a project filter by default."

$projectModel = Get-AnalyticsReportModel -StartDate "2026-01-01" -EndDate "2026-01-31" -Locale "fr" -ProjectCode " P1 " -CurrentUser $currentUser
Assert-Equal "P1" $projectModel.meta.defaultProject "The requested report project was not normalized into metadata."
Assert-Equal @($model.facts).Count @($projectModel.facts).Count "A default project must not silently discard other accessible report data."

$invalidProjectRejected = $false
try { Get-AnalyticsReportModel -ProjectCode "../P1" -CurrentUser $currentUser | Out-Null } catch [System.ArgumentException] { $invalidProjectRejected = $true }
Assert-True $invalidProjectRejected "An invalid project code must be rejected."
$missingProjectRejected = $false
try { Get-AnalyticsReportModel -ProjectCode "UNKNOWN" -CurrentUser $currentUser | Out-Null } catch [System.Collections.Generic.KeyNotFoundException] { $missingProjectRejected = $true }
Assert-True $missingProjectRejected "A super administrator must receive a not-found result for an unknown report project."
$inaccessibleProjectRejected = $false
try { Get-AnalyticsReportModel -ProjectCode "P1" -CurrentUser ([PSCustomObject]@{ role = "restrictedAdmin" }) | Out-Null } catch [System.UnauthorizedAccessException] { $inaccessibleProjectRejected = $true }
Assert-True $inaccessibleProjectRejected "An inaccessible report project must be rejected."
Assert-Equal "P-1" (ConvertTo-AnalyticsReportFileNameToken -Value "P 1") "Project filename tokens must replace unsafe spacing."

$export = New-AnalyticsReportExport -StartDate "2026-01-01" -EndDate "2026-01-31" -Locale "fr" -CurrentUser $currentUser
Assert-True $export.Html.StartsWith("<!doctype html>") "The report must be a complete HTML document."
Assert-Equal "saphir-analytics-2026-01-01_2026-01-31-fr.html" $export.FileName "The download filename changed."
Assert-True (-not $export.Html.Contains("Alice </script>")) "Untrusted names must not appear as executable inline markup."
Assert-True (-not $export.Html.Contains("<script src=")) "The standalone report must not load external JavaScript."
Assert-True (-not $export.Html.Contains("<link rel=")) "The standalone report must not load external stylesheets."
Assert-True (-not $export.Html.Contains("fetch(")) "The standalone report must not make network requests."
Assert-True (-not $export.Html.Contains("XMLHttpRequest")) "The standalone report must not make XHR requests."
Assert-True $export.Html.Contains('<meta name="color-scheme" content="light">') "The meeting report must explicitly remain in the light color scheme."
Assert-True $export.Html.Contains('--bg:#fff') "The meeting report must use a white canvas."
Assert-True (-not $export.Html.Contains('@media(prefers-color-scheme:dark)')) "The meeting report must not inherit a dark system theme."
Assert-True $export.Html.Contains('select.control{appearance:none') "Report dropdowns must use the styled select treatment."
Assert-True $export.Html.Contains('select.control option{background:#fff') "Report dropdown options must remain readable on white."
Assert-True $export.Html.Contains('projectSelect.value=data.meta.defaultProject||"";') "The standalone report does not initialize its project filter from metadata."
Assert-True $export.Html.Contains('byId("projectFilter").value=data.meta.defaultProject||"";') "Reset does not restore the report's default project."
foreach ($sensitiveField in @("employeeCode", "entryId", "exactPunchIn", "exactPunchOut", "workComment", "supervisorNote", "gc179Profile")) {
    Assert-True (-not $export.Html.Contains($sensitiveField)) "Sensitive field '$sensitiveField' leaked into the report."
}

$encodedMatch = [regex]::Match($export.Html, '<script id="reportData" type="application/octet-stream">([^<]+)</script>')
Assert-True $encodedMatch.Success "The report payload was not embedded as Base64."
$decodedJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedMatch.Groups[1].Value))
$decoded = $decodedJson | ConvertFrom-Json
Assert-True ([string]$decoded.employees[0].displayName -like "Alice*") "UTF-8 employee names did not survive the embedded payload."
Assert-True ([string]$decoded.projects[0].displayName -like "Ancien*" -or @($decoded.projects | Where-Object { [string]$_.displayName -like "Projet*" }).Count -eq 1) "Project labels did not survive the payload."

$projectExport = New-AnalyticsReportExport -StartDate "2026-01-01" -EndDate "2026-01-31" -Locale "fr" -ProjectCode "P1" -CurrentUser $currentUser
Assert-Equal "saphir-analytics-P1-2026-01-01_2026-01-31-fr.html" $projectExport.FileName "The project report filename is incorrect."
Assert-Equal "P1" $projectExport.Model.meta.defaultProject "The project export did not retain its initial filter."

$script:RouteStatus = 0
$script:RouteContentType = ""
$script:RouteFileName = ""
$script:RouteBytes = [byte[]]@()
$script:RouteMessage = ""
function respondWithDownload {
    param($response, [byte[]]$Bytes, [string]$ContentType, [string]$FileName)
    $script:RouteStatus = 200
    $script:RouteContentType = $ContentType
    $script:RouteFileName = $FileName
    $script:RouteBytes = $Bytes
}
function respondWithError {
    param($response, [int]$statusCode, [string]$message)
    $script:RouteStatus = $statusCode
    $script:RouteMessage = $message
}
function Invoke-AnalyticsReportTestRoute {
    param([Alias("Query")][string]$QueryText)
    $script:RouteStatus = 0
    $script:RouteContentType = ""
    $script:RouteFileName = ""
    $script:RouteBytes = [byte[]]@()
    $script:RouteMessage = ""
    $request = [PSCustomObject]@{
        HttpMethod = "GET"
        Url = [Uri]("http://localhost/stats/analytics-export{0}" -f $QueryText)
    }
    $response = [PSCustomObject]@{}
    $currentUser = [PSCustomObject]@{ role = "superAdmin" }
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/stats/analytics-export.routes.ps1")
    }
}

Invoke-AnalyticsReportTestRoute -Query "?startDate=2026-01-01&endDate=2026-01-31&locale=fr"
Assert-Equal 200 $script:RouteStatus "The analytics export route did not return a download."
Assert-Equal "text/html; charset=utf-8" $script:RouteContentType "The analytics report content type is incorrect."
Assert-Equal "saphir-analytics-2026-01-01_2026-01-31-fr.html" $script:RouteFileName "The route filename is incorrect."
Assert-True ($script:RouteBytes.Count -gt 1000) "The route returned an empty analytics report."

Invoke-AnalyticsReportTestRoute -Query "?startDate=2026-01-01&endDate=2026-01-31&locale=fr&projectCode=P1"
Assert-Equal 200 $script:RouteStatus "The project analytics export route did not return a download."
Assert-Equal "saphir-analytics-P1-2026-01-01_2026-01-31-fr.html" $script:RouteFileName "The project route filename is incorrect."
$routeProjectHtml = [System.Text.Encoding]::UTF8.GetString($script:RouteBytes)
$routePayloadMatch = [regex]::Match($routeProjectHtml, '<script id="reportData" type="application/octet-stream">([^<]+)</script>')
Assert-True $routePayloadMatch.Success "The project route report payload is missing."
$routePayload = ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($routePayloadMatch.Groups[1].Value))) | ConvertFrom-Json
Assert-Equal "P1" $routePayload.meta.defaultProject "The project route did not set the report's default project."

Invoke-AnalyticsReportTestRoute -Query "?startDate=bad&locale=fr"
Assert-Equal 400 $script:RouteStatus "An invalid start date must return HTTP 400."
Invoke-AnalyticsReportTestRoute -Query "?startDate=2026-02-01&endDate=2026-01-01&locale=fr"
Assert-Equal 400 $script:RouteStatus "A reversed date range must return HTTP 400."
Invoke-AnalyticsReportTestRoute -Query "?locale=fr-CA"
Assert-Equal 400 $script:RouteStatus "An unsupported locale must return HTTP 400."
Invoke-AnalyticsReportTestRoute -Query "?projectCode=..%2FP1&locale=fr"
Assert-Equal 400 $script:RouteStatus "An invalid project code must return HTTP 400."
Invoke-AnalyticsReportTestRoute -Query "?projectCode=UNKNOWN&locale=fr"
Assert-Equal 404 $script:RouteStatus "An unknown project must return HTTP 404 for a super administrator."

Write-Host "Standalone analytics HTML report model tests passed."
