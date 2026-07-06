[CmdletBinding()]
param(
    [string[]]$MonthKeys = @(),
    [int]$EntriesPerEmployeePerMonth = 40,
    [string]$StandardEmployeeCode = "000999150",
    [string]$StandardEmployeeName = "GC179 Standard Week Tester",
    [string]$CompressedEmployeeCode = "000999175",
    [string]$CompressedEmployeeName = "GC179 Compressed Week Tester",
    [string]$ProjectCode = "GC179-RULES",
    [string]$ProjectName = "GC179 Calculation Rules Test",
    [string]$Sector = "Testing",
    [string]$Password = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$backendDir = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend"

if (-not (Test-Path -Path $backendDir)) {
    throw "Unable to locate backend folder at $backendDir"
}

$scriptDir = $backendDir
. (Join-Path -Path $backendDir -ChildPath "lib/AdminContext.ps1")
. (Join-Path -Path $backendDir -ChildPath "lib/FileStore.ps1")
. (Join-Path -Path $backendDir -ChildPath "lib/CommonHelpers.ps1")
. (Join-Path -Path $backendDir -ChildPath "services/AuthService.ps1")
. (Join-Path -Path $backendDir -ChildPath "services/EntryService.ps1")

function Write-JsonLocked {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 10
    )

    $lockHandle = Acquire-ResourceLock -ResourcePath $Path
    try {
        Write-JsonAtomic -Path $Path -Value $Value -Depth $Depth
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

function Get-JsonArraySafe {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return @()
    }

    return @(Read-JsonArrayFile -Path $Path)
}

function Get-NameMapHashtable {
    $result = [ordered]@{}
    if (-not (Test-Path -Path $mappingFile)) {
        return $result
    }

    try {
        $raw = [System.IO.File]::ReadAllText($mappingFile)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $result
        }

        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) {
            return $result
        }

        foreach ($property in $parsed.PSObject.Properties) {
            $result[[string]$property.Name] = [string]$property.Value
        }
    }
    catch {
        return $result
    }

    return $result
}

function Get-CodeList {
    param(
        $Options,
        [string]$Fallback
    )

    $codes = @(
        @($Options) |
            Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains "code") -and -not [string]::IsNullOrWhiteSpace([string]$_.code) } |
            ForEach-Object { [string]$_.code }
    )

    if ($codes.Count -eq 0) {
        return @($Fallback)
    }

    return @($codes)
}

function Get-MonthStart {
    param([Parameter(Mandatory = $true)][string]$Value)

    try {
        return [DateTime]::ParseExact($Value, "yyyy-MM", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "MonthKeys must use yyyy-MM format. Example: -MonthKeys 2026-04,2026-05,2026-06"
    }
}

function Get-DefaultMonthKeys {
    $now = Get-Date
    $currentMonth = Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 0 -Second 0
    return @(
        $currentMonth.AddMonths(-3).ToString("yyyy-MM"),
        $currentMonth.AddMonths(-2).ToString("yyyy-MM"),
        $currentMonth.AddMonths(-1).ToString("yyyy-MM")
    )
}

function Get-SyncVersion {
    if (-not (Test-Path -Path $syncStateFile)) {
        return 0
    }

    try {
        $raw = [System.IO.File]::ReadAllText($syncStateFile)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return 0
        }

        $state = $raw | ConvertFrom-Json
        if ($null -eq $state -or -not ($state.PSObject.Properties.Name -contains "version")) {
            return 0
        }

        return [int]$state.version
    }
    catch {
        return 0
    }
}

function New-SeedUserRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$InitialPassword,
        [Parameter(Mandatory = $true)][bool]$CompressedWorkWeek,
        [Parameter(Mandatory = $true)][string]$Surname,
        [Parameter(Mandatory = $true)][string]$GivenName,
        [Parameter(Mandatory = $true)][string]$Initials,
        [Parameter(Mandatory = $true)][string]$Pri,
        [Parameter(Mandatory = $true)][string]$Position,
        [Parameter(Mandatory = $true)][string]$Level
    )

    $secret = New-PasswordCredential -Password $InitialPassword
    return [PSCustomObject]@{
        username           = $Code
        displayName        = $Name
        role               = "employee"
        employeeCode       = $Code
        timeEntryTypes     = @("overtime")
        gc179Profile       = [PSCustomObject]@{
            surname            = $Surname
            givenName          = $GivenName
            initials           = $Initials
            pri                = ConvertTo-Gc179PriText -Value $Pri
            position           = $Position
            level              = $Level
            compressedWorkWeek = $CompressedWorkWeek
        }
        disabled           = $false
        mustChangePassword = $false
        createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
        passwordSalt       = $secret.passwordSalt
        passwordHash       = $secret.passwordHash
        passwordIterations = $secret.passwordIterations
        passwordAlgorithm  = $secret.passwordAlgorithm
    }
}

