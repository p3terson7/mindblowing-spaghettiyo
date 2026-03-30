function ConvertTo-EmployeeNameDictionary {
    param($NameMap)

    $dictionary = @{}
    if ($null -eq $NameMap) {
        return $dictionary
    }

    foreach ($property in $NameMap.PSObject.Properties) {
        $dictionary[[string]$property.Name] = [string]$property.Value
    }

    return $dictionary
}

function Write-EmployeeNameDictionary {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EmployeeNames
    )

    $ordered = [ordered]@{}
    foreach ($code in ($EmployeeNames.Keys | Sort-Object)) {
        $ordered[$code] = [string]$EmployeeNames[$code]
    }

    Write-JsonAtomic -Path $mappingFile -Value ([PSCustomObject]$ordered) -Depth 6
}

function Get-EmployeeDataFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    return (Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode))
}

function Ensure-EmployeeDataFile {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $dataFile = Get-EmployeeDataFilePath -EmployeeCode $EmployeeCode
    if (!(Test-Path -Path $dataFile)) {
        Write-JsonAtomic -Path $dataFile -Value @()
    }

    return $dataFile
}

function Update-EmployeeEntryDisplayName {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $dataFile = Get-EmployeeDataFilePath -EmployeeCode $EmployeeCode
    if (!(Test-Path -Path $dataFile)) {
        return 0
    }

    $updatedCount = 0
    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
    try {
        $entries = Read-JsonArrayFile -Path $dataFile
        foreach ($entry in $entries) {
            if ([string]$entry.name -ne $DisplayName) {
                $entry.name = [string]$DisplayName
                $updatedCount++
            }
        }

        if ($updatedCount -gt 0) {
            Write-JsonAtomic -Path $dataFile -Value $entries -Depth 6
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updatedCount
}

function Get-EmployeeDirectoryList {
    $employees = @()
    $users = @(Get-Users | Where-Object { [string]$_.role -eq "employee" -and -not [bool]$_.disabled } | Sort-Object username)

    foreach ($user in $users) {
        $employeeCode = if ($user.employeeCode) { [string]$user.employeeCode } else { [string]$user.username }
        $displayName = if ($user.displayName) { [string]$user.displayName } else { [string](Get-EmployeeName $employeeCode) }
        $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode
        $entryCount = 0
        if (Test-Path -Path $dataFile) {
            $entryCount = @(Read-JsonArrayFile -Path $dataFile).Count
        }

        $employees += [PSCustomObject]@{
            code       = $employeeCode
            name       = $displayName
            entryCount = $entryCount
        }
    }

    return $employees
}

function Add-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$InitialPassword,
        [bool]$MustChangePassword = $true
    )

    $userResult = Ensure-EmployeeUser -EmployeeCode $EmployeeCode -DisplayName $DisplayName -InitialPassword $InitialPassword -MustChangePassword $MustChangePassword
    if (-not $userResult.updated) {
        return $userResult
    }

    $mappingLock = Acquire-ResourceLock -ResourcePath $mappingFile
    try {
        $employeeNames = ConvertTo-EmployeeNameDictionary -NameMap (Get-EmployeeNameMap)
        $employeeNames[$EmployeeCode] = [string]$DisplayName
        Write-EmployeeNameDictionary -EmployeeNames $employeeNames
    }
    finally {
        Release-ResourceLock -LockHandle $mappingLock
    }

    Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode | Out-Null
    Update-EmployeeEntryDisplayName -EmployeeCode $EmployeeCode -DisplayName $DisplayName | Out-Null
    return $userResult
}

function Update-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $mappingLock = Acquire-ResourceLock -ResourcePath $mappingFile
    try {
        $employeeNames = ConvertTo-EmployeeNameDictionary -NameMap (Get-EmployeeNameMap)
        $employeeNames[$EmployeeCode] = [string]$DisplayName
        Write-EmployeeNameDictionary -EmployeeNames $employeeNames
    }
    finally {
        Release-ResourceLock -LockHandle $mappingLock
    }

    $userUpdated = Set-EmployeeUserDisplayName -EmployeeCode $EmployeeCode -DisplayName $DisplayName
    Update-EmployeeEntryDisplayName -EmployeeCode $EmployeeCode -DisplayName $DisplayName | Out-Null

    return [PSCustomObject]@{
        updated = $userUpdated
        error   = $null
    }
}

function Remove-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $updated = Disable-EmployeeUser -EmployeeCode $EmployeeCode
    if ($updated) {
        Revoke-SessionsForUsername -Username $EmployeeCode
    }

    return [PSCustomObject]@{
        updated = $updated
        error   = $null
    }
}
