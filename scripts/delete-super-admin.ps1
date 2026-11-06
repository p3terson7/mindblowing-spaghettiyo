[CmdletBinding()]
param(
    [string]$Username = "",
    [switch]$Force,
    [switch]$RemoveEmployeeName,
    [switch]$AllowLastSuperAdmin
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
. (Join-Path -Path $backendDir -ChildPath "services/SyncService.ps1")

function Get-UserDisplayName {
    param($User)

    if ($null -eq $User) {
        return ""
    }

    if ($User.PSObject.Properties.Name -contains "displayName" -and -not [string]::IsNullOrWhiteSpace([string]$User.displayName)) {
        return [string]$User.displayName
    }

    return [string]$User.username
}

function Get-UserEmployeeCode {
    param($User)

    if ($null -eq $User) {
        return ""
    }

    if ($User.PSObject.Properties.Name -contains "employeeCode") {
        return [string]$User.employeeCode
    }

    return ""
}

function Test-UserDisabled {
    param($User)

    return ($User.PSObject.Properties.Name -contains "disabled" -and [bool]$User.disabled)
}

function Get-NameMapHashtable {
    $result = [ordered]@{}
    $nameMap = Get-EmployeeNameMap
    if ($null -eq $nameMap) {
        return $result
    }

    foreach ($property in $nameMap.PSObject.Properties) {
        $result[[string]$property.Name] = [string]$property.Value
    }

    return $result
}

function Write-EmployeeNameMap {
    param([Parameter(Mandatory = $true)]$Map)

    $lockHandle = Acquire-ResourceLock -ResourcePath $mappingFile
    try {
        Write-JsonAtomic -Path $mappingFile -Value ([PSCustomObject]$Map) -Depth 6
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

$users = @(Read-JsonArrayFile -Path $usersFile)
$superAdmins = @(
    $users |
        Where-Object { (Get-NormalizedRoleName -Role ([string]$_.role)) -eq "superAdmin" } |
        Sort-Object @{ Expression = { Get-UserDisplayName -User $_ } }, username
)

if ($superAdmins.Count -eq 0) {
    Write-Host "No super admins found."
    exit 0
}

Write-Host "Super admins:"
for ($index = 0; $index -lt $superAdmins.Count; $index++) {
    $user = $superAdmins[$index]
    $status = if (Test-UserDisabled -User $user) { "disabled" } else { "active" }
    $employeeCode = Get-UserEmployeeCode -User $user
    $employeeCodeText = if ([string]::IsNullOrWhiteSpace($employeeCode)) { "-" } else { $employeeCode }
    Write-Host ("[{0}] {1} | username: {2} | HRMIS: {3} | {4}" -f ($index + 1), (Get-UserDisplayName -User $user), [string]$user.username, $employeeCodeText, $status)
}

$targetUser = $null
if (-not [string]::IsNullOrWhiteSpace($Username)) {
    $targetUser = $superAdmins | Where-Object { [string]$_.username -eq $Username } | Select-Object -First 1
    if ($null -eq $targetUser) {
        throw "No super admin found with username '$Username'."
    }
}
else {
    Write-Host ""
    $selection = Read-Host "Enter the number or username of the super admin to delete"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        Write-Host "Cancelled."
        exit 0
    }

    if ($selection -match "^\d+$") {
        $selectedIndex = [int]$selection - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $superAdmins.Count) {
            throw "Invalid selection."
        }
        $targetUser = $superAdmins[$selectedIndex]
    }
    else {
        $targetUser = $superAdmins | Where-Object { [string]$_.username -eq $selection } | Select-Object -First 1
        if ($null -eq $targetUser) {
            throw "No super admin found with username '$selection'."
        }
    }
}

$targetUsername = [string]$targetUser.username
$targetDisplayName = Get-UserDisplayName -User $targetUser
$targetEmployeeCode = Get-UserEmployeeCode -User $targetUser
$activeSuperAdminCount = @($superAdmins | Where-Object { -not (Test-UserDisabled -User $_) }).Count

if (-not (Test-UserDisabled -User $targetUser) -and $activeSuperAdminCount -le 1 -and -not $AllowLastSuperAdmin) {
    throw "Refusing to delete the last active super admin. Create another super admin first, or rerun with -AllowLastSuperAdmin for test-only cleanup."
}

if (-not $Force) {
    Write-Host ""
    Write-Host ("Selected: {0} ({1})" -f $targetDisplayName, $targetUsername)
    Write-Host "This will permanently remove the user account and revoke active sessions."
    $confirmation = Read-Host "Type DELETE to continue"
    if ($confirmation -ne "DELETE") {
        Write-Host "Cancelled."
        exit 0
    }
}

$lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
try {
    $currentUsers = @(Read-JsonArrayFile -Path $usersFile)
    $remainingUsers = [object[]]@($currentUsers | Where-Object { [string]$_.username -ne $targetUsername })
    if ($remainingUsers.Count -eq $currentUsers.Count) {
        throw "User '$targetUsername' was not found while writing users.json."
    }
    Write-JsonAtomic -Path $usersFile -Value $remainingUsers -Depth 8
    Clear-AuthRuntimeCaches
}
finally {
    Release-ResourceLock -LockHandle $lockHandle
}

Revoke-SessionsForUsername -Username $targetUsername

if ($RemoveEmployeeName -and -not [string]::IsNullOrWhiteSpace($targetEmployeeCode)) {
    $nameMap = Get-NameMapHashtable
    if ($nameMap.Contains($targetEmployeeCode)) {
        $nameMap.Remove($targetEmployeeCode)
        Write-EmployeeNameMap -Map $nameMap
    }
}

[void](Publish-DataChange -Category "auth" -Resource $targetUsername)

Write-Host ("Deleted super admin {0} ({1})." -f $targetDisplayName, $targetUsername)
if ($RemoveEmployeeName -and -not [string]::IsNullOrWhiteSpace($targetEmployeeCode)) {
    Write-Host ("Removed employee name mapping for {0}." -f $targetEmployeeCode)
}
