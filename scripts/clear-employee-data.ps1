[CmdletBinding()]
param(
    [switch]$Force
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

function Write-JsonLocked {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 8
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

function New-BootstrapSuperAdminRecord {
    $secret = New-PasswordCredential -Password $bootstrapAdminPassword
    return [PSCustomObject]@{
        username           = $bootstrapAdminUsername
        displayName        = "Administrator"
        role               = "superAdmin"
        employeeCode       = ""
        disabled           = $false
        mustChangePassword = $true
        createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
        passwordSalt       = $secret.passwordSalt
        passwordHash       = $secret.passwordHash
        passwordIterations = $secret.passwordIterations
        passwordAlgorithm  = $secret.passwordAlgorithm
        timeEntryTypes     = @("overtime")
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

Write-Host "Data folder: $sharedFolder"
if (-not $Force) {
    Write-Host "This will delete employee data files, employees, projects, history, and sessions."
    Write-Host "Reference files are kept: overtimeCodes.json, paymentOptions.json, reasonCodes.json."
    $confirmation = Read-Host "Type DELETE to continue"
    if ($confirmation -ne "DELETE") {
        Write-Host "Cancelled."
        exit 0
    }
}

$removedDataFiles = 0
Get-ChildItem -Path $sharedFolder -File -Filter "*_data.json" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -Path $_.FullName -Force
    $removedDataFiles++
}

$users = Get-JsonArraySafe -Path $usersFile
$superAdmins = @(
    $users |
        Where-Object {
            $role = if ($_.PSObject.Properties.Name -contains "role") { Get-NormalizedRoleName -Role ([string]$_.role) } else { "" }
            $disabled = if ($_.PSObject.Properties.Name -contains "disabled") { [bool]$_.disabled } else { $false }
            $role -eq "superAdmin" -and -not $disabled
        }
)

if ($superAdmins.Count -eq 0) {
    $superAdmins = @((New-BootstrapSuperAdminRecord))
}

$superAdminNameMap = [ordered]@{}
foreach ($user in $superAdmins) {
    $employeeCode = if ($user.PSObject.Properties.Name -contains "employeeCode") { [string]$user.employeeCode } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($employeeCode)) {
        $displayName = if ($user.PSObject.Properties.Name -contains "displayName" -and -not [string]::IsNullOrWhiteSpace([string]$user.displayName)) {
            [string]$user.displayName
        }
        else {
            [string]$user.username
        }
        $superAdminNameMap[$employeeCode] = $displayName
    }
}

Write-JsonLocked -Path $usersFile -Value @($superAdmins) -Depth 10
Write-JsonLocked -Path $mappingFile -Value ([PSCustomObject]$superAdminNameMap) -Depth 6
Write-JsonLocked -Path $projectsFile -Value ([object[]]@()) -Depth 8
Write-JsonLocked -Path $historyFile -Value ([object[]]@()) -Depth 8
Write-JsonLocked -Path $sessionsFile -Value ([object[]]@()) -Depth 6
Write-JsonLocked -Path $syncStateFile -Value ([PSCustomObject]@{
    version      = (Get-SyncVersion + 1)
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    category     = "seed"
    resource     = "clear-employee-data"
}) -Depth 6

Write-Host "Employee data cleared."
Write-Host "Removed employee data files: $removedDataFiles"
Write-Host "Kept super admin accounts: $($superAdmins.Count)"
if ($superAdmins.Count -eq 1 -and [string]$superAdmins[0].username -eq $bootstrapAdminUsername -and [bool]$superAdmins[0].mustChangePassword) {
    Write-Host "Bootstrap super admin login: $bootstrapAdminUsername / $bootstrapAdminPassword"
}
