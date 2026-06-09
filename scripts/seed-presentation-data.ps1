[CmdletBinding()]
param(
    [string]$AdminUsername = "admin",
    [string]$AdminPassword = "ChangeMe123!",
    [string]$EmployeePassword = "Demo123!",
    [int]$MonthsBack = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 12
    )

    if ($Value -is [string]) {
        $json = [string]$Value
    }
    elseif ($null -eq $Value) {
        $json = "null"
    }
    else {
        $json = $Value | ConvertTo-Json -Depth $Depth
        if ([string]::IsNullOrWhiteSpace([string]$json) -and ($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
            $json = "[]"
        }
    }

    Write-Utf8File -Path $Path -Content $json
}

function New-PasswordCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$Iterations = 120000
    )

    $saltBytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
    $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $saltBytes, $Iterations)
    try {
        $hashBytes = $deriveBytes.GetBytes(32)
    }
    finally {
        $deriveBytes.Dispose()
    }

    return [PSCustomObject]@{
        passwordSalt       = [System.Convert]::ToBase64String($saltBytes)
        passwordHash       = [System.Convert]::ToBase64String($hashBytes)
        passwordIterations = $Iterations
        passwordAlgorithm  = "PBKDF2-HMACSHA1"
    }
}

function New-UserRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Role,
        [string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$Password,
        [bool]$MustChangePassword = $false
    )

    $secret = New-PasswordCredential -Password $Password

    return [PSCustomObject]@{
        username           = $Username
        displayName        = $DisplayName
        role               = $Role
        employeeCode       = $EmployeeCode
        disabled           = $false
        mustChangePassword = $MustChangePassword
        createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
        passwordSalt       = $secret.passwordSalt
        passwordHash       = $secret.passwordHash
        passwordIterations = $secret.passwordIterations
        passwordAlgorithm  = $secret.passwordAlgorithm
    }
}

function ConvertTo-OrderedObject {
    param([Parameter(Mandatory = $true)][hashtable]$Map)

    $ordered = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object)) {
        $ordered[$key] = $Map[$key]
    }

    return [PSCustomObject]$ordered
}

function Round-ToNearestQuarterHour {
    param([Parameter(Mandatory = $true)][datetime]$Value)

    $minutes = [int][math]::Floor($Value.TimeOfDay.TotalMinutes + 7.5)
    $roundedMinutes = [int]([math]::Floor($minutes / 15) * 15)
    return $Value.Date.AddMinutes($roundedMinutes)
}

function New-EntryIdentifier {
    return ([Guid]::NewGuid().ToString("N"))
}

