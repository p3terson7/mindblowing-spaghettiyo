function Get-ProjectColorKeys {
    return @("blue", "green", "violet", "teal", "amber", "coral", "pink", "indigo", "graphite", "mint")
}

function Get-ProjectMarkerKeys {
    return @("circle", "square", "diamond", "triangle")
}

function Get-ProjectColorKeyFromText {
    param([AllowNull()][string]$ProjectCodeText)

    $palette = @(Get-ProjectColorKeys)
    $hash = 0
    foreach ($character in ([string]$ProjectCodeText).ToUpperInvariant().ToCharArray()) {
        $hash = (($hash * 31) + [int][char]$character) % $palette.Count
    }
    return $palette[[math]::Abs($hash)]
}

function Get-DefaultProjectColorKey {
    param([AllowNull()][string]$ProjectCode)

    # The historical project catalog helper trims its code before hashing.
    # Consumers with a different legacy convention can call the lower-level
    # text primitive after preparing the exact token they need to preserve.
    return (Get-ProjectColorKeyFromText -ProjectCodeText ([string]$ProjectCode).Trim())
}

function Test-ProjectColorKey {
    param([AllowNull()][string]$ColorKey)

    $candidate = ([string]$ColorKey).Trim().ToLowerInvariant()
    return (-not [string]::IsNullOrWhiteSpace($candidate) -and @(Get-ProjectColorKeys) -contains $candidate)
}

function Resolve-ProjectColorKey {
    param(
        [AllowNull()][string]$ColorKey,
        [AllowNull()][string]$ProjectCode
    )

    $candidate = ([string]$ColorKey).Trim().ToLowerInvariant()
    if (Test-ProjectColorKey -ColorKey $candidate) {
        return $candidate
    }
    return (Get-DefaultProjectColorKey -ProjectCode $ProjectCode)
}

function Get-ProjectMarkerKeyFromText {
    param([AllowNull()][string]$ProjectCodeText)

    $colorCount = @(Get-ProjectColorKeys).Count
    $markers = @(Get-ProjectMarkerKeys)
    $identityCount = $colorCount * $markers.Count
    $hash = 0
    foreach ($character in ([string]$ProjectCodeText).ToUpperInvariant().ToCharArray()) {
        $hash = (($hash * 31) + [int][char]$character) % $identityCount
    }

    # The identity bucket deliberately keeps the existing color in its low
    # digit: bucket % 10 is exactly the historical color hash, while the
    # quotient supplies one of four additional markers.
    $markerIndex = [int]([math]::Floor(([math]::Abs($hash) / $colorCount)) % $markers.Count)
    return $markers[$markerIndex]
}

function Get-DefaultProjectMarkerKey {
    param([AllowNull()][string]$ProjectCode)

    return (Get-ProjectMarkerKeyFromText -ProjectCodeText ([string]$ProjectCode).Trim())
}

function Test-ProjectMarkerKey {
    param([AllowNull()][string]$MarkerKey)

    $candidate = ([string]$MarkerKey).Trim().ToLowerInvariant()
    return (-not [string]::IsNullOrWhiteSpace($candidate) -and @(Get-ProjectMarkerKeys) -contains $candidate)
}

function Resolve-ProjectMarkerKey {
    param(
        [AllowNull()][string]$MarkerKey,
        [AllowNull()][string]$ProjectCode
    )

    $candidate = ([string]$MarkerKey).Trim().ToLowerInvariant()
    if (Test-ProjectMarkerKey -MarkerKey $candidate) {
        return $candidate
    }
    return (Get-DefaultProjectMarkerKey -ProjectCode $ProjectCode)
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

    # Preserve fields introduced by newer releases. Older servers may still
    # normalize the fields they understand, but must not erase unknown data.
    $normalized = [ordered]@{}
    foreach ($property in @($Project.PSObject.Properties)) {
        $normalized[[string]$property.Name] = $property.Value
    }
    $normalized["projectCode"] = [string]$Project.projectCode
    $normalized["projectName"] = [string]$Project.projectName
    $normalized["sector"] = $sector
    $normalized["admins"] = @(Get-ProjectAdminCodes -Project $Project)
    $normalized["backupAdmins"] = @(Get-ProjectBackupAdminCodes -Project $Project)
    $normalized["archived"] = Test-ProjectArchived -Project $Project
    $storedColorKey = if ($Project.PSObject.Properties.Name -contains "colorKey") { [string]$Project.colorKey } else { "" }
    $normalized["colorKey"] = Resolve-ProjectColorKey -ColorKey $storedColorKey -ProjectCode ([string]$Project.projectCode)
    $storedMarkerKey = if ($Project.PSObject.Properties.Name -contains "markerKey") { [string]$Project.markerKey } else { "" }
    $normalized["markerKey"] = Resolve-ProjectMarkerKey -MarkerKey $storedMarkerKey -ProjectCode ([string]$Project.projectCode)

    return [PSCustomObject]$normalized
}

function ConvertTo-ProjectArchiveScope {
    param([AllowNull()][string]$Scope)

    $normalizedScope = ([string]$Scope).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedScope)) {
        return "active"
    }

    if (@("active", "archived", "all") -notcontains $normalizedScope) {
        throw [System.ArgumentException]::new("Project scope must be active, archived, or all.")
    }

    return $normalizedScope
}

function Select-ProjectsByArchiveScope {
    param(
        $Projects,
        [AllowNull()][string]$Scope = "active"
    )

    $normalizedScope = ConvertTo-ProjectArchiveScope -Scope $Scope
    $projectList = @($Projects)
    if ($normalizedScope -eq "all") {
        return @($projectList)
    }
    if ($normalizedScope -eq "archived") {
        return @($projectList | Where-Object { Test-ProjectArchived -Project $_ })
    }

    # Missing archive metadata is the legacy representation of an active
    # project, so old catalogs remain usable without a migration or rewrite.
    return @($projectList | Where-Object { -not (Test-ProjectArchived -Project $_) })
}

Export-ModuleMember -Function @(
    "Get-ProjectColorKeys",
    "Get-ProjectColorKeyFromText",
    "Get-DefaultProjectColorKey",
    "Test-ProjectColorKey",
    "Resolve-ProjectColorKey",
    "Get-ProjectMarkerKeys",
    "Get-ProjectMarkerKeyFromText",
    "Get-DefaultProjectMarkerKey",
    "Test-ProjectMarkerKey",
    "Resolve-ProjectMarkerKey",
    "ConvertTo-CodeArray",
    "Get-ProjectAdminCodes",
    "Get-ProjectBackupAdminCodes",
    "Test-ProjectArchived",
    "ConvertTo-NormalizedProjectObject",
    "ConvertTo-ProjectArchiveScope",
    "Select-ProjectsByArchiveScope"
)
