if (-not $script:EmployeeNameMapCache) {
    $script:EmployeeNameMapCache = $null
}

if (-not $script:ProjectsCache) {
    $script:ProjectsCache = $null
}

if (-not $script:JsonOptionArrayCache) {
    $script:JsonOptionArrayCache = @{}
}

# Helper function to emulate the null-coalescing operator
function Get-EmployeeNameMap {
    if (!(Test-Path -Path $mappingFile)) {
        Write-JsonAtomic -Path $mappingFile -Value @{} -Depth 3
    }

    $metadata = Get-FileMetadataSnapshot -Path $mappingFile
    $cacheKey = if ($null -ne $metadata) { "{0}:{1}" -f $metadata.LastWriteTicks, $metadata.Length } else { "missing" }
    if ($script:EmployeeNameMapCache -and $script:EmployeeNameMapCache.Key -eq $cacheKey) {
        return $script:EmployeeNameMapCache.Value
    }

    try {
        $map = Read-TextFileCached -Path $mappingFile | ConvertFrom-Json
        if ($null -eq $map) {
            $emptyMap = [PSCustomObject]@{}
            $script:EmployeeNameMapCache = [PSCustomObject]@{
                Key = $cacheKey
                Value = $emptyMap
            }
            return $emptyMap
        }
        $script:EmployeeNameMapCache = [PSCustomObject]@{
            Key = $cacheKey
            Value = $map
        }
        return $map
    }
    catch {
        $emptyMap = [PSCustomObject]@{}
        $script:EmployeeNameMapCache = [PSCustomObject]@{
            Key = $cacheKey
            Value = $emptyMap
        }
        return $emptyMap
    }
}

function Get-EmployeeName($code) {
    $employeeNames = Get-EmployeeNameMap
    if ($employeeNames -and ($employeeNames.PSObject.Properties.Name -contains $code)) {
        return $employeeNames.$code
    }
    return $code
}

function Get-Projects {
    if (!(Test-Path -Path $projectsFile)) {
        Write-JsonAtomic -Path $projectsFile -Value @() -Depth 3
    }

    $metadata = Get-FileMetadataSnapshot -Path $projectsFile
    $cacheKey = if ($null -ne $metadata) { "{0}:{1}" -f $metadata.LastWriteTicks, $metadata.Length } else { "missing" }
    if ($script:ProjectsCache -and $script:ProjectsCache.Key -eq $cacheKey) {
        return @($script:ProjectsCache.Value)
    }

    try {
        $projects = Read-TextFileCached -Path $projectsFile | ConvertFrom-Json
        if ($null -eq $projects) {
            $script:ProjectsCache = [PSCustomObject]@{
                Key   = $cacheKey
                Value = @()
            }
            return @()
        }

        $normalizedProjects = New-Object System.Collections.ArrayList
        if (-not ($projects -is [System.Collections.IEnumerable]) -or ($projects -is [string])) {
            [void]$normalizedProjects.Add((ConvertTo-NormalizedProjectObject -Project $projects))
        }
        else {
            foreach ($project in @($projects)) {
                [void]$normalizedProjects.Add((ConvertTo-NormalizedProjectObject -Project $project))
            }
        }

        $result = @($normalizedProjects.ToArray())
        $script:ProjectsCache = [PSCustomObject]@{
            Key   = $cacheKey
            Value = $result
        }
        return $result
    }
    catch {
        $script:ProjectsCache = [PSCustomObject]@{
            Key   = $cacheKey
            Value = @()
        }
        return @()
    }
}

