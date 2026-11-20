$ErrorActionPreference = "Stop"

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$script:sharedFolder = [System.IO.Path]::GetTempPath()

. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/EmployeeDirectoryService.ps1")

$script:DirectoryUsers = New-Object System.Collections.ArrayList
$script:DirectoryUsersByCode = @{}
for ($index = 1; $index -le 1000; $index++) {
    $employeeCode = $index.ToString("D9")
    $user = [PSCustomObject]@{
        username       = $employeeCode
        employeeCode   = $employeeCode
        displayName    = "Employee $index"
        role           = "employee"
        disabled       = $false
        timeEntryTypes = @("overtime")
    }
    [void]$script:DirectoryUsers.Add($user)
    $script:DirectoryUsersByCode[$employeeCode] = $user
}

$activeCode = (500).ToString("D9")
$fallbackNameCode = (999).ToString("D9")
$archivedCode = (1000).ToString("D9")
$script:DirectoryUsersByCode[$fallbackNameCode].displayName = ""
$script:DirectoryUsersByCode[$archivedCode].disabled = $true
$script:EmployeeEntryFileReadCount = 0
$script:EmployeeAuthLookupCount = 0
$script:EmployeeNameFallbackCount = 0

function Get-Users {
    return @($script:DirectoryUsers.ToArray())
}

function Get-EmployeeUserByCode {
    param([string]$EmployeeCode)

    $script:EmployeeAuthLookupCount++
    if ($script:DirectoryUsersByCode.ContainsKey($EmployeeCode)) {
        return $script:DirectoryUsersByCode[$EmployeeCode]
    }
    return $null
}

function Test-EmployeeUserRecord {
    param(
        $UserRecord,
        [string]$EmployeeCode
    )

    if ($null -eq $UserRecord -or [string]::IsNullOrWhiteSpace([string]$UserRecord.employeeCode)) {
        return $false
    }
    return ([string]::IsNullOrWhiteSpace($EmployeeCode) -or [string]$UserRecord.employeeCode -eq $EmployeeCode)
}

function Get-UserEmployeeCodeValue {
    param($UserRecord)
    return [string]$UserRecord.employeeCode
}

function Get-CachedEmployeeEntriesForFile {
    param([string]$DataFile)

    $script:EmployeeEntryFileReadCount++
    return @()
}

function Get-EmployeeName {
    param([string]$code)

    $script:EmployeeNameFallbackCount++
    return "Mapped $code"
}

function Get-EmployeeDirectoryStats {
    param($Entries)

    return [PSCustomObject]@{
        totalOvertimeSeconds = 0
        totalOvertime        = "00:00:00"
        approvedCount        = 0
        pendingCount         = 0
        rejectedCount        = 0
        liveCount            = 0
        diverseCount         = 0
        diverseSeconds       = 0
        diverseDuration      = "00:00:00"
        projectStats         = @()
    }
}

function Get-EmployeeTimeEntryTypesFromUserRecord {
    param($UserRecord)
    return @($UserRecord.timeEntryTypes)
}

function Get-Gc179ProfileFromUserRecord {
    param($UserRecord)
    return $null
}

function Get-EffectiveUserRole {
    param($UserRecord)
    return [string]$UserRecord.role
}

function Get-ProjectAdminCodes {
    param($Project)
    return @()
}

function Get-ProjectBackupAdminCodes {
    param($Project)
    return @()
}

# Confirm the replaced preflight path scales with the whole directory and
# attempts to read every employee entry file, even when only one code is needed.
$legacyDirectory = @(Get-EmployeeDirectoryListUncached -IncludeDisabled:$true)
Assert-Equal -Expected 1000 -Actual $legacyDirectory.Count -Message "The synthetic directory fixture is incomplete."
Assert-Equal -Expected 1000 -Actual $script:EmployeeEntryFileReadCount -Message "The legacy directory lookup should inspect every employee entry file."

$script:EmployeeEntryFileReadCount = 0
$script:EmployeeAuthLookupCount = 0
$activeMetadata = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $activeCode
Assert-Equal -Expected $activeCode -Actual $activeMetadata.code -Message "The targeted lookup returned the wrong employee code."
Assert-Equal -Expected "Employee 500" -Actual $activeMetadata.name -Message "The targeted lookup returned the wrong display name."
Assert-Equal -Expected $false -Actual $activeMetadata.archived -Message "The targeted lookup returned the wrong archive state."
Assert-Equal -Expected 1 -Actual $script:EmployeeAuthLookupCount -Message "The targeted lookup should perform one auth-index lookup."
Assert-Equal -Expected 0 -Actual $script:EmployeeEntryFileReadCount -Message "The targeted lookup must not read employee entry files."

$activeOnlyArchivedMetadata = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $archivedCode
Assert-True -Condition ($null -eq $activeOnlyArchivedMetadata) -Message "Archived employees must remain hidden from active-only CRUD checks."
$archivedMetadata = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $archivedCode -IncludeDisabled:$true
Assert-Equal -Expected $true -Actual $archivedMetadata.archived -Message "Restore checks must be able to retrieve archived employees."
Assert-Equal -Expected "Employee 1000" -Actual $archivedMetadata.name -Message "Archived metadata returned the wrong name."

$fallbackMetadata = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $fallbackNameCode
Assert-Equal -Expected "Mapped $fallbackNameCode" -Actual $fallbackMetadata.name -Message "The targeted lookup changed display-name fallback behavior."
Assert-True -Condition ($script:EmployeeNameFallbackCount -gt 0) -Message "The mapping fallback was not used for an empty display name."

$missingMetadata = Get-EmployeeDirectoryRecordMetadata -EmployeeCode "999999999" -IncludeDisabled:$true
Assert-True -Condition ($null -eq $missingMetadata) -Message "Unknown employee codes must still return no metadata."

$routeExpectations = @(
    [PSCustomObject]@{ Path = "app/backend/routes/employee/create-record.routes.ps1"; IncludeDisabled = $false },
    [PSCustomObject]@{ Path = "app/backend/routes/employee/update-record.routes.ps1"; IncludeDisabled = $false },
    # Delete intentionally sees archived records so a retry can finish session
    # revocation without duplicating the history entry.
    [PSCustomObject]@{ Path = "app/backend/routes/employee/delete-record.routes.ps1"; IncludeDisabled = $true },
    [PSCustomObject]@{ Path = "app/backend/routes/employee/restore-record.routes.ps1"; IncludeDisabled = $true }
)

foreach ($expectation in $routeExpectations) {
    $routePath = Join-Path -Path $repoRoot -ChildPath $expectation.Path
    $routeSource = [System.IO.File]::ReadAllText($routePath)
    Assert-True -Condition ($routeSource -match "Test-CurrentUserSuperAdmin") -Message "$($expectation.Path) lost its super-admin permission guard."
    Assert-True -Condition ($routeSource -match "Get-EmployeeDirectoryRecordMetadata") -Message "$($expectation.Path) does not use the targeted metadata lookup."
    Assert-True -Condition ($routeSource -notmatch "Get-EmployeeDirectoryList") -Message "$($expectation.Path) still builds the full employee directory for a CRUD preflight."
    if ([bool]$expectation.IncludeDisabled) {
        Assert-True -Condition ($routeSource -match '-IncludeDisabled:\$true') -Message "$($expectation.Path) must include archived metadata."
    }
    else {
        Assert-True -Condition ($routeSource -notmatch "-IncludeDisabled") -Message "$($expectation.Path) must keep archived employees hidden."
    }
}

Write-Host "Employee directory targeted lookup test passed: 1 auth lookup and 0 entry-file reads versus 1,000 legacy entry-file reads."