function Convert-SecondsToTimeText {
    param([int]$Seconds)

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    $span = [TimeSpan]::FromSeconds($Seconds)
    return ("{0:00}:{1:00}:{2:00}" -f [int][math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

function Get-IndexedItem {
    param(
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $source = @($Items)
    if ($source.Count -eq 0) {
        return $null
    }

    $safeIndex = $Index % $source.Count
    if ($safeIndex -lt 0) {
        $safeIndex += $source.Count
    }

    return $source[$safeIndex]
}

function New-DemoEntry {
    param(
        [Parameter(Mandatory = $true)]$Employee,
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][datetime]$ExactStart,
        [int]$DurationMinutes = 90,
        [string]$Status = "approved",
        [string]$OvertimeCode = "260",
        [string]$PaymentOption = "cash",
        [string]$ReasonCode = "D",
        [string]$Message = "",
        [bool]$Open = $false
    )

    $exactEnd = $ExactStart.AddMinutes($DurationMinutes)
    $roundedStart = Round-ToNearestQuarterHour -Value $ExactStart
    $roundedEnd = Round-ToNearestQuarterHour -Value $exactEnd
    if ($roundedEnd -le $roundedStart) {
        $roundedEnd = $roundedStart.AddMinutes(15)
    }

    $overtime = $null
    if (-not $Open) {
        $overtime = Convert-SecondsToTimeText -Seconds ([int]($roundedEnd - $roundedStart).TotalSeconds)
    }

    return [PSCustomObject]@{
        entryId       = New-EntryIdentifier
        name          = [string]$Employee.name
        date          = $roundedStart.ToString("yyyy-MM-dd")
        punchIn       = $roundedStart.ToString("HH:mm:ss")
        exactPunchIn  = $ExactStart.ToString("HH:mm:ss")
        punchOut      = if ($Open) { $null } else { $roundedEnd.ToString("HH:mm:ss") }
        exactPunchOut = if ($Open) { $null } else { $exactEnd.ToString("HH:mm:ss") }
        overtime      = $overtime
        status        = $Status
        message       = $Message
        projectCode   = [string]$Project.projectCode
        overtimeCode  = $OvertimeCode
        paymentOption = $PaymentOption
        reasonCode    = $ReasonCode
        seededAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
        seedProfile   = "presentation-30x10"
    }
}

function Sort-EntriesChronologically {
    param([System.Collections.IEnumerable]$Entries)

    return @(
        @($Entries) | Sort-Object @{
            Expression = {
                try {
                    [datetime]::ParseExact(("{0} {1}" -f [string]$_.date, [string]$_.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
                }
                catch {
                    [datetime]::MinValue
                }
            }
        }
    )
}

function Format-HistoryTime {
    param([Parameter(Mandatory = $true)][datetime]$Value)

    return $Value.ToString("HH'h'mm")
}

function Format-HistoryDate {
    param([Parameter(Mandatory = $true)][datetime]$Value)

    return $Value.ToString("MMMM dd, yyyy")
}

function New-HistoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$TargetEmployee,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][datetime]$Timestamp,
        [string]$Author = "Presentation Seed",
        [string]$AuthorUsername = "seed-script",
        [string]$AuthorRole = "superAdmin"
    )

    return [PSCustomObject]@{
        action         = $Action
        message        = $Message
        employee       = $TargetEmployee
        targetEmployee = $TargetEmployee
        author         = $Author
        authorUsername = $AuthorUsername
        authorRole     = $AuthorRole
        timestamp      = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
    }
}

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$dataPath = Join-Path -Path $repoRoot -ChildPath "data"
$lockPath = Join-Path -Path $dataPath -ChildPath ".locks"

if (-not (Test-Path -Path $dataPath)) {
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
}

Get-ChildItem -Path $dataPath -File -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
if (Test-Path -Path $lockPath) {
    Get-ChildItem -Path $lockPath -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

$overtimeCodes = @(
    [PSCustomObject]@{ code = ""; labelEn = "Overtime Code"; labelFr = "Code de temps supplementaire" },
    [PSCustomObject]@{ code = "260"; labelEn = "OVERTIME, Regular Working Day"; labelFr = "HEURES SUPPLEMENTAIRES, Jour ouvrable regulier" },
    [PSCustomObject]@{ code = "261"; labelEn = "OVERTIME, First Day of Rest"; labelFr = "HEURES SUPPLEMENTAIRES, Premier jour de repos" },
    [PSCustomObject]@{ code = "262"; labelEn = "OVERTIME, Second or Subsequent Day of Rest"; labelFr = "HEURES SUPPLEMENTAIRES, Deuxieme jour de repos subsequent" },
    [PSCustomObject]@{ code = "263"; labelEn = "OVERTIME, Designated Holiday"; labelFr = "HEURES SUPPLEMENTAIRES, Conge ferie" },
    [PSCustomObject]@{ code = "089"; labelEn = "TRAVEL TIME, Regular Working Day"; labelFr = "TEMPS de DEPLACEMENT, Jour ouvrable regulier" },
    [PSCustomObject]@{ code = "072"; labelEn = "TRAVEL TIME, Day of Rest"; labelFr = "TEMPS de DEPLACEMENT, Jour de repos" },
    [PSCustomObject]@{ code = "009"; labelEn = "CALL BACK"; labelFr = "RAPPEL AU TRAVAIL" },
    [PSCustomObject]@{ code = "050"; labelEn = "REPORTING PAY"; labelFr = "INDEMNITE DE PRESENCE" },
    [PSCustomObject]@{ code = "049"; labelEn = "PART TIME, Additional Hours"; labelFr = "TEMPS PARTIEL, Heures additionnelles" },
    [PSCustomObject]@{ code = "043"; labelEn = "PART TIME, Premium Pay for Work on a Holiday"; labelFr = "TEMPS PARTIEL, Prime pour le travail effectue lors d'un jour ferie" }
)

$paymentOptions = @(
    [PSCustomObject]@{ code = "cash"; labelEn = "Cash"; labelFr = "En espece" },
    [PSCustomObject]@{ code = "leave"; labelEn = "Leave"; labelFr = "Conge" }
)

$reasonCodes = @(
    [PSCustomObject]@{ code = ""; labelEn = "Reason"; labelFr = "Raison" },
    [PSCustomObject]@{ code = "A"; labelEn = "Emergency Situation"; labelFr = "Situation d'urgence" },
    [PSCustomObject]@{ code = "B"; labelEn = "Cost Effectiveness"; labelFr = "Cout-efficacite" },
    [PSCustomObject]@{ code = "C"; labelEn = "Exceptional Circumstances"; labelFr = "Circonstances exceptionnelles" },
    [PSCustomObject]@{ code = "D"; labelEn = "Significant Workload Increases"; labelFr = "Augmentation significative de charge de travail" },
    [PSCustomObject]@{ code = "E"; labelEn = "Unanticipated Absence"; labelFr = "Absence imprevue" },
    [PSCustomObject]@{ code = "F"; labelEn = "Vacant Position"; labelFr = "Poste vacant" },
    [PSCustomObject]@{ code = "G"; labelEn = "Other"; labelFr = "Autre" }
)

$employeeDefinitions = @(
    [PSCustomObject]@{ code = "000100000"; name = "Alexandre Roy"; role = "superAdmin"; noEntries = $false },
    [PSCustomObject]@{ code = "000100001"; name = "Camille Tremblay"; role = "admin"; noEntries = $false },
    [PSCustomObject]@{ code = "000100002"; name = "Marc-Andre Gagnon"; role = "admin"; noEntries = $false },
    [PSCustomObject]@{ code = "000100003"; name = "Sophie Leclerc"; role = "admin"; noEntries = $false },
    [PSCustomObject]@{ code = "000100004"; name = "Nadia Bouchard"; role = "admin"; noEntries = $false },
    [PSCustomObject]@{ code = "000100005"; name = "Peter-Nicholas Sarateanu"; role = "admin"; noEntries = $false },
    [PSCustomObject]@{ code = "000200001"; name = "Alice Johnson"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200002"; name = "Jane Smith"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200003"; name = "Michael Chen"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200004"; name = "Priya Patel"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200005"; name = "Remy Beaulieu"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200006"; name = "Isabelle Martin"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200007"; name = "Olivier Fortin"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200008"; name = "Maya Singh"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200009"; name = "Daniel Nguyen"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200010"; name = "Sarah Ouellet"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200011"; name = "Thomas Bergeron"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200012"; name = "Lea Mercier"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200013"; name = "Hugo Cote"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200014"; name = "Emma Wilson"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200015"; name = "Noah Brown"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200016"; name = "Chloe Tremblay"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200017"; name = "Gabriel Lavoie"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200018"; name = "Amelie Girard"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200019"; name = "Ethan Miller"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200020"; name = "Zoe Anderson"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200021"; name = "Samuel Richard"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200022"; name = "Jasmine Lee"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200023"; name = "Antoine Morin"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200024"; name = "Olivia Garcia"; role = "employee"; noEntries = $false },
    [PSCustomObject]@{ code = "000200025"; name = "Liam Clark"; role = "employee"; noEntries = $true },
    [PSCustomObject]@{ code = "000200026"; name = "Mila Roberts"; role = "employee"; noEntries = $true }
)

$projects = @(
    [PSCustomObject]@{ projectCode = "OPS-410"; projectName = "Month-End Close"; sector = "Operations"; admins = @("000100001", "000100005"); backupAdmins = @("000100004"); archived = $false },
    [PSCustomObject]@{ projectCode = "INF-330"; projectName = "Infrastructure Maintenance"; sector = "Infrastructure"; admins = @("000100002", "000100005"); backupAdmins = @("000100003"); archived = $false },
    [PSCustomObject]@{ projectCode = "APP-220"; projectName = "Portal Upgrade"; sector = "Applications"; admins = @("000100003", "000100005"); backupAdmins = @("000100002"); archived = $false },
    [PSCustomObject]@{ projectCode = "CLT-120"; projectName = "Client Rollout"; sector = "Client Services"; admins = @("000100004"); backupAdmins = @("000100001", "000100005"); archived = $false },
    [PSCustomObject]@{ projectCode = "SEC-510"; projectName = "Security Audit"; sector = "Security"; admins = @("000100002"); backupAdmins = @("000100000"); archived = $false },
    [PSCustomObject]@{ projectCode = "FIN-275"; projectName = "Financial Reporting"; sector = "Finance"; admins = @("000100001"); backupAdmins = @("000100003"); archived = $false },
    [PSCustomObject]@{ projectCode = "HR-180"; projectName = "HR Systems Update"; sector = "Corporate Services"; admins = @("000100004"); backupAdmins = @("000100001"); archived = $false },
    [PSCustomObject]@{ projectCode = "NET-640"; projectName = "Network Refresh"; sector = "Infrastructure"; admins = @("000100002"); backupAdmins = @("000100005"); archived = $false },
    [PSCustomObject]@{ projectCode = "DAT-390"; projectName = "Data Cleanup"; sector = "Data"; admins = @("000100003"); backupAdmins = @("000100004"); archived = $false },
    [PSCustomObject]@{ projectCode = "QMS-730"; projectName = "Quality Review"; sector = "Quality"; admins = @("000100000", "000100001"); backupAdmins = @("000100002"); archived = $false }
)

$employeesByCode = @{}
foreach ($employee in $employeeDefinitions) {
    $employeesByCode[[string]$employee.code] = $employee
}

$employeeNames = @{}
foreach ($employee in $employeeDefinitions) {
    $employeeNames[[string]$employee.code] = [string]$employee.name
}

$projectAssignments = @{}
$entryEmployees = @($employeeDefinitions | Where-Object { -not [bool]$_.noEntries })
for ($i = 0; $i -lt $entryEmployees.Count; $i++) {
    $employee = $entryEmployees[$i]
    $primary = Get-IndexedItem -Items $projects -Index $i
    $assigned = @($primary)
    if (($i % 3) -eq 0) {
        $assigned += (Get-IndexedItem -Items $projects -Index ($i + 4))
    }
    elseif (($i % 5) -eq 0) {
        $assigned += (Get-IndexedItem -Items $projects -Index ($i + 2))
    }
    $projectAssignments[[string]$employee.code] = @($assigned | Sort-Object projectCode -Unique)
}

$todayBase = (Get-Date).Date
$entryStartHours = @(6, 7, 15, 16, 17, 18, 19)
$entryStartMinutes = @(0, 15, 30, 45)
$durationOptions = @(45, 60, 75, 90, 105, 120, 150, 180, 210)
$overtimeCodeOptions = @("260", "261", "262", "263", "089", "072", "009", "050")
$paymentOptionCodes = @("cash", "leave")
$reasonCodeOptions = @("A", "B", "C", "D", "E", "F", "G")
$openEntryCodes = @("000200003", "000200014", "000100005")
$history = @()
$employeeEntryMap = @{}
$totalEntries = 0
$projectUsage = @{}

for ($employeeIndex = 0; $employeeIndex -lt $employeeDefinitions.Count; $employeeIndex++) {
    $employee = $employeeDefinitions[$employeeIndex]
    $employeeCode = [string]$employee.code
    $employeeEntries = @()

    if (-not [bool]$employee.noEntries) {
        $assignedProjects = @($projectAssignments[$employeeCode])
        $entryCount = 5 + ($employeeIndex % 5)
        if ([string]$employee.role -ne "employee") {
            $entryCount = 4 + ($employeeIndex % 4)
        }

        for ($entryIndex = 0; $entryIndex -lt $entryCount; $entryIndex++) {
            $project = $assignedProjects[$entryIndex % $assignedProjects.Count]
            $daysBack = 3 + (($employeeIndex * 11 + $entryIndex * 17) % ([math]::Max(45, $MonthsBack * 31)))
            $hour = [int](Get-IndexedItem -Items $entryStartHours -Index ($employeeIndex + $entryIndex))
            $minute = [int](Get-IndexedItem -Items $entryStartMinutes -Index ($employeeIndex * 2 + $entryIndex))
            $duration = [int](Get-IndexedItem -Items $durationOptions -Index ($employeeIndex + ($entryIndex * 3)))
            $exactOffset = (($employeeIndex + $entryIndex) % 13) - 6
            $exactStart = $todayBase.AddDays(-1 * $daysBack).AddHours($hour).AddMinutes($minute + $exactOffset)
            $statusSelector = ($employeeIndex + ($entryIndex * 2)) % 10
            $status = "approved"
            if ($statusSelector -eq 0 -or $statusSelector -eq 4) {
                $status = "pending"
            }
            elseif ($statusSelector -eq 7) {
                $status = "rejected"
            }
            if ([string]$employee.role -ne "employee" -and $entryIndex -eq 0) {
                $status = "pending"
            }

            $message = ""
            if ($status -eq "rejected") {
                $message = "A valider avec le superviseur avant approbation finale."
            }
            elseif (($entryIndex + $employeeIndex) % 12 -eq 0) {
                $message = "Note ajoutee pour le suivi mensuel."
            }

            $entry = New-DemoEntry `
                -Employee $employee `
                -Project $project `
                -ExactStart $exactStart `
                -DurationMinutes $duration `
                -Status $status `
                -OvertimeCode ([string](Get-IndexedItem -Items $overtimeCodeOptions -Index ($employeeIndex + $entryIndex))) `
                -PaymentOption ([string](Get-IndexedItem -Items $paymentOptionCodes -Index ($employeeIndex + $entryIndex))) `
                -ReasonCode ([string](Get-IndexedItem -Items $reasonCodeOptions -Index ($employeeIndex + $entryIndex))) `
                -Message $message

            $employeeEntries += $entry
            $projectUsage[[string]$project.projectCode] = $true
            $totalEntries++

            if ($history.Count -lt 34 -and ($entryIndex -eq 0 -or $status -ne "approved")) {
                $historyAction = if ($status -eq "approved") { "Approved" } elseif ($status -eq "rejected") { "Rejected" } else { "Add" }
                $historyTimestamp = $exactStart.AddMinutes([math]::Min($duration, 180) + 8)
                $historyMessage = if ($entry.punchOut) {
                    "{0} an entry for <strong>{1}</strong> on {2} from <strong>{3}</strong> to <strong>{4}</strong> for project <strong>{5}</strong>." -f $historyAction, [string]$employee.name, (Format-HistoryDate $exactStart), (Format-HistoryTime $exactStart), (Format-HistoryTime $exactStart.AddMinutes($duration)), [string]$project.projectCode
                }
                else {
                    "Added an active entry for <strong>{0}</strong> on {1} starting at <strong>{2}</strong> for project <strong>{3}</strong>." -f [string]$employee.name, (Format-HistoryDate $exactStart), (Format-HistoryTime $exactStart), [string]$project.projectCode
                }
                $history += New-HistoryRecord -Action $historyAction -TargetEmployee ([string]$employee.name) -Message $historyMessage -Timestamp $historyTimestamp
            }
        }

        if ($openEntryCodes -contains $employeeCode) {
            $project = $assignedProjects[0]
            $openStart = (Get-Date).AddMinutes(-1 * (65 + ($employeeIndex % 5) * 12))
            $openEntry = New-DemoEntry `
                -Employee $employee `
                -Project $project `
                -ExactStart $openStart `
                -DurationMinutes 90 `
                -Status "pending" `
                -OvertimeCode "260" `
                -PaymentOption "cash" `
                -ReasonCode "D" `
                -Message "" `
                -Open:$true
            $employeeEntries += $openEntry
            $projectUsage[[string]$project.projectCode] = $true
            $totalEntries++
            $history += New-HistoryRecord -Action "Add" -TargetEmployee ([string]$employee.name) -Message ("Added an active entry for <strong>{0}</strong> on {1} starting at <strong>{2}</strong> for project <strong>{3}</strong>." -f [string]$employee.name, (Format-HistoryDate $openStart), (Format-HistoryTime $openStart), [string]$project.projectCode) -Timestamp $openStart.AddMinutes(2)
        }
    }

    $employeeEntryMap[$employeeCode] = Sort-EntriesChronologically -Entries $employeeEntries
}

$users = @()
$users += New-UserRecord -Username $AdminUsername -DisplayName "Administrator" -Role "admin" -EmployeeCode $null -Password $AdminPassword -MustChangePassword:$false
foreach ($employee in $employeeDefinitions) {
    $users += New-UserRecord -Username ([string]$employee.code) -DisplayName ([string]$employee.name) -Role ([string]$employee.role) -EmployeeCode ([string]$employee.code) -Password $EmployeePassword -MustChangePassword:$false
}

Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "employeeNames.json") -Value (ConvertTo-OrderedObject -Map $employeeNames) -Depth 6
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "projects.json") -Value $projects -Depth 8
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "overtimeCodes.json") -Value $overtimeCodes -Depth 6
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "paymentOptions.json") -Value $paymentOptions -Depth 6
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "reasonCodes.json") -Value $reasonCodes -Depth 6

foreach ($employee in $employeeDefinitions) {
    $employeeCode = [string]$employee.code
    Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath ("{0}_data.json" -f $employeeCode)) -Value @($employeeEntryMap[$employeeCode]) -Depth 10
}

$history = @($history | Sort-Object @{ Expression = { try { [datetime]::ParseExact([string]$_.timestamp, "yyyy-MM-dd HH:mm:ss", $null) } catch { [datetime]::MinValue } } } -Descending | Select-Object -First 42)
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "history.json") -Value $history -Depth 8
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "users.json") -Value $users -Depth 8
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "sessions.json") -Value @() -Depth 5
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "sync-state.json") -Value ([PSCustomObject]@{
    version      = 1
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    category     = "seed"
    resource     = "presentation-30x10"
}) -Depth 5

Write-Host "Presentation data seed complete."
Write-Host ("Employees: {0}" -f $employeeDefinitions.Count)
Write-Host ("Projects: {0}" -f $projects.Count)
Write-Host ("Entries: {0}" -f $totalEntries)
Write-Host ("Projects with entries: {0}" -f $projectUsage.Keys.Count)
Write-Host "Super admin login: admin / ChangeMe123!"
Write-Host "Employee/admin login: employee code / Demo123!"
