[CmdletBinding()]
param(
    [string]$EmployeeCode = "000999179",
    [string]$EmployeeName = "GC179 Multipage Tester",
    [string]$ProjectCode = "GC179-TEST",
    [string]$ProjectName = "GC179 Multipage Export Test",
    [string]$Sector = "Testing",
    [string]$MonthKey = "",
    [int]$EntryCount = 34,
    [string]$Password = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$backendDir = Join-Path -Path $repoRoot -ChildPath "app/backend"

if (-not (Test-Path -Path $backendDir)) {
    throw "Unable to locate backend folder at $backendDir"
}

$scriptDir = $backendDir
. (Join-Path -Path $backendDir -ChildPath "lib/AppContext.ps1")
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
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $now = Get-Date
        return (Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 0 -Second 0)
    }

    try {
        return [DateTime]::ParseExact($Value, "yyyy-MM", $null)
    }
    catch {
        throw "MonthKey must use yyyy-MM format. Example: 2026-06"
    }
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
        [Parameter(Mandatory = $true)][string]$InitialPassword
    )

    $secret = New-PasswordCredential -Password $InitialPassword
    return [PSCustomObject]@{
        username           = $Code
        displayName        = $Name
        role               = "employee"
        employeeCode       = $Code
        timeEntryTypes     = @("overtime")
        gc179Profile       = [PSCustomObject]@{
            surname         = "TESTER"
            givenName       = "GC179 MULTIPAGE"
            initials        = "G.T"
            pri             = ""
            position        = "AS03"
            level           = "1"
            compressedWorkWeek = $false
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

function New-Gc179SeedEntry {
    param(
        [Parameter(Mandatory = $true)][DateTime]$StartTime,
        [Parameter(Mandatory = $true)][int]$DurationMinutes,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$OvertimeCode,
        [Parameter(Mandatory = $true)][string]$PaymentOption,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [int]$OffsetIndex = 0
    )

    $startOffsets = @(-6, -3, 2, 5, -1)
    $endOffsets = @(4, -2, 6, -4, 1)
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
    $roundedStart = [DateTime]::ParseExact(("{0} {1}" -f $dateText, $punchInRounded), "yyyy-MM-dd HH:mm:ss", $null)
    $roundedEnd = [DateTime]::ParseExact(("{0} {1}" -f $dateText, $punchOutRounded), "yyyy-MM-dd HH:mm:ss", $null)
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
        message       = ""
        projectCode   = $Project
        overtimeCode  = $OvertimeCode
        paymentOption = $PaymentOption
        reasonCode    = $ReasonCode
        seedBatchId   = $BatchId
        seededAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
        seedProfile   = "gc179-multipage"
    }
}

function Sort-EntriesForStorage {
    param($Entries)

    return @(
        @($Entries) | Sort-Object @{
            Expression = {
                try {
                    [DateTime]::ParseExact(("{0} {1}" -f [string]$_.date, [string]$_.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
                }
                catch {
                    [DateTime]::MinValue
                }
            }
        }
    )
}

if ($EntryCount -lt 31) {
    throw "EntryCount must be at least 31 to test multiple GC179 exports. Recommended: 34."
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    $Password = $EmployeeCode
}

$monthStart = Get-MonthStart -Value $MonthKey
$effectiveMonthKey = $monthStart.ToString("yyyy-MM")
$daysInMonth = [DateTime]::DaysInMonth($monthStart.Year, $monthStart.Month)
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
$nameMap[$EmployeeCode] = $EmployeeName
Write-JsonLocked -Path $mappingFile -Value ([PSCustomObject]$nameMap) -Depth 8

$users = @(
    Get-JsonArraySafe -Path $usersFile |
        Where-Object {
            $username = if ($_.PSObject.Properties.Name -contains "username") { [string]$_.username } else { "" }
            $code = if ($_.PSObject.Properties.Name -contains "employeeCode") { [string]$_.employeeCode } else { "" }
            $role = if ($_.PSObject.Properties.Name -contains "role") { Get-NormalizedRoleName -Role ([string]$_.role) } else { "" }

            if (($username -eq $EmployeeCode -or $code -eq $EmployeeCode) -and $role -eq "superAdmin") {
                throw "Refusing to replace super admin account $EmployeeCode."
            }

            return ($username -ne $EmployeeCode -and $code -ne $EmployeeCode)
        }
)
$users += (New-SeedUserRecord -Code $EmployeeCode -Name $EmployeeName -InitialPassword $Password)
Write-JsonLocked -Path $usersFile -Value $users -Depth 10

$overtimeCodes = Get-CodeList -Options (Get-OvertimeCodes) -Fallback "260"
$paymentOptions = Get-CodeList -Options (Get-PaymentOptions) -Fallback "cash"
$reasonCodes = Get-CodeList -Options (Get-ReasonCodes) -Fallback "D"
$durations = @(60, 75, 90, 105, 120, 150, 180)
$entries = @()

for ($i = 0; $i -lt $EntryCount; $i++) {
    $day = ($i % $daysInMonth) + 1
    $cycle = [int][math]::Floor($i / $daysInMonth)
    $hour = @(6, 15, 17, 18, 19)[$cycle % 5]
    $minute = @(0, 15, 30, 45)[$i % 4]
    $start = Get-Date -Year $monthStart.Year -Month $monthStart.Month -Day $day -Hour $hour -Minute $minute -Second 0

    $entries += (New-Gc179SeedEntry `
        -StartTime $start `
        -DurationMinutes $durations[$i % $durations.Count] `
        -BatchId $batchId `
        -Code $EmployeeCode `
        -Name $EmployeeName `
        -Project $ProjectCode `
        -OvertimeCode $overtimeCodes[$i % $overtimeCodes.Count] `
        -PaymentOption $paymentOptions[$i % $paymentOptions.Count] `
        -ReasonCode $reasonCodes[$i % $reasonCodes.Count] `
        -OffsetIndex $i)
}

$dataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode)
Write-JsonLocked -Path $dataFile -Value (Sort-EntriesForStorage -Entries $entries) -Depth 10

$history = Get-JsonArraySafe -Path $historyFile
$history += [PSCustomObject]@{
    action    = "Seed"
    employee  = $EmployeeName
    author    = "GC179 seed script"
    message   = "Generated <strong>$EntryCount</strong> approved GC179 test entries for <strong>$effectiveMonthKey</strong>."
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}
Write-JsonLocked -Path $historyFile -Value $history -Depth 10
Write-JsonLocked -Path $syncStateFile -Value ([PSCustomObject]@{
    version      = (Get-SyncVersion + 1)
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    category     = "seed"
    resource     = $batchId
}) -Depth 6

Write-Host "GC179 multipage seed created."
Write-Host "Data folder: $sharedFolder"
Write-Host "Employee: $EmployeeName ($EmployeeCode)"
Write-Host "Employee login: $EmployeeCode / $Password"
Write-Host "Project: $ProjectCode - $ProjectName"
Write-Host "Month: $effectiveMonthKey"
Write-Host "Approved entries: $EntryCount"
Write-Host "Expected GC179 parts with 16 rows per PDF: $([int][math]::Ceiling($EntryCount / 16))"
