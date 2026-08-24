$projectCatalogModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.ProjectCatalog.psd1"
Import-Module -Name $projectCatalogModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name projectCatalogModuleManifest -ErrorAction SilentlyContinue

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
function Read-EmployeeNameMapFromDisk {
    $raw = Read-TextFileCached -Path $mappingFile
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "null") {
        return [PSCustomObject]@{}
    }

    try {
        $map = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw (New-Object System.IO.InvalidDataException(
            ("Persistent JSON file is invalid and was left unchanged: {0}" -f $mappingFile),
            $_.Exception
        ))
    }

    if ($null -eq $map) {
        return [PSCustomObject]@{}
    }
    if (($map -is [System.Collections.IEnumerable]) -and -not ($map -is [string])) {
        throw [System.IO.InvalidDataException]::new("Employee-name mapping must be a JSON object: $mappingFile")
    }
    if (-not ($map.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject") -and
        -not ($map -is [System.Collections.IDictionary])) {
        throw [System.IO.InvalidDataException]::new("Employee-name mapping must be a JSON object: $mappingFile")
    }

    return $map
}

function Get-EmployeeNameMap {
    if (-not (Test-SaphirFileExists -Path $mappingFile)) {
        $mappingLock = Acquire-ResourceLock -ResourcePath $mappingFile
        try {
            if (-not (Test-SaphirFileExists -Path $mappingFile)) {
                Write-JsonAtomic -Path $mappingFile -Value @{} -Depth 3
            }
        }
        finally {
            Release-ResourceLock -LockHandle $mappingLock
        }
    }

    $metadata = Get-FileMetadataSnapshot -Path $mappingFile
    $cacheKey = if ($null -ne $metadata) { "{0}:{1}" -f $metadata.LastWriteTicks, $metadata.Length } else { "missing" }
    if ($script:EmployeeNameMapCache -and $script:EmployeeNameMapCache.Key -eq $cacheKey) {
        return $script:EmployeeNameMapCache.Value
    }

    $map = Read-EmployeeNameMapFromDisk
    $script:EmployeeNameMapCache = [PSCustomObject]@{
        Key = $cacheKey
        Value = $map
    }
    return $map
}

function Get-EmployeeName($code) {
    $employeeNames = Get-EmployeeNameMap
    if ($employeeNames -and ($employeeNames.PSObject.Properties.Name -contains $code)) {
        return $employeeNames.$code
    }
    return $code
}

function Get-ProjectColorKeys {
    return (Saphir.ProjectCatalog\Get-ProjectColorKeys)
}

function Get-DefaultProjectColorKey {
    param([AllowNull()][string]$ProjectCode)

    return (Saphir.ProjectCatalog\Get-DefaultProjectColorKey -ProjectCode $ProjectCode)
}

function Test-ProjectColorKey {
    param([AllowNull()][string]$ColorKey)

    return (Saphir.ProjectCatalog\Test-ProjectColorKey -ColorKey $ColorKey)
}

function Resolve-ProjectColorKey {
    param(
        [AllowNull()][string]$ColorKey,
        [AllowNull()][string]$ProjectCode
    )

    return (Saphir.ProjectCatalog\Resolve-ProjectColorKey -ColorKey $ColorKey -ProjectCode $ProjectCode)
}

function Get-ProjectMarkerKeys {
    return (Saphir.ProjectCatalog\Get-ProjectMarkerKeys)
}

function Get-DefaultProjectMarkerKey {
    param([AllowNull()][string]$ProjectCode)

    return (Saphir.ProjectCatalog\Get-DefaultProjectMarkerKey -ProjectCode $ProjectCode)
}

function Test-ProjectMarkerKey {
    param([AllowNull()][string]$MarkerKey)

    return (Saphir.ProjectCatalog\Test-ProjectMarkerKey -MarkerKey $MarkerKey)
}

function Resolve-ProjectMarkerKey {
    param(
        [AllowNull()][string]$MarkerKey,
        [AllowNull()][string]$ProjectCode
    )

    return (Saphir.ProjectCatalog\Resolve-ProjectMarkerKey -MarkerKey $MarkerKey -ProjectCode $ProjectCode)
}

