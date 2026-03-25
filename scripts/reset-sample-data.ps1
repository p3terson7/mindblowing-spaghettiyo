[CmdletBinding()]
param(
    [string]$AdminUsername = "admin",
    [string]$AdminPassword = "ChangeMe123!"
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
        [int]$Depth = 10
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
        [bool]$MustChangePassword
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

function Round-ToMinute {
    param([Parameter(Mandatory = $true)][datetime]$Value)

    return (Get-Date -Year $Value.Year -Month $Value.Month -Day $Value.Day -Hour $Value.Hour -Minute $Value.Minute -Second 0)
}

function New-DayTime {
    param(
        [Parameter(Mandatory = $true)][datetime]$Today,
        [Parameter(Mandatory = $true)][int]$DayOffset,
        [Parameter(Mandatory = $true)][int]$Hour,
        [Parameter(Mandatory = $true)][int]$Minute
    )

    return $Today.AddDays($DayOffset).AddHours($Hour).AddMinutes($Minute)
}

function New-Entry {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [Parameter(Mandatory = $true)][datetime]$PunchIn,
        [datetime]$PunchOut,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$ProjectCode,
        [string]$OvertimeCode,
        [string]$Message = ""
    )

    $roundedPunchIn = Round-ToMinute -Value $PunchIn
    $roundedPunchOut = $null
    $overtime = $null

    if ($PSBoundParameters.ContainsKey("PunchOut") -and $null -ne $PunchOut) {
        $roundedPunchOut = Round-ToMinute -Value $PunchOut
        $overtime = ($roundedPunchOut - $roundedPunchIn).ToString("hh\:mm\:ss")
    }

    return [PSCustomObject]@{
        name        = $EmployeeName
        date        = $roundedPunchIn.ToString("yyyy-MM-dd")
        punchIn     = $roundedPunchIn.ToString("HH:mm:ss")
        punchOut    = if ($roundedPunchOut) { $roundedPunchOut.ToString("HH:mm:ss") } else { $null }
        overtime    = $overtime
        status      = $Status
        message     = $Message
        projectCode = $ProjectCode
        overtimeCode = $OvertimeCode
    }
}

