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

function Get-EmployeeDirectoryEntrySeconds {
    param($Entry)

    if ($null -eq $Entry) {
        return 0
    }

    return (Get-OvertimeSecondsFromText -Value ([string]$Entry.overtime))
}

function Get-EmployeeDirectoryEntryStatus {
    param($Entry)

    if (Test-EntryOpen -Entry $Entry) {
        return "live"
    }

    $status = ([string]$Entry.status).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($status)) {
        return "pending"
    }

    return $status
}

function Get-EmployeeDirectoryStats {
    param($Entries)

    $totalSeconds = 0
    $approvedCount = 0
    $pendingCount = 0
    $rejectedCount = 0
    $liveCount = 0
    $projectBuckets = @{}

    foreach ($entry in @($Entries)) {
        $seconds = Get-EmployeeDirectoryEntrySeconds -Entry $entry
        $status = Get-EmployeeDirectoryEntryStatus -Entry $entry
        $projectCode = ([string]$entry.projectCode).Trim()
        if ([string]::IsNullOrWhiteSpace($projectCode)) {
            $projectCode = "__NO_PROJECT__"
        }

        if (-not $projectBuckets.ContainsKey($projectCode)) {
            $projectBuckets[$projectCode] = [PSCustomObject]@{
                projectCode = $projectCode
                entryCount = 0
                totalOvertimeSeconds = 0
                approvedCount = 0
                pendingCount = 0
                rejectedCount = 0
                liveCount = 0
            }
        }

        $bucket = $projectBuckets[$projectCode]
        $bucket.entryCount = [int]$bucket.entryCount + 1
        $bucket.totalOvertimeSeconds = [int]$bucket.totalOvertimeSeconds + [int]$seconds
        $totalSeconds += $seconds

        if ($status -eq "approved") {
            $approvedCount++
            $bucket.approvedCount = [int]$bucket.approvedCount + 1
        }
        elseif ($status -eq "rejected") {
            $rejectedCount++
            $bucket.rejectedCount = [int]$bucket.rejectedCount + 1
        }
        elseif ($status -eq "live") {
            $liveCount++
            $bucket.liveCount = [int]$bucket.liveCount + 1
        }
        else {
            $pendingCount++
            $bucket.pendingCount = [int]$bucket.pendingCount + 1
        }
    }

    $projectStats = @()
    foreach ($projectCode in ($projectBuckets.Keys | Sort-Object)) {
        $bucket = $projectBuckets[$projectCode]
        $projectStats += [PSCustomObject]@{
            projectCode = [string]$bucket.projectCode
            entryCount = [int]$bucket.entryCount
            totalOvertimeSeconds = [int]$bucket.totalOvertimeSeconds
            totalOvertime = Convert-SecondsToTimeText -Seconds ([int]$bucket.totalOvertimeSeconds)
            approvedCount = [int]$bucket.approvedCount
            pendingCount = [int]$bucket.pendingCount
            rejectedCount = [int]$bucket.rejectedCount
            liveCount = [int]$bucket.liveCount
        }
    }

    return [PSCustomObject]@{
        totalOvertimeSeconds = [int]$totalSeconds
        totalOvertime = Convert-SecondsToTimeText -Seconds $totalSeconds
        approvedCount = [int]$approvedCount
        pendingCount = [int]$pendingCount
        rejectedCount = [int]$rejectedCount
        liveCount = [int]$liveCount
        projectStats = $projectStats
    }
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
    param(
        [bool]$IncludeDisabled = $false,
        $CurrentUser
    )

    $directory = @()
    $visibleProjectCodes = @()
    $isScopedManager = $false
    if ($null -ne $CurrentUser -and -not (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) -and (Test-CurrentUserManager -CurrentUser $CurrentUser)) {
        $isScopedManager = $true
        $visibleProjectCodes = @(Get-ProjectCodesForCurrentUser -CurrentUser $CurrentUser)
    }

    $users = @(Get-Users | Where-Object { Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode "" })
    foreach ($user in ($users | Sort-Object username)) {
        $isArchived = [bool]$user.disabled
        if ($isArchived -and -not $IncludeDisabled) {
            continue
        }

        $employeeCode = Get-UserEmployeeCodeValue -UserRecord $user
        $displayName = if ($user.displayName) { [string]$user.displayName } else { [string](Get-EmployeeName $employeeCode) }
        $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode
        $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)
        if ($isScopedManager) {
            $entries = @($entries | Where-Object { $visibleProjectCodes -contains [string]$_.projectCode })
            if ($entries.Count -eq 0) {
                continue
            }
        }
        $entryCount = $entries.Count
        $projectCodes = @(
            $entries |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.projectCode) } |
                ForEach-Object { [string]$_.projectCode } |
                Sort-Object -Unique
        )
        $entryStats = Get-EmployeeDirectoryStats -Entries $entries

        $directory += [PSCustomObject]@{
            code                 = $employeeCode
            name                 = $displayName
            entryCount           = $entryCount
            totalOvertimeSeconds = [int]$entryStats.totalOvertimeSeconds
            totalOvertime        = [string]$entryStats.totalOvertime
            approvedCount        = [int]$entryStats.approvedCount
            pendingCount         = [int]$entryStats.pendingCount
            rejectedCount        = [int]$entryStats.rejectedCount
            liveCount            = [int]$entryStats.liveCount
            projectCodes         = $projectCodes
            projectStats         = @($entryStats.projectStats)
            archived             = $isArchived
            role                 = Get-EffectiveUserRole -UserRecord $user
        }
    }

    return @($directory)
}

function Add-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$InitialPassword,
        [bool]$MustChangePassword = $true,
        [string]$Role = "employee"
    )

    $userResult = Ensure-EmployeeUser -EmployeeCode $EmployeeCode -DisplayName $DisplayName -InitialPassword $InitialPassword -MustChangePassword $MustChangePassword -Role $Role
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
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$Role
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
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        $userUpdated = (Set-EmployeeUserRole -EmployeeCode $EmployeeCode -Role $Role) -or $userUpdated
    }
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

function Restore-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $updated = Restore-EmployeeUser -EmployeeCode $EmployeeCode
    if ($updated) {
        Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode | Out-Null
    }

    return [PSCustomObject]@{
        updated = $updated
        error   = $null
    }
}
