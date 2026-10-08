function Get-NormalizedRoleName {
    param([string]$Role)

    $normalized = ([string]$Role).Trim().ToLowerInvariant() -replace "[\s_-]", ""
    if ($normalized -eq "superadmin" -or $normalized -eq "super") {
        return "superAdmin"
    }
    if ($normalized -eq "admin") {
        return "admin"
    }

    return "employee"
}

function ConvertTo-TimeEntryTypeArray {
    param($Value)

    $result = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($item in @($Value)) {
        $normalized = ([string]$item).Trim().ToLowerInvariant()
        $entryType = ""
        if ($normalized -eq "overtime" -or $normalized -eq "ot") {
            $entryType = "overtime"
        }
        elseif ($normalized -eq "diverse") {
            $entryType = "diverse"
        }

        if (-not [string]::IsNullOrWhiteSpace($entryType) -and -not $seen.ContainsKey($entryType)) {
            [void]$result.Add($entryType)
            $seen[$entryType] = $true
        }
    }

    if ($result.Count -eq 0) {
        [void]$result.Add("overtime")
    }

    return @($result.ToArray())
}

function Get-EmployeeTimeEntryTypesFromUserRecord {
    param($UserRecord)

    if ($null -eq $UserRecord) {
        return @("overtime")
    }

    if ($UserRecord.PSObject.Properties.Name -contains "timeEntryTypes") {
        return @(ConvertTo-TimeEntryTypeArray -Value $UserRecord.timeEntryTypes)
    }

    if ($UserRecord.PSObject.Properties.Name -contains "canPunchDiverse") {
        $diverseFlagValue = $UserRecord.canPunchDiverse
        $diverseFlag = $false
        if ($diverseFlagValue -is [bool]) {
            $diverseFlag = [bool]$diverseFlagValue
        }
        else {
            $normalizedDiverseFlag = ([string]$diverseFlagValue).Trim().ToLowerInvariant()
            $diverseFlag = ($normalizedDiverseFlag -eq "true" -or $normalizedDiverseFlag -eq "1" -or $normalizedDiverseFlag -eq "yes")
        }

        if ($diverseFlag) {
            return @("overtime", "diverse")
        }
    }

    if ($UserRecord.PSObject.Properties.Name -contains "hasDiverse" -and [bool]$UserRecord.hasDiverse) {
        return @("overtime", "diverse")
    }

    return @("overtime")
}

Export-ModuleMember -Function @(
    "Get-NormalizedRoleName",
    "ConvertTo-TimeEntryTypeArray",
    "Get-EmployeeTimeEntryTypesFromUserRecord"
)
