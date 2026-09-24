function Get-CompensationObjectPropertyValue {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ([string]$key -ieq $Name) {
                return $Value[$key]
            }
        }
    }

    foreach ($property in @($Value.PSObject.Properties)) {
        if ([string]$property.Name -ieq $Name) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-CompensationGridCode {
    <#
        This uses the same compact, uppercase code shape as the three GC179
        classification fields. Blank values are represented as an empty string
        here so callers can decide whether a field is optional; salary bands
        themselves require all three classification fields.
    #>
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][int]$MaximumLength
    )

    if ($MaximumLength -lt 1) {
        throw [System.ArgumentException]::new("MaximumLength must be positive.")
    }

    $normalized = ([string]$Value).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, "\s+", "")
    if ($normalized.Length -gt $MaximumLength) {
        throw [System.ArgumentException]::new(("Classification code must be at most {0} characters." -f $MaximumLength))
    }
    if (-not [System.Text.RegularExpressions.Regex]::IsMatch($normalized, "^[0-9A-Z._/-]+$")) {
        throw [System.ArgumentException]::new("Classification codes may contain only letters, digits, periods, underscores, slashes, and hyphens.")
    }

    return $normalized
}

function ConvertTo-CompensationGroupCode {
    param([AllowNull()][string]$Value)

    $normalized = ([string]$Value).Trim().ToUpperInvariant()
    if ($normalized -ne "" -and $normalized -cnotmatch "^[A-Z]{1,6}$") {
        throw [System.ArgumentException]::new("Group must contain 1 to 6 letters only.")
    }

    return $normalized
}

function ConvertTo-CompensationTwoDigitCode {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    $digits = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($digits)) {
        return ""
    }
    if ($digits -cnotmatch "^[0-9]{1,2}$") {
        throw [System.ArgumentException]::new(("{0} must contain one or two digits only." -f $FieldName))
    }

    return $digits.PadLeft(2, "0")
}

