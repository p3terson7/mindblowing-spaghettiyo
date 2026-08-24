function Get-ObjectPropertyValue {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [hashtable] -and $Value.ContainsKey($Name)) {
        return $Value[$Name]
    }

    if ($Value.PSObject.Properties.Name -contains $Name) {
        return $Value.PSObject.Properties[$Name].Value
    }

    return $null
}

function Get-ObjectStringProperty {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $propertyValue = Get-ObjectPropertyValue -Value $Value -Name $Name
    if ($null -ne $propertyValue) {
        return [string]$propertyValue
    }

    return ""
}

function Get-FirstObjectStringProperty {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in @($Names)) {
        $candidate = Get-ObjectStringProperty -Value $Value -Name $name
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return ""
}

function Test-ObjectHasAnyProperty {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Value) {
        return $false
    }

    foreach ($name in @($Names)) {
        if ($Value -is [hashtable] -and $Value.ContainsKey($name)) {
            return $true
        }
        if ($Value.PSObject.Properties.Name -contains $name) {
            return $true
        }
    }

    return $false
}

function ConvertTo-Gc179UpperText {
    param([AllowNull()][string]$Value)

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    return $text.ToUpperInvariant()
}

function Get-Gc179NamePartsFromDisplayName {
    param([AllowNull()][string]$DisplayName)

    $name = ([string]$DisplayName).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return [PSCustomObject]@{
            surname   = ""
            givenName = ""
            initials  = ""
        }
    }

    $tokens = @($name -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $surname = ""
    $givenName = ""
    if ($tokens.Count -eq 1) {
        $surname = [string]$tokens[0]
    }
    else {
        $surname = [string]$tokens[$tokens.Count - 1]
        $givenName = [string]::Join(" ", @($tokens[0..($tokens.Count - 2)]))
    }

    $initialParts = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($givenName)) {
        [void]$initialParts.Add(([string]$givenName).Substring(0, 1).ToUpperInvariant())
    }
    if (-not [string]::IsNullOrWhiteSpace($surname)) {
        [void]$initialParts.Add(([string]$surname).Substring(0, 1).ToUpperInvariant())
    }

    return [PSCustomObject]@{
        surname   = ConvertTo-Gc179UpperText -Value $surname
        givenName = ConvertTo-Gc179UpperText -Value $givenName
        initials  = [string]::Join(".", @($initialParts.ToArray()))
    }
}

function ConvertTo-Gc179BooleanValue {
    param(
        $Value,
        [bool]$DefaultValue = $false
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq "true" -or $text -eq "1" -or $text -eq "yes" -or $text -eq "y" -or $text -eq "on") {
        return $true
    }

    if ($text -eq "false" -or $text -eq "0" -or $text -eq "no" -or $text -eq "n" -or $text -eq "off") {
        return $false
    }

    return $DefaultValue
}

function ConvertTo-Gc179PriText {
    param([AllowNull()][string]$Value)

    $digits = ([string]$Value) -replace "\D", ""
    if ([string]::IsNullOrWhiteSpace($digits)) {
        return ""
    }

    if ($digits.Length -gt 9) {
        $digits = $digits.Substring(0, 9)
    }

    $groups = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $digits.Length; $index += 3) {
        $length = [math]::Min(3, $digits.Length - $index)
        [void]$groups.Add($digits.Substring($index, $length))
    }

    return [string]::Join(" ", @($groups.ToArray()))
}

function ConvertTo-Gc179HeaderCodeText {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][int]$MaximumLength
    )

    if ($MaximumLength -lt 1) {
        return ""
    }

    $normalized = ([string]$Value).Trim().ToUpperInvariant()
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, "\s+", "")
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, "[^0-9A-Z._/-]", "")
    if ($normalized.Length -gt $MaximumLength) {
        $normalized = $normalized.Substring(0, $MaximumLength)
    }

    return $normalized
}

function ConvertTo-Gc179GroupText {
    param([AllowNull()][string]$Value)

    # The GC179 Group field accepts up to six characters. Codes vary by
    # employee (for example CR4, AS-03, or STS), so do not use an allowlist.
    return (ConvertTo-Gc179HeaderCodeText -Value $Value -MaximumLength 6)
}

function ConvertTo-Gc179SubGroupText {
    param([AllowNull()][string]$Value)

    # The GC179 Sub-Group field accepts up to ten characters.
    return (ConvertTo-Gc179HeaderCodeText -Value $Value -MaximumLength 10)
}

function ConvertTo-Gc179LevelText {
    param([AllowNull()][string]$Value)

    # Level/Niveau is a distinct ten-character field in the GC179 header.
    return (ConvertTo-Gc179HeaderCodeText -Value $Value -MaximumLength 10)
}

function ConvertTo-Gc179PositionText {
    param([AllowNull()][string]$Value)

    # Compatibility facade for profile data written before Group was named
    # explicitly in SAPHIR.
    return (ConvertTo-Gc179GroupText -Value $Value)
}

function ConvertTo-Gc179EchelonText {
    param([AllowNull()][string]$Value)

    # Compatibility facade for profile data written before Sub-Group was
    # named explicitly in SAPHIR.
    return (ConvertTo-Gc179SubGroupText -Value $Value)
}