function ConvertTo-CodeArray {
    param($Value)

    $codes = @()
    if ($null -eq $Value) {
        return $codes
    }

    if ($Value -is [string]) {
        $codes = @($Value -split "[,;]" | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    elseif (($Value -is [System.Collections.IEnumerable])) {
        foreach ($item in @($Value)) {
            if ($null -eq $item) {
                continue
            }

            if ($item -is [string]) {
                $candidate = ([string]$item).Trim()
            }
            elseif ($item.PSObject.Properties.Name -contains "employeeCode") {
                $candidate = ([string]$item.employeeCode).Trim()
            }
            elseif ($item.PSObject.Properties.Name -contains "code") {
                $candidate = ([string]$item.code).Trim()
            }
            else {
                $candidate = ([string]$item).Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $codes += $candidate
            }
        }
    }
    else {
        $candidate = ([string]$Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $codes += $candidate
        }
    }

    return @($codes | Sort-Object -Unique)
}

function Get-ProjectAdminCodes {
    param($Project)

    if ($null -eq $Project) {
        return @()
    }

    if ($Project.PSObject.Properties.Name -contains "admins") {
        return (ConvertTo-CodeArray -Value $Project.admins)
    }
    if ($Project.PSObject.Properties.Name -contains "adminEmployeeCodes") {
        return (ConvertTo-CodeArray -Value $Project.adminEmployeeCodes)
    }
    if ($Project.PSObject.Properties.Name -contains "adminEmployeeCode") {
        return (ConvertTo-CodeArray -Value $Project.adminEmployeeCode)
    }
    if ($Project.PSObject.Properties.Name -contains "admin") {
        return (ConvertTo-CodeArray -Value $Project.admin)
    }

    return @()
}

function Get-ProjectBackupAdminCodes {
    param($Project)

    if ($null -eq $Project) {
        return @()
    }

    if ($Project.PSObject.Properties.Name -contains "backupAdmins") {
        return (ConvertTo-CodeArray -Value $Project.backupAdmins)
    }
    if ($Project.PSObject.Properties.Name -contains "backupAdminEmployeeCodes") {
        return (ConvertTo-CodeArray -Value $Project.backupAdminEmployeeCodes)
    }
    if ($Project.PSObject.Properties.Name -contains "backupAdminEmployeeCode") {
        return (ConvertTo-CodeArray -Value $Project.backupAdminEmployeeCode)
    }
    if ($Project.PSObject.Properties.Name -contains "backupAdmin") {
        return (ConvertTo-CodeArray -Value $Project.backupAdmin)
    }

    return @()
}

function Test-ProjectArchived {
    param($Project)

    if ($null -eq $Project -or -not ($Project.PSObject.Properties.Name -contains "archived")) {
        return $false
    }

    $archivedValue = $Project.archived
    if ($archivedValue -is [bool]) {
        return [bool]$archivedValue
    }
    if ($archivedValue -is [int]) {
        return ([int]$archivedValue -ne 0)
    }

    $normalizedValue = ([string]$archivedValue).Trim().ToLowerInvariant()
    return ($normalizedValue -eq "true" -or $normalizedValue -eq "1" -or $normalizedValue -eq "yes")
}

function ConvertTo-NormalizedProjectObject {
    param($Project)

    if ($null -eq $Project) {
        return $null
    }

    $sector = ""
    if ($Project.PSObject.Properties.Name -contains "sector") {
        $sector = [string]$Project.sector
    }
    elseif ($Project.PSObject.Properties.Name -contains "secteur") {
        $sector = [string]$Project.secteur
    }

    return [PSCustomObject]@{
        projectCode  = [string]$Project.projectCode
        projectName  = [string]$Project.projectName
        sector       = $sector
        admins       = @(Get-ProjectAdminCodes -Project $Project)
        backupAdmins = @(Get-ProjectBackupAdminCodes -Project $Project)
        archived     = Test-ProjectArchived -Project $Project
    }
}

function Get-ActiveProjects {
    return @((Get-Projects) | Where-Object { -not (Test-ProjectArchived -Project $_) })
}

function Get-OvertimeCodes {
    return (Read-JsonOptionArray -Path $overtimeCodesFile)
}

function Read-JsonOptionArray {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (!(Test-Path -Path $Path)) {
        Write-JsonAtomic -Path $Path -Value @() -Depth 3
    }

    $metadata = Get-FileMetadataSnapshot -Path $Path
    if ($null -eq $metadata) {
        return @()
    }

    $cacheKey = [string]$metadata.Path
    $cacheEntry = $script:JsonOptionArrayCache[$cacheKey]
    if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
        return @($cacheEntry.Items)
    }

    try {
        $items = Read-TextFileCached -Path $metadata.Path | ConvertFrom-Json
        if ($null -eq $items) {
            $script:JsonOptionArrayCache[$cacheKey] = [PSCustomObject]@{
                LastWriteTicks = $metadata.LastWriteTicks
                Length         = $metadata.Length
                Items          = @()
            }
            return @()
        }
        if (-not ($items -is [System.Collections.IEnumerable]) -or ($items -is [string])) {
            $items = @($items)
        }
        else {
            $items = @($items)
        }

        $script:JsonOptionArrayCache[$cacheKey] = [PSCustomObject]@{
            LastWriteTicks = $metadata.LastWriteTicks
            Length         = $metadata.Length
            Items          = $items
        }
        return $items
    }
    catch {
        return @()
    }
}

function Get-PaymentOptions {
    return (Read-JsonOptionArray -Path $paymentOptionsFile)
}

function Get-ReasonCodes {
    return (Read-JsonOptionArray -Path $reasonCodesFile)
}

function Test-OptionCode {
    param(
        [Parameter(Mandatory = $true)]$Options,
        [AllowNull()][string]$Code,
        [bool]$AllowBlank = $false
    )

    $candidate = [string]$Code
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $AllowBlank
    }

    return [bool](@($Options | Where-Object { [string]$_.code -eq $candidate } | Select-Object -First 1).Count -gt 0)
}

function Read-JsonRequestBody {
    param($Request)

    $reader = New-Object IO.StreamReader($Request.InputStream)
    try {
        $rawBody = $reader.ReadToEnd()
    }
    finally {
        $reader.Close()
    }

    if ([string]::IsNullOrWhiteSpace($rawBody)) {
        return $null
    }

    return ($rawBody | ConvertFrom-Json)
}

# Helper: Format a time string from "HH:mm:ss" to a history-friendly format ("HHhmm")
function Format-TimeForHistory($timeString) {
    if ($timeString -and $timeString.Length -ge 5) {
        $t = $timeString.Substring(0, 5)  # Get HH:mm
        return $t -replace ":", "h"
    }
    return $timeString
}