function ConvertTo-CompensationEffectiveDate {
    param(
        $Value,
        [bool]$AllowEmpty = $false,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($AllowEmpty) {
            return $null
        }
        throw [System.ArgumentException]::new(("{0} is required and must use YYYY-MM-DD." -f $FieldName))
    }

    $parsed = [DateTime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::None
    $isValid = [DateTime]::TryParseExact($text, "yyyy-MM-dd", $culture, $styles, [ref]$parsed)
    if (-not $isValid) {
        throw [System.ArgumentException]::new(("{0} must use YYYY-MM-DD." -f $FieldName))
    }

    return $parsed.ToString("yyyy-MM-dd", $culture)
}

function ConvertTo-CompensationSalaryCents {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($null -eq $Value) {
        throw [System.ArgumentException]::new(("{0} is required." -f $FieldName))
    }

    # Cents are intentionally stored as an integer. The file-backed service
    # or UI can convert an annual dollar input to cents before it reaches this
    # pure model, avoiding floating point rounding in payroll calculations.
    $text = ([string]$Value).Trim()
    if (-not [System.Text.RegularExpressions.Regex]::IsMatch($text, "^[0-9]+$")) {
        throw [System.ArgumentException]::new(("{0} must be a positive whole number of cents." -f $FieldName))
    }

    $cents = [Int64]0
    $isValid = [Int64]::TryParse($text, [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$cents)
    if (-not $isValid -or $cents -le 0) {
        throw [System.ArgumentException]::new(("{0} must be a positive whole number of cents." -f $FieldName))
    }

    # This is a validation guardrail, not a business salary limit. It keeps
    # malformed values from becoming unreasonable monetary amounts while
    # leaving the actual pay scale entirely editable in configuration.
    if ($cents -gt 999999999999) {
        throw [System.ArgumentException]::new(("{0} is outside the supported range." -f $FieldName))
    }

    return $cents
}

function ConvertTo-CompensationBandId {
    param($Value)

    $id = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw [System.ArgumentException]::new("Salary band id is required.")
    }
    if ($id.Length -gt 80 -or -not [System.Text.RegularExpressions.Regex]::IsMatch($id, "^[0-9A-Za-z][0-9A-Za-z._-]*$")) {
        throw [System.ArgumentException]::new("Salary band id must start with a letter or digit and contain only letters, digits, periods, underscores, or hyphens.")
    }

    return $id
}

function Get-CompensationBandClassificationKey {
    param([Parameter(Mandatory = $true)]$Band)

    $separator = [string][char]31
    return ("{0}{1}{2}{1}{3}" -f [string]$Band.group, $separator, [string]$Band.subGroup, [string]$Band.level)
}

function Get-CompensationEffectiveDateValue {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    $normalized = ConvertTo-CompensationEffectiveDate -Value $Value -AllowEmpty $false -FieldName $FieldName
    return [DateTime]::ParseExact($normalized, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-CompensationBandDateRangesOverlap {
    param(
        [Parameter(Mandatory = $true)]$First,
        [Parameter(Mandatory = $true)]$Second
    )

    $firstStart = Get-CompensationEffectiveDateValue -Value ([string]$First.effectiveFrom) -FieldName "effectiveFrom"
    $secondStart = Get-CompensationEffectiveDateValue -Value ([string]$Second.effectiveFrom) -FieldName "effectiveFrom"
    $firstEnd = if ($null -eq $First.effectiveTo) { [DateTime]::MaxValue.Date } else { Get-CompensationEffectiveDateValue -Value ([string]$First.effectiveTo) -FieldName "effectiveTo" }
    $secondEnd = if ($null -eq $Second.effectiveTo) { [DateTime]::MaxValue.Date } else { Get-CompensationEffectiveDateValue -Value ([string]$Second.effectiveTo) -FieldName "effectiveTo" }

    return ($firstStart -le $secondEnd -and $secondStart -le $firstEnd)
}

function Get-CompensationSalaryGridValidationResult {
    param($Value)

    $errors = New-Object System.Collections.ArrayList
    $normalizedBands = New-Object System.Collections.ArrayList

    if ($null -eq $Value) {
        [void]$errors.Add("Salary grid document is required.")
        return [PSCustomObject]@{ errors = @($errors.ToArray()); document = $null }
    }

    $schemaVersionRaw = Get-CompensationObjectPropertyValue -Value $Value -Name "schemaVersion"
    $schemaVersionText = ([string]$schemaVersionRaw).Trim()
    if ($schemaVersionText -ne "1") {
        [void]$errors.Add("Salary grid schemaVersion must be 1.")
    }

    $currencyRaw = Get-CompensationObjectPropertyValue -Value $Value -Name "currency"
    $currency = ([string]$currencyRaw).Trim().ToUpperInvariant()
    if ($currency -ne "CAD") {
        [void]$errors.Add("Salary grid currency must be CAD.")
    }

    $bandsRaw = Get-CompensationObjectPropertyValue -Value $Value -Name "bands"
    if ($null -eq $bandsRaw -or $bandsRaw -is [string] -or -not ($bandsRaw -is [System.Collections.IEnumerable])) {
        [void]$errors.Add("Salary grid bands must be an array.")
    }
    else {
        $bands = @($bandsRaw)
        if ($bands.Count -eq 0) {
            [void]$errors.Add("Salary grid must contain at least one band.")
        }
        elseif ($bands.Count -gt 500) {
            [void]$errors.Add("Salary grid cannot contain more than 500 bands.")
        }
        else {
            for ($index = 0; $index -lt $bands.Count; $index++) {
                try {
                    $band = ConvertTo-CompensationSalaryBand -Value $bands[$index]
                    [void]$normalizedBands.Add($band)
                }
                catch {
                    [void]$errors.Add(("Band {0}: {1}" -f ($index + 1), $_.Exception.Message))
                }
            }
        }
    }

    $ids = @{}
    foreach ($band in @($normalizedBands.ToArray())) {
        $idKey = ([string]$band.id).ToUpperInvariant()
        if ($ids.ContainsKey($idKey)) {
            [void]$errors.Add(("Salary band id '{0}' is duplicated." -f [string]$band.id))
        }
        else {
            $ids[$idKey] = $true
        }
    }

    $bandsByClassification = @{}
    foreach ($band in @($normalizedBands.ToArray())) {
        $classificationKey = Get-CompensationBandClassificationKey -Band $band
        if (-not $bandsByClassification.ContainsKey($classificationKey)) {
            $bandsByClassification[$classificationKey] = New-Object System.Collections.ArrayList
        }
        [void]$bandsByClassification[$classificationKey].Add($band)
    }

    foreach ($classificationKey in @($bandsByClassification.Keys)) {
        $sameClassificationBands = @($bandsByClassification[$classificationKey].ToArray())
        for ($firstIndex = 0; $firstIndex -lt $sameClassificationBands.Count; $firstIndex++) {
            for ($secondIndex = $firstIndex + 1; $secondIndex -lt $sameClassificationBands.Count; $secondIndex++) {
                if (Test-CompensationBandDateRangesOverlap -First $sameClassificationBands[$firstIndex] -Second $sameClassificationBands[$secondIndex]) {
                    [void]$errors.Add(("Salary bands '{0}' and '{1}' overlap for the same Group, Sub-group, and Level." -f [string]$sameClassificationBands[$firstIndex].id, [string]$sameClassificationBands[$secondIndex].id))
                }
            }
        }
    }

    if ($errors.Count -gt 0) {
        return [PSCustomObject]@{ errors = @($errors.ToArray()); document = $null }
    }

    return [PSCustomObject]@{
        errors = @()
        document = [PSCustomObject][ordered]@{
            schemaVersion = 1
            currency      = "CAD"
            bands         = @($normalizedBands.ToArray())
        }
    }
}

function ConvertTo-CompensationSalaryBand {
    param([Parameter(Mandatory = $true)]$Value)

    if ($null -eq $Value) {
        throw [System.ArgumentException]::new("Salary band is required.")
    }

    $id = ConvertTo-CompensationBandId -Value (Get-CompensationObjectPropertyValue -Value $Value -Name "id")
    $group = ConvertTo-CompensationGroupCode -Value ([string](Get-CompensationObjectPropertyValue -Value $Value -Name "group"))
    $subGroup = ConvertTo-CompensationTwoDigitCode -Value ([string](Get-CompensationObjectPropertyValue -Value $Value -Name "subGroup")) -FieldName "Sub-group"
    $level = ConvertTo-CompensationTwoDigitCode -Value ([string](Get-CompensationObjectPropertyValue -Value $Value -Name "level")) -FieldName "Level"
    if ([string]::IsNullOrWhiteSpace($group)) {
        throw [System.ArgumentException]::new("Salary band Group is required.")
    }
    if ([string]::IsNullOrWhiteSpace($subGroup)) {
        throw [System.ArgumentException]::new("Salary band Sub-group is required.")
    }
    if ([string]::IsNullOrWhiteSpace($level)) {
        throw [System.ArgumentException]::new("Salary band Level is required.")
    }

    $annualSalaryCents = ConvertTo-CompensationSalaryCents -Value (Get-CompensationObjectPropertyValue -Value $Value -Name "annualSalaryCents") -FieldName "annualSalaryCents"
    $effectiveFrom = ConvertTo-CompensationEffectiveDate -Value (Get-CompensationObjectPropertyValue -Value $Value -Name "effectiveFrom") -FieldName "effectiveFrom"
    $effectiveTo = ConvertTo-CompensationEffectiveDate -Value (Get-CompensationObjectPropertyValue -Value $Value -Name "effectiveTo") -AllowEmpty $true -FieldName "effectiveTo"

    if ($null -ne $effectiveTo) {
        $effectiveFromValue = Get-CompensationEffectiveDateValue -Value $effectiveFrom -FieldName "effectiveFrom"
        $effectiveToValue = Get-CompensationEffectiveDateValue -Value $effectiveTo -FieldName "effectiveTo"
        if ($effectiveToValue -lt $effectiveFromValue) {
            throw [System.ArgumentException]::new("effectiveTo cannot be earlier than effectiveFrom.")
        }
    }

    # The matching key is deliberately the exact canonical GC179 triple.
    # Legacy Poste/Echelon aliases and wildcard fallbacks are not consulted;
    # an incomplete or wrongly classified employee must not get a salary rate.
    return [PSCustomObject][ordered]@{
        id                = $id
        group             = $group
        subGroup          = $subGroup
        level             = $level
        annualSalaryCents = $annualSalaryCents
        effectiveFrom     = $effectiveFrom
        effectiveTo       = $effectiveTo
    }
}

function Test-CompensationSalaryGridDocument {
    param($Value)

    $validation = Get-CompensationSalaryGridValidationResult -Value $Value
    return [PSCustomObject]@{
        isValid  = (@($validation.errors).Count -eq 0)
        errors   = @($validation.errors)
        document = $validation.document
    }
}

function ConvertTo-CompensationSalaryGridDocument {
    param([Parameter(Mandatory = $true)]$Value)

    $validation = Get-CompensationSalaryGridValidationResult -Value $Value
    if (@($validation.errors).Count -gt 0) {
        throw [System.ArgumentException]::new((@($validation.errors) -join " "))
    }

    return $validation.document
}

function Resolve-CompensationSalaryBand {
    <#
        Resolves the rate valid for one specific calendar day. The caller must
        pass the entry date explicitly; this module never reads the clock. A
        missing or invalid employee classification produces no match rather
        than using legacy profile fields or an inferred default.
    #>
    param(
        [Parameter(Mandatory = $true)]$SalaryGrid,
        [AllowNull()][string]$Group,
        [AllowNull()][string]$SubGroup,
        [AllowNull()][string]$Level,
        [Parameter(Mandatory = $true)][DateTime]$AsOfDate
    )

    $document = ConvertTo-CompensationSalaryGridDocument -Value $SalaryGrid
    $normalizedGroup = ConvertTo-CompensationGroupCode -Value $Group
    $normalizedSubGroup = ConvertTo-CompensationTwoDigitCode -Value $SubGroup -FieldName "Sub-group"
    $normalizedLevel = ConvertTo-CompensationTwoDigitCode -Value $Level -FieldName "Level"
    if ([string]::IsNullOrWhiteSpace($normalizedGroup) -or
        [string]::IsNullOrWhiteSpace($normalizedSubGroup) -or
        [string]::IsNullOrWhiteSpace($normalizedLevel)) {
        return $null
    }

    $comparisonDate = $AsOfDate.Date
    foreach ($band in @($document.bands)) {
        if ([string]$band.group -cne $normalizedGroup -or
            [string]$band.subGroup -cne $normalizedSubGroup -or
            [string]$band.level -cne $normalizedLevel) {
            continue
        }

        $effectiveFrom = Get-CompensationEffectiveDateValue -Value ([string]$band.effectiveFrom) -FieldName "effectiveFrom"
        $effectiveTo = if ($null -eq $band.effectiveTo) { [DateTime]::MaxValue.Date } else { Get-CompensationEffectiveDateValue -Value ([string]$band.effectiveTo) -FieldName "effectiveTo" }
        if ($comparisonDate -ge $effectiveFrom -and $comparisonDate -le $effectiveTo) {
            return $band
        }
    }

    return $null
}

Export-ModuleMember -Function @(
    "ConvertTo-CompensationGridCode",
    "ConvertTo-CompensationSalaryBand",
    "Test-CompensationSalaryGridDocument",
    "ConvertTo-CompensationSalaryGridDocument",
    "Resolve-CompensationSalaryBand"
)