function ConvertTo-Gc179ProfileObject {
    param(
        $Value,
        [AllowNull()][string]$DisplayName
    )

    $fallback = Get-Gc179NamePartsFromDisplayName -DisplayName $DisplayName

    $surname = Get-ObjectStringProperty -Value $Value -Name "surname"
    if ([string]::IsNullOrWhiteSpace($surname)) {
        $surname = Get-ObjectStringProperty -Value $Value -Name "Surname"
    }
    if ([string]::IsNullOrWhiteSpace($surname)) {
        $surname = Get-ObjectStringProperty -Value $Value -Name "lastName"
    }
    if ([string]::IsNullOrWhiteSpace($surname)) {
        $surname = [string]$fallback.surname
    }

    $givenName = Get-ObjectStringProperty -Value $Value -Name "givenName"
    if ([string]::IsNullOrWhiteSpace($givenName)) {
        $givenName = Get-ObjectStringProperty -Value $Value -Name "given"
    }
    if ([string]::IsNullOrWhiteSpace($givenName)) {
        $givenName = Get-ObjectStringProperty -Value $Value -Name "Given"
    }
    if ([string]::IsNullOrWhiteSpace($givenName)) {
        $givenName = [string]$fallback.givenName
    }

    $initials = Get-ObjectStringProperty -Value $Value -Name "initials"
    if ([string]::IsNullOrWhiteSpace($initials)) {
        $initials = Get-ObjectStringProperty -Value $Value -Name "Initials"
    }
    if ([string]::IsNullOrWhiteSpace($initials)) {
        $initials = [string]$fallback.initials
    }

    $pri = Get-ObjectStringProperty -Value $Value -Name "pri"
    if ([string]::IsNullOrWhiteSpace($pri)) {
        $pri = Get-ObjectStringProperty -Value $Value -Name "PRI"
    }

    $groupPropertyNames = @("group", "Group", "groupe", "Groupe")
    $subGroupPropertyNames = @("subGroup", "SubGroup", "subgroup", "SousGroupe", "sousGroupe")
    $hasExplicitGroup = Test-ObjectHasAnyProperty -Value $Value -Names $groupPropertyNames
    $hasExplicitSubGroup = Test-ObjectHasAnyProperty -Value $Value -Names $subGroupPropertyNames

    # Version 2 profiles use the three GC179 field names directly. Legacy
    # profiles had only position + level, where level actually meant
    # Sub-Group. Keep that mapping while reading old shared-disk data.
    $group = Get-FirstObjectStringProperty -Value $Value -Names ($groupPropertyNames + @("position", "Position", "poste", "Poste", "classification", "Classification"))
    $subGroup = Get-FirstObjectStringProperty -Value $Value -Names $subGroupPropertyNames
    if ([string]::IsNullOrWhiteSpace($subGroup) -and -not $hasExplicitGroup -and -not $hasExplicitSubGroup) {
        $subGroup = Get-FirstObjectStringProperty -Value $Value -Names @("echelon", "Echelon", "level", "Level")
    }

    $level = ""
    if ($hasExplicitGroup -or $hasExplicitSubGroup) {
        $level = Get-FirstObjectStringProperty -Value $Value -Names @("level", "Level", "niveau", "Niveau")
    }

    $compressedWorkWeekValue = Get-ObjectPropertyValue -Value $Value -Name "compressedWorkWeek"
    if ($null -eq $compressedWorkWeekValue) {
        $compressedWorkWeekValue = Get-ObjectPropertyValue -Value $Value -Name "isCompressedWorkWeek"
    }
    if ($null -eq $compressedWorkWeekValue) {
        $compressedWorkWeekValue = Get-ObjectPropertyValue -Value $Value -Name "compressed"
    }
    $compressedWorkWeek = ConvertTo-Gc179BooleanValue -Value $compressedWorkWeekValue -DefaultValue $false

    $normalizedGroup = ConvertTo-Gc179GroupText -Value $group
    if ([string]::IsNullOrWhiteSpace($normalizedGroup)) {
        $normalizedGroup = "STS"
    }

    $normalizedSubGroup = ConvertTo-Gc179SubGroupText -Value $subGroup
    if ([string]::IsNullOrWhiteSpace($normalizedSubGroup)) {
        $normalizedSubGroup = "SUF-00"
    }

    return [PSCustomObject]@{
        surname            = ConvertTo-Gc179UpperText -Value $surname
        givenName          = ConvertTo-Gc179UpperText -Value $givenName
        initials           = ConvertTo-Gc179UpperText -Value $initials
        pri                = ConvertTo-Gc179PriText -Value $pri
        group              = $normalizedGroup
        subGroup           = $normalizedSubGroup
        level              = ConvertTo-Gc179LevelText -Value $level
        compressedWorkWeek = [bool]$compressedWorkWeek
    }
}

function Get-Gc179ProfileFromUserRecord {
    param($UserRecord)

    if ($null -eq $UserRecord) {
        return (ConvertTo-Gc179ProfileObject -Value $null -DisplayName "")
    }

    $profile = Get-ObjectPropertyValue -Value $UserRecord -Name "gc179Profile"
    $displayName = Get-ObjectStringProperty -Value $UserRecord -Name "displayName"
    return (ConvertTo-Gc179ProfileObject -Value $profile -DisplayName $displayName)
}

Export-ModuleMember -Function @(
    "ConvertTo-Gc179UpperText",
    "Get-Gc179NamePartsFromDisplayName",
    "ConvertTo-Gc179BooleanValue",
    "ConvertTo-Gc179PriText",
    "ConvertTo-Gc179HeaderCodeText",
    "ConvertTo-Gc179GroupText",
    "ConvertTo-Gc179SubGroupText",
    "ConvertTo-Gc179LevelText",
    "ConvertTo-Gc179PositionText",
    "ConvertTo-Gc179EchelonText",
    "ConvertTo-Gc179ProfileObject",
    "Get-Gc179ProfileFromUserRecord"
)
