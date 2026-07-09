param(
    [Parameter(Mandatory = $true)][string]$FirstName,
    [Parameter(Mandatory = $true)][string]$LastName,
    [Parameter(Mandatory = $true)][string]$HRMIS,
    [Parameter(Mandatory = $true)][string]$Password,
    [switch]$NoMustChangePassword
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$backendDir = Join-Path $repoRoot "apps/admin/backend"
$scriptDir = $backendDir

. (Join-Path $backendDir "lib/AdminContext.ps1")
. (Join-Path $backendDir "lib/FileStore.ps1")
. (Join-Path $backendDir "lib/CommonHelpers.ps1")
. (Join-Path $backendDir "services/AuthService.ps1")

$normalizedHRMIS = ([string]$HRMIS).Trim()
$displayName = ("{0} {1}" -f ([string]$FirstName).Trim(), ([string]$LastName).Trim()).Trim()

if ([string]::IsNullOrWhiteSpace($displayName)) {
    throw "First name and last name are required."
}

if ($normalizedHRMIS -notmatch "^\d+$") {
    throw "HRMIS must contain digits only."
}

$policyError = Test-NewPasswordPolicy -Password $Password
if ($policyError) {
    throw $policyError
}

$secret = New-PasswordCredential -Password $Password
$mustChangePassword = -not [bool]$NoMustChangePassword
$created = $false

$lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
try {
    $users = @(Read-JsonArrayFile -Path $usersFile)
    $existingUser = $users | Where-Object { [string]$_.username -eq $normalizedHRMIS } | Select-Object -First 1

    if ($null -eq $existingUser) {
        $users += [PSCustomObject]@{
            username           = $normalizedHRMIS
            displayName        = $displayName
            role               = "superAdmin"
            employeeCode       = $normalizedHRMIS
            disabled           = $false
            mustChangePassword = $mustChangePassword
            createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
            passwordSalt       = $secret.passwordSalt
            passwordHash       = $secret.passwordHash
            passwordIterations = $secret.passwordIterations
            passwordAlgorithm  = $secret.passwordAlgorithm
            timeEntryTypes     = @("overtime", "diverse")
        }
        $created = $true
    }
    else {
        $existingUser.displayName = $displayName
        $existingUser.role = "superAdmin"
        $existingUser.employeeCode = $normalizedHRMIS
        $existingUser.disabled = $false
        $existingUser.mustChangePassword = $mustChangePassword
        $existingUser.passwordSalt = $secret.passwordSalt
        $existingUser.passwordHash = $secret.passwordHash
        $existingUser.passwordIterations = $secret.passwordIterations
        $existingUser.passwordAlgorithm = $secret.passwordAlgorithm

        if ($existingUser.PSObject.Properties.Name -contains "timeEntryTypes") {
            $existingUser.timeEntryTypes = @("overtime", "diverse")
        }
        else {
            $existingUser | Add-Member -NotePropertyName "timeEntryTypes" -NotePropertyValue @("overtime", "diverse") -Force
        }
    }

    Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
}
finally {
    Release-ResourceLock -LockHandle $lockHandle
}

$mappingLock = Acquire-ResourceLock -ResourcePath $mappingFile
try {
    $employeeNames = @{}
    $nameMap = Get-EmployeeNameMap
    foreach ($property in $nameMap.PSObject.Properties) {
        $employeeNames[[string]$property.Name] = [string]$property.Value
    }
    $employeeNames[$normalizedHRMIS] = $displayName
    Write-JsonAtomic -Path $mappingFile -Value ([PSCustomObject]$employeeNames) -Depth 6
}
finally {
    Release-ResourceLock -LockHandle $mappingLock
}

$action = if ($created) { "Created" } else { "Updated" }
Write-Host ("{0} super admin {1} ({2})." -f $action, $displayName, $normalizedHRMIS)
Write-Host ("Username: {0}" -f $normalizedHRMIS)
Write-Host ("Must change password: {0}" -f $mustChangePassword)