function Set-ProjectRecordColorKey {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [AllowNull()][string]$ColorKey
    )

    $resolved = Resolve-ProjectColorKey -ColorKey $ColorKey -ProjectCode ([string]$Project.projectCode)
    if ($Project.PSObject.Properties.Name -contains "colorKey") {
        $Project.colorKey = $resolved
    }
    else {
        $Project | Add-Member -NotePropertyName colorKey -NotePropertyValue $resolved
    }
    return $resolved
}

function Set-ProjectRecordMarkerKey {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [AllowNull()][string]$MarkerKey
    )

    $resolved = Resolve-ProjectMarkerKey -MarkerKey $MarkerKey -ProjectCode ([string]$Project.projectCode)
    if ($Project.PSObject.Properties.Name -contains "markerKey") {
        $Project.markerKey = $resolved
    }
    else {
        $Project | Add-Member -NotePropertyName markerKey -NotePropertyValue $resolved
    }
    return $resolved
}

function Read-ProjectsFromDisk {
    $projects = @(Read-JsonArrayFile -Path $projectsFile)
    $normalizedProjects = New-Object System.Collections.ArrayList
    foreach ($project in $projects) {
        if ($null -ne $project) {
            [void]$normalizedProjects.Add((ConvertTo-NormalizedProjectObject -Project $project))
        }
    }
    return @($normalizedProjects.ToArray())
}

function Get-Projects {
    if (-not (Test-SaphirFileExists -Path $projectsFile)) {
        $projectsLock = Acquire-ResourceLock -ResourcePath $projectsFile
        try {
            if (-not (Test-SaphirFileExists -Path $projectsFile)) {
                Write-JsonArrayAtomic -Path $projectsFile -Items @() -Depth 3
            }
        }
        finally {
            Release-ResourceLock -LockHandle $projectsLock
        }
    }

    $metadata = Get-FileMetadataSnapshot -Path $projectsFile
    $cacheKey = if ($null -ne $metadata) { "{0}:{1}" -f $metadata.LastWriteTicks, $metadata.Length } else { "missing" }
    if ($script:ProjectsCache -and $script:ProjectsCache.Key -eq $cacheKey) {
        return @($script:ProjectsCache.Value)
    }

    $result = @(Read-ProjectsFromDisk)
    $script:ProjectsCache = [PSCustomObject]@{
        Key   = $cacheKey
        Value = $result
    }
    return $result
}

function ConvertTo-CodeArray {
    param($Value)

    return (Saphir.ProjectCatalog\ConvertTo-CodeArray -Value $Value)
}

function Get-ProjectAdminCodes {
    param($Project)

    return (Saphir.ProjectCatalog\Get-ProjectAdminCodes -Project $Project)
}

function Get-ProjectBackupAdminCodes {
    param($Project)

    return (Saphir.ProjectCatalog\Get-ProjectBackupAdminCodes -Project $Project)
}

function Test-ProjectArchived {
    param($Project)

    return (Saphir.ProjectCatalog\Test-ProjectArchived -Project $Project)
}

function ConvertTo-NormalizedProjectObject {
    param($Project)

    return (Saphir.ProjectCatalog\ConvertTo-NormalizedProjectObject -Project $Project)
}

function Get-ActiveProjects {
    return @((Get-Projects) | Where-Object { -not (Test-ProjectArchived -Project $_) })
}

function ConvertTo-ProjectArchiveScope {
    param([AllowNull()][string]$Scope)

    return (Saphir.ProjectCatalog\ConvertTo-ProjectArchiveScope -Scope $Scope)
}

function Select-ProjectsByArchiveScope {
    param(
        $Projects,
        [AllowNull()][string]$Scope = "active"
    )

    return (Saphir.ProjectCatalog\Select-ProjectsByArchiveScope -Projects $Projects -Scope $Scope)
}

function Acquire-ProjectReferenceLock {
    # This logical resource coordinates catalog rename/delete operations with
    # every transaction that can write a project code into an employee entry.
    # No physical guard file is required; FileStore hashes the resource path
    # into the shared .locks directory.
    $guardResource = Join-Path -Path $sharedFolder -ChildPath ".project-references"
    return (Acquire-ResourceLock -ResourcePath $guardResource)
}

function Test-ActiveProjectCodeFromDisk {
    param([AllowNull()][string]$ProjectCode)

    $candidate = ([string]$ProjectCode).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $false
    }

    foreach ($project in @(Read-ProjectsFromDisk)) {
        if ([string]$project.projectCode -eq $candidate -and -not (Test-ProjectArchived -Project $project)) {
            return $true
        }
    }

    return $false
}