function Sort-EntriesChronologically {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable]$Entries
    )

    return @(
        $Entries | Sort-Object @{
            Expression = {
                try {
                    [datetime]::ParseExact(
                        ("{0} {1}" -f [string]$_.date, [string]$_.punchIn),
                        "yyyy-MM-dd HH:mm:ss",
                        $null
                    )
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
        [Parameter(Mandatory = $true)][string]$Employee,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][datetime]$Timestamp
    )

    return [PSCustomObject]@{
        action    = $Action
        employee  = $Employee
        message   = $Message
        timestamp = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
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

$employees = [ordered]@{
    "000123070" = "Alice Johnson"
    "000123456" = "Jane Smith"
    "000379070" = "Peter-Nicholas Sarateanu"
    "000456123" = "Michael Chen"
    "000789123" = "Priya Patel"
}

$projects = @(
    [PSCustomObject]@{ projectCode = "OPS-410"; projectName = "Month-End Close" },
    [PSCustomObject]@{ projectCode = "APP-220"; projectName = "Portal Upgrade" },
    [PSCustomObject]@{ projectCode = "INF-330"; projectName = "Infrastructure Maintenance" },
    [PSCustomObject]@{ projectCode = "CLT-120"; projectName = "Client Rollout" }
)

$overtimeCodes = @(
    [PSCustomObject]@{ code = "OT-OPS"; label = "Operational Support" },
    [PSCustomObject]@{ code = "OT-MNT"; label = "Maintenance Window" },
    [PSCustomObject]@{ code = "OT-REL"; label = "Release / Deployment" },
    [PSCustomObject]@{ code = "OT-CLS"; label = "Month-End / Closeout" }
)

$now = Get-Date
$today = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour 0 -Minute 0 -Second 0
$activePunchIn = Round-ToMinute -Value ($now.AddMinutes(-75))
if ($activePunchIn.Date -lt $today.Date) {
    $activePunchIn = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute 0 -Second 0
}
if ($activePunchIn -ge $now) {
    $activePunchIn = Round-ToMinute -Value ($now.AddMinutes(-15))
}

$employeeEntries = [ordered]@{
    "000123070" = @(
        (New-Entry -EmployeeName $employees."000123070" -PunchIn $activePunchIn -Status "pending" -ProjectCode "INF-330" -OvertimeCode "OT-MNT"),
        (New-Entry -EmployeeName $employees."000123070" -PunchIn (New-DayTime -Today $today -DayOffset -2 -Hour 17 -Minute 45) -PunchOut (New-DayTime -Today $today -DayOffset -2 -Hour 18 -Minute 30) -Status "approved" -ProjectCode "OPS-410" -OvertimeCode "OT-CLS"),
        (New-Entry -EmployeeName $employees."000123070" -PunchIn (New-DayTime -Today $today -DayOffset -16 -Hour 18 -Minute 20) -PunchOut (New-DayTime -Today $today -DayOffset -16 -Hour 21 -Minute 10) -Status "approved" -ProjectCode "APP-220" -OvertimeCode "OT-REL" -Message "After-hours deployment support.")
    )
    "000123456" = @(
        (New-Entry -EmployeeName $employees."000123456" -PunchIn (New-DayTime -Today $today -DayOffset -1 -Hour 17 -Minute 30) -PunchOut (New-DayTime -Today $today -DayOffset -1 -Hour 19 -Minute 15) -Status "pending" -ProjectCode "OPS-410" -OvertimeCode "OT-CLS" -Message "Month-end reconciliation and report validation."),
        (New-Entry -EmployeeName $employees."000123456" -PunchIn (New-DayTime -Today $today -DayOffset -6 -Hour 18 -Minute 0) -PunchOut (New-DayTime -Today $today -DayOffset -6 -Hour 20 -Minute 30) -Status "approved" -ProjectCode "APP-220" -OvertimeCode "OT-REL"),
        (New-Entry -EmployeeName $employees."000123456" -PunchIn (New-DayTime -Today $today -DayOffset -22 -Hour 18 -Minute 10) -PunchOut (New-DayTime -Today $today -DayOffset -22 -Hour 19 -Minute 40) -Status "approved" -ProjectCode "CLT-120" -OvertimeCode "OT-OPS")
    )
    "000379070" = @(
        (New-Entry -EmployeeName $employees."000379070" -PunchIn (New-DayTime -Today $today -DayOffset -3 -Hour 18 -Minute 5) -PunchOut (New-DayTime -Today $today -DayOffset -3 -Hour 20 -Minute 20) -Status "rejected" -ProjectCode "APP-220" -OvertimeCode "OT-REL" -Message "Split support and build work into separate entries."),
        (New-Entry -EmployeeName $employees."000379070" -PunchIn (New-DayTime -Today $today -DayOffset -8 -Hour 18 -Minute 0) -PunchOut (New-DayTime -Today $today -DayOffset -8 -Hour 19 -Minute 30) -Status "approved" -ProjectCode "APP-220" -OvertimeCode "OT-OPS"),
        (New-Entry -EmployeeName $employees."000379070" -PunchIn (New-DayTime -Today $today -DayOffset -37 -Hour 18 -Minute 10) -PunchOut (New-DayTime -Today $today -DayOffset -37 -Hour 21 -Minute 0) -Status "approved" -ProjectCode "CLT-120" -OvertimeCode "OT-OPS")
    )
    "000456123" = @(
        (New-Entry -EmployeeName $employees."000456123" -PunchIn (New-DayTime -Today $today -DayOffset -1 -Hour 6 -Minute 30) -PunchOut (New-DayTime -Today $today -DayOffset -1 -Hour 8 -Minute 0) -Status "pending" -ProjectCode "INF-330" -OvertimeCode "OT-MNT" -Message "Early maintenance window and verification."),
        (New-Entry -EmployeeName $employees."000456123" -PunchIn (New-DayTime -Today $today -DayOffset -9 -Hour 19 -Minute 0) -PunchOut (New-DayTime -Today $today -DayOffset -9 -Hour 21 -Minute 10) -Status "approved" -ProjectCode "INF-330" -OvertimeCode "OT-MNT"),
        (New-Entry -EmployeeName $employees."000456123" -PunchIn (New-DayTime -Today $today -DayOffset -61 -Hour 18 -Minute 45) -PunchOut (New-DayTime -Today $today -DayOffset -61 -Hour 20 -Minute 0) -Status "approved" -ProjectCode "OPS-410" -OvertimeCode "OT-OPS")
    )
    "000789123" = @(
        (New-Entry -EmployeeName $employees."000789123" -PunchIn (New-DayTime -Today $today -DayOffset -1 -Hour 20 -Minute 0) -PunchOut (New-DayTime -Today $today -DayOffset -1 -Hour 22 -Minute 0) -Status "approved" -ProjectCode "CLT-120" -OvertimeCode "OT-OPS"),
        (New-Entry -EmployeeName $employees."000789123" -PunchIn (New-DayTime -Today $today -DayOffset -7 -Hour 19 -Minute 15) -PunchOut (New-DayTime -Today $today -DayOffset -7 -Hour 20 -Minute 10) -Status "approved" -ProjectCode "OPS-410" -OvertimeCode "OT-CLS"),
        (New-Entry -EmployeeName $employees."000789123" -PunchIn (New-DayTime -Today $today -DayOffset -28 -Hour 18 -Minute 30) -PunchOut (New-DayTime -Today $today -DayOffset -28 -Hour 20 -Minute 5) -Status "approved" -ProjectCode "APP-220" -OvertimeCode "OT-REL")
    )
}

$history = @(
    (New-HistoryRecord -Action "Add" -Employee $employees."000123070" -Timestamp (New-DayTime -Today $today -DayOffset 0 -Hour $activePunchIn.Hour -Minute $activePunchIn.Minute) -Message ("Added an active overtime entry on {0}, starting at <strong>{1}</strong> for project <strong>INF-330</strong>." -f (Format-HistoryDate $activePunchIn), (Format-HistoryTime $activePunchIn))),
    (New-HistoryRecord -Action "Approved" -Employee $employees."000789123" -Timestamp (New-DayTime -Today $today -DayOffset -1 -Hour 22 -Minute 10) -Message ("Approved an entry on {0} starting at <strong>{1}</strong>." -f (Format-HistoryDate (New-DayTime -Today $today -DayOffset -1 -Hour 20 -Minute 0)), (Format-HistoryTime (New-DayTime -Today $today -DayOffset -1 -Hour 20 -Minute 0)))),
    (New-HistoryRecord -Action "Add" -Employee $employees."000123456" -Timestamp (New-DayTime -Today $today -DayOffset -1 -Hour 19 -Minute 20) -Message ("Added an entry on {0}, starting at <strong>{1}</strong> and finishing at <strong>{2}</strong> for project <strong>OPS-410</strong>." -f (Format-HistoryDate (New-DayTime -Today $today -DayOffset -1 -Hour 17 -Minute 30)), (Format-HistoryTime (New-DayTime -Today $today -DayOffset -1 -Hour 17 -Minute 30)), (Format-HistoryTime (New-DayTime -Today $today -DayOffset -1 -Hour 19 -Minute 15)))),
    (New-HistoryRecord -Action "Add" -Employee $employees."000456123" -Timestamp (New-DayTime -Today $today -DayOffset -1 -Hour 8 -Minute 5) -Message ("Added an entry on {0}, starting at <strong>{1}</strong> and finishing at <strong>{2}</strong> for project <strong>INF-330</strong>." -f (Format-HistoryDate (New-DayTime -Today $today -DayOffset -1 -Hour 6 -Minute 30)), (Format-HistoryTime (New-DayTime -Today $today -DayOffset -1 -Hour 6 -Minute 30)), (Format-HistoryTime (New-DayTime -Today $today -DayOffset -1 -Hour 8 -Minute 0)))),
    (New-HistoryRecord -Action "Approved" -Employee $employees."000123456" -Timestamp (New-DayTime -Today $today -DayOffset -6 -Hour 20 -Minute 40) -Message ("Approved an entry on {0} starting at <strong>{1}</strong>." -f (Format-HistoryDate (New-DayTime -Today $today -DayOffset -6 -Hour 18 -Minute 0)), (Format-HistoryTime (New-DayTime -Today $today -DayOffset -6 -Hour 18 -Minute 0)))),
    (New-HistoryRecord -Action "Update" -Employee $employees."000379070" -Timestamp (New-DayTime -Today $today -DayOffset -3 -Hour 20 -Minute 24) -Message ("Updated an entry on {0}, Project Code updated." -f (Format-HistoryDate (New-DayTime -Today $today -DayOffset -3 -Hour 18 -Minute 5)))),
    (New-HistoryRecord -Action "Rejected" -Employee $employees."000379070" -Timestamp (New-DayTime -Today $today -DayOffset -3 -Hour 20 -Minute 27) -Message ("Rejected an entry on {0} starting at <strong>{1}</strong>." -f (Format-HistoryDate (New-DayTime -Today $today -DayOffset -3 -Hour 18 -Minute 5)), (Format-HistoryTime (New-DayTime -Today $today -DayOffset -3 -Hour 18 -Minute 5))))
)

$users = @(
    (New-UserRecord -Username $AdminUsername -DisplayName "Administrator" -Role "admin" -EmployeeCode $null -Password $AdminPassword -MustChangePassword:$false)
)

foreach ($employeeCode in $employees.Keys) {
    $users += New-UserRecord -Username $employeeCode -DisplayName $employees[$employeeCode] -Role "employee" -EmployeeCode $employeeCode -Password $employeeCode -MustChangePassword:$true
}

Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "employeeNames.json") -Value ([PSCustomObject]$employees) -Depth 5
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "projects.json") -Value $projects -Depth 5
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "overtimeCodes.json") -Value $overtimeCodes -Depth 5
foreach ($employeeCode in $employees.Keys) {
    Write-JsonFile `
        -Path (Join-Path -Path $dataPath -ChildPath ("{0}_data.json" -f $employeeCode)) `
        -Value (Sort-EntriesChronologically -Entries $employeeEntries[$employeeCode]) `
        -Depth 8
}
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "history.json") -Value $history -Depth 8
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "users.json") -Value $users -Depth 8
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "sessions.json") -Value @() -Depth 5
Write-JsonFile -Path (Join-Path -Path $dataPath -ChildPath "sync-state.json") -Value ([PSCustomObject]@{
    version      = 1
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    category     = "seed"
    resource     = "reset-sample-data"
}) -Depth 5

Write-Host "Sample data reset complete."
Write-Host "Admin login: $AdminUsername / $AdminPassword"
Write-Host "Employee login: employee code / employee code"