function New-Gc179RuleEntry {
    param(
        [Parameter(Mandatory = $true)][DateTime]$StartTime,
        [Parameter(Mandatory = $true)][int]$DurationMinutes,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$OvertimeCode,
        [Parameter(Mandatory = $true)][string]$PaymentOption,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [int]$OffsetIndex = 0
    )

    $startOffsets = @(-6, -3, 2, 5, -1, 4)
    $endOffsets = @(4, -2, 6, -4, 1, 3)
    $exactStart = $StartTime.AddMinutes($startOffsets[$OffsetIndex % $startOffsets.Count])
    $exactEnd = $StartTime.AddMinutes($DurationMinutes).AddMinutes($endOffsets[$OffsetIndex % $endOffsets.Count])
    if ($exactEnd.Date -ne $exactStart.Date) {
        $exactEnd = $StartTime.AddMinutes($DurationMinutes)
    }

    $dateText = $StartTime.ToString("yyyy-MM-dd")
    $exactPunchIn = $exactStart.ToString("HH:mm:ss")
    $exactPunchOut = $exactEnd.ToString("HH:mm:ss")
    $punchInRounded = Convert-ToNearestQuarterHourText -Date $dateText -TimeText $exactPunchIn
    $punchOutRounded = Convert-ToNearestQuarterHourText -Date $dateText -TimeText $exactPunchOut
    $roundedStart = [DateTime]::ParseExact(("{0} {1}" -f $dateText, $punchInRounded), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $roundedEnd = [DateTime]::ParseExact(("{0} {1}" -f $dateText, $punchOutRounded), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    if ($roundedEnd -le $roundedStart) {
        $roundedEnd = $roundedStart.AddMinutes(15)
        $punchOutRounded = $roundedEnd.ToString("HH:mm:ss")
        $exactPunchOut = $punchOutRounded
    }

    return [PSCustomObject]@{
        entryId       = New-EntryIdentifier
        entryType     = "overtime"
        name          = $Name
        date          = $dateText
        punchIn       = $punchInRounded
        exactPunchIn  = $exactPunchIn
        punchOut      = $punchOutRounded
        exactPunchOut = $exactPunchOut
        overtime      = ($roundedEnd - $roundedStart).ToString("hh\:mm\:ss")
        status        = "approved"
        message       = "Seeded for GC179 Regular Workday calculation testing."
        projectCode   = $Project
        overtimeCode  = $OvertimeCode
        paymentOption = $PaymentOption
        reasonCode    = $ReasonCode
        seedBatchId   = $BatchId
        seededAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
        seedProfile   = "gc179-rule-months"
    }
}

function Sort-EntriesForStorage {
    param($Entries)

    return @(
        @($Entries) | Sort-Object @{
            Expression = {
                try {
                    [DateTime]::ParseExact(("{0} {1}" -f [string]$_.date, [string]$_.punchIn), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
                }
                catch {
                    [DateTime]::MinValue
                }
            }
        }
    )
}

function Add-EntryForDay {
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)][DateTime]$Day,
        [Parameter(Mandatory = $true)][int]$Hour,
        [Parameter(Mandatory = $true)][int]$Minute,
        [Parameter(Mandatory = $true)][int]$DurationMinutes,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$OvertimeCodes,
        [Parameter(Mandatory = $true)]$PaymentOptions,
        [Parameter(Mandatory = $true)]$ReasonCodes,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $start = Get-Date -Year $Day.Year -Month $Day.Month -Day $Day.Day -Hour $Hour -Minute $Minute -Second 0
    [void]$Entries.Add((New-Gc179RuleEntry `
        -StartTime $start `
        -DurationMinutes $DurationMinutes `
        -BatchId $BatchId `
        -Name $Name `
        -Project $Project `
        -OvertimeCode $OvertimeCodes[$Index % $OvertimeCodes.Count] `
        -PaymentOption $PaymentOptions[$Index % $PaymentOptions.Count] `
        -ReasonCode $ReasonCodes[$Index % $ReasonCodes.Count] `
        -OffsetIndex $Index))
}

function New-EntriesForMonth {
    param(
        [Parameter(Mandatory = $true)][DateTime]$MonthStart,
        [Parameter(Mandatory = $true)][int]$EntryCount,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$OvertimeCodes,
        [Parameter(Mandatory = $true)]$PaymentOptions,
        [Parameter(Mandatory = $true)]$ReasonCodes
    )

    $entries = New-Object System.Collections.ArrayList
    $daysInMonth = [DateTime]::DaysInMonth($MonthStart.Year, $MonthStart.Month)
    $index = 0

    for ($day = 1; $day -le $daysInMonth; $day++) {
        $currentDay = Get-Date -Year $MonthStart.Year -Month $MonthStart.Month -Day $day -Hour 0 -Minute 0 -Second 0
        if ($currentDay.DayOfWeek -eq [System.DayOfWeek]::Saturday -and $entries.Count -lt $EntryCount) {
            Add-EntryForDay -Entries $entries -Day $currentDay -Hour 9 -Minute 0 -DurationMinutes 120 -BatchId $BatchId -Name $Name -Project $Project -OvertimeCodes $OvertimeCodes -PaymentOptions $PaymentOptions -ReasonCodes $ReasonCodes -Index $index
            $index++

            $sunday = $currentDay.AddDays(1)
            if ($sunday.Month -eq $MonthStart.Month -and $entries.Count -lt $EntryCount) {
                Add-EntryForDay -Entries $entries -Day $sunday -Hour 10 -Minute 0 -DurationMinutes 150 -BatchId $BatchId -Name $Name -Project $Project -OvertimeCodes $OvertimeCodes -PaymentOptions $PaymentOptions -ReasonCodes $ReasonCodes -Index $index
                $index++
            }
        }
    }

    $weekdayCursor = 1
    $timeSlots = @(
        @{ Hour = 6; Minute = 0; Duration = 60 },
        @{ Hour = 15; Minute = 30; Duration = 75 },
        @{ Hour = 17; Minute = 45; Duration = 90 },
        @{ Hour = 18; Minute = 15; Duration = 120 },
        @{ Hour = 19; Minute = 0; Duration = 150 }
    )

    while ($entries.Count -lt $EntryCount) {
        $dayNumber = (($weekdayCursor - 1) % $daysInMonth) + 1
        $cycle = [int][math]::Floor(($weekdayCursor - 1) / $daysInMonth)
        $currentDay = Get-Date -Year $MonthStart.Year -Month $MonthStart.Month -Day $dayNumber -Hour 0 -Minute 0 -Second 0
        $slot = $timeSlots[$index % $timeSlots.Count]

        if ($currentDay.DayOfWeek -ne [System.DayOfWeek]::Sunday -or $cycle -gt 0) {
            Add-EntryForDay -Entries $entries -Day $currentDay -Hour ([int]$slot.Hour) -Minute ([int]$slot.Minute) -DurationMinutes ([int]$slot.Duration) -BatchId $BatchId -Name $Name -Project $Project -OvertimeCodes $OvertimeCodes -PaymentOptions $PaymentOptions -ReasonCodes $ReasonCodes -Index $index
            $index++
        }

        $weekdayCursor++
    }

    return @(Sort-EntriesForStorage -Entries $entries)
}

if ($EntriesPerEmployeePerMonth -lt 20) {
    throw "EntriesPerEmployeePerMonth must be at least 20. Use 40 for a strong multi-page test."
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    $Password = "GC179Test123!"
}

if ($MonthKeys.Count -eq 0) {
    $MonthKeys = Get-DefaultMonthKeys
}

$monthStarts = @($MonthKeys | ForEach-Object { Get-MonthStart -Value ([string]$_) })
$effectiveMonthKeys = @($monthStarts | ForEach-Object { $_.ToString("yyyy-MM") })
$batchId = [Guid]::NewGuid().ToString("N")

$superAdminCodes = @(
    Get-JsonArraySafe -Path $usersFile |
        Where-Object {
            $role = if ($_.PSObject.Properties.Name -contains "role") { Get-NormalizedRoleName -Role ([string]$_.role) } else { "" }
            $role -eq "superAdmin"
        } |
        ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "employeeCode") { [string]$_.employeeCode } else { "" }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

$projects = @(
    Get-JsonArraySafe -Path $projectsFile |
        Where-Object { [string]$_.projectCode -ne $ProjectCode }
)
$projects += [PSCustomObject]@{
    projectCode  = $ProjectCode
    projectName  = $ProjectName
    sector       = $Sector
    admins       = @($superAdminCodes)
    backupAdmins = @()
    archived     = $false
}
Write-JsonLocked -Path $projectsFile -Value $projects -Depth 10

$nameMap = Get-NameMapHashtable
$nameMap[$StandardEmployeeCode] = $StandardEmployeeName
$nameMap[$CompressedEmployeeCode] = $CompressedEmployeeName
Write-JsonLocked -Path $mappingFile -Value ([PSCustomObject]$nameMap) -Depth 8

$seedCodes = @($StandardEmployeeCode, $CompressedEmployeeCode)
$users = @(
    Get-JsonArraySafe -Path $usersFile |
        Where-Object {
            $username = if ($_.PSObject.Properties.Name -contains "username") { [string]$_.username } else { "" }
            $code = if ($_.PSObject.Properties.Name -contains "employeeCode") { [string]$_.employeeCode } else { "" }
            $role = if ($_.PSObject.Properties.Name -contains "role") { Get-NormalizedRoleName -Role ([string]$_.role) } else { "" }

            if (($seedCodes -contains $username -or $seedCodes -contains $code) -and $role -eq "superAdmin") {
                throw "Refusing to replace super admin account $username / $code."
            }

            (-not ($seedCodes -contains $username) -and -not ($seedCodes -contains $code))
        }
)
$users += (New-SeedUserRecord -Code $StandardEmployeeCode -Name $StandardEmployeeName -InitialPassword $Password -CompressedWorkWeek $false -Surname "STANDARD" -GivenName "GC179" -Initials "G.S" -Pri "111222333" -Position "AS03" -Level "1")
$users += (New-SeedUserRecord -Code $CompressedEmployeeCode -Name $CompressedEmployeeName -InitialPassword $Password -CompressedWorkWeek $true -Surname "COMPRESSED" -GivenName "GC179" -Initials "G.C" -Pri "444555666" -Position "AS04" -Level "2")
Write-JsonLocked -Path $usersFile -Value $users -Depth 10

$overtimeCodes = Get-CodeList -Options (Get-OvertimeCodes) -Fallback "260"
$paymentOptions = Get-CodeList -Options (Get-PaymentOptions) -Fallback "cash"
$reasonCodes = Get-CodeList -Options (Get-ReasonCodes) -Fallback "D"

$standardEntries = New-Object System.Collections.ArrayList
$compressedEntries = New-Object System.Collections.ArrayList

foreach ($monthStart in $monthStarts) {
    foreach ($entry in @(New-EntriesForMonth -MonthStart $monthStart -EntryCount $EntriesPerEmployeePerMonth -BatchId $batchId -Name $StandardEmployeeName -Project $ProjectCode -OvertimeCodes $overtimeCodes -PaymentOptions $paymentOptions -ReasonCodes $reasonCodes)) {
        [void]$standardEntries.Add($entry)
    }
    foreach ($entry in @(New-EntriesForMonth -MonthStart $monthStart -EntryCount $EntriesPerEmployeePerMonth -BatchId $batchId -Name $CompressedEmployeeName -Project $ProjectCode -OvertimeCodes $overtimeCodes -PaymentOptions $paymentOptions -ReasonCodes $reasonCodes)) {
        [void]$compressedEntries.Add($entry)
    }
}

$standardDataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $StandardEmployeeCode)
$compressedDataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $CompressedEmployeeCode)
Write-JsonLocked -Path $standardDataFile -Value (Sort-EntriesForStorage -Entries $standardEntries) -Depth 10
Write-JsonLocked -Path $compressedDataFile -Value (Sort-EntriesForStorage -Entries $compressedEntries) -Depth 10

$history = Get-JsonArraySafe -Path $historyFile
$history += [PSCustomObject]@{
    action    = "Seed"
    employee  = "GC179 calculation test employees"
    author    = "GC179 rule seed script"
    message   = "Generated <strong>$($standardEntries.Count + $compressedEntries.Count)</strong> approved GC179 calculation test entries across <strong>$($effectiveMonthKeys -join ', ')</strong>."
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}
Write-JsonLocked -Path $historyFile -Value $history -Depth 10
Write-JsonLocked -Path $syncStateFile -Value ([PSCustomObject]@{
    version      = (Get-SyncVersion + 1)
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    category     = "seed"
    resource     = $batchId
}) -Depth 6

Write-Host "GC179 calculation rule seed created."
Write-Host "Data folder: $sharedFolder"
Write-Host "Project: $ProjectCode - $ProjectName"
Write-Host "Months: $($effectiveMonthKeys -join ', ')"
Write-Host "Entries per employee per month: $EntriesPerEmployeePerMonth"
Write-Host "Standard week employee: $StandardEmployeeName ($StandardEmployeeCode)"
Write-Host "Compressed week employee: $CompressedEmployeeName ($CompressedEmployeeCode)"
Write-Host "Employee login password for both: $Password"
Write-Host "Expected GC179 parts per employee/month: $([int][math]::Ceiling($EntriesPerEmployeePerMonth / 16))"
Write-Host "Standard test expectation: weekdays and Saturdays go to 1.5; Sundays after seeded Saturdays go to 2.0."
Write-Host "Compressed test expectation: every entry goes to 1.75."