function Get-OvertimeCodes {
    return (Read-JsonOptionArray -Path $overtimeCodesFile)
}

function Read-JsonOptionArray {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-SaphirFileExists -Path $Path)) {
        $optionLock = Acquire-ResourceLock -ResourcePath $Path
        try {
            if (-not (Test-SaphirFileExists -Path $Path)) {
                Write-JsonArrayAtomic -Path $Path -Items @() -Depth 3
            }
        }
        finally {
            Release-ResourceLock -LockHandle $optionLock
        }
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

    $items = @(Read-JsonArrayFile -Path $metadata.Path)
    $script:JsonOptionArrayCache[$cacheKey] = [PSCustomObject]@{
        LastWriteTicks = $metadata.LastWriteTicks
        Length         = $metadata.Length
        Items          = $items
    }
    return $items
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

function Invoke-PostCommitActionSafely {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    try {
        & $Action | Out-Null
        return ""
    }
    catch {
        $warning = "{0}: {1}" -f $Description, $_.Exception.Message
        Write-Warning $warning
        return $warning
    }
}

function Read-JsonRequestBody {
    param(
        $Request,
        [int]$MaxBytes = 2097152,
        [int]$TimeoutMs = 15000
    )

    $declaredLength = -1L
    if ($null -ne $Request -and $Request.PSObject.Properties.Name -contains "ContentLength64") {
        $declaredLength = [long]$Request.ContentLength64
    }
    if ($declaredLength -gt $MaxBytes) {
        $bodyTooLargeException = [System.IO.InvalidDataException]::new("Request body exceeds the $MaxBytes byte limit.")
        $bodyTooLargeException.Data["SaphirHttpStatusCode"] = 413
        throw $bodyTooLargeException
    }

    $inputStream = $Request.InputStream
    $memory = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    $deadlineUtc = (Get-Date).ToUniversalTime().AddMilliseconds($TimeoutMs)
    try {
        while ($true) {
            $remainingMs = [int][Math]::Ceiling(($deadlineUtc - (Get-Date).ToUniversalTime()).TotalMilliseconds)
            if ($remainingMs -le 0) {
                $bodyTimeoutException = [System.TimeoutException]::new("Timed out while reading the request body.")
                $bodyTimeoutException.Data["SaphirHttpStatusCode"] = 408
                throw $bodyTimeoutException
            }

            $readTask = $inputStream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait($remainingMs)) {
                $bodyTimeoutException = [System.TimeoutException]::new("Timed out while reading the request body.")
                $bodyTimeoutException.Data["SaphirHttpStatusCode"] = 408
                throw $bodyTimeoutException
            }

            $bytesRead = [int]$readTask.Result
            if ($bytesRead -le 0) {
                break
            }

            $memory.Write($buffer, 0, $bytesRead)
            if ($memory.Length -gt $MaxBytes) {
                $bodyTooLargeException = [System.IO.InvalidDataException]::new("Request body exceeds the $MaxBytes byte limit.")
                $bodyTooLargeException.Data["SaphirHttpStatusCode"] = 413
                throw $bodyTooLargeException
            }
        }

        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        try {
            $rawBody = $utf8Strict.GetString($memory.ToArray())
        }
        catch [System.Text.DecoderFallbackException] {
            $utf8Exception = [System.FormatException]::new("Request body must use valid UTF-8.", $_.Exception)
            $utf8Exception.Data["SaphirHttpStatusCode"] = 400
            throw $utf8Exception
        }
    }
    finally {
        $memory.Dispose()
        try { $inputStream.Close() } catch { }
    }

    if ([string]::IsNullOrWhiteSpace($rawBody)) {
        return $null
    }

    try {
        return ($rawBody | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        $jsonException = [System.FormatException]::new("Request body must contain valid JSON.", $_.Exception)
        $jsonException.Data["SaphirHttpStatusCode"] = 400
        throw $jsonException
    }
}

# Helper: Format a time string from "HH:mm:ss" to a history-friendly format ("HHhmm")
function Format-TimeForHistory($timeString) {
    if ($timeString -and $timeString.Length -ge 5) {
        $t = $timeString.Substring(0, 5)  # Get HH:mm
        return $t -replace ":", "h"
    }
    return $timeString
}
