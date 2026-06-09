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
    $diverseCount = 0
    $diverseSeconds = 0
    $projectBuckets = @{}

    foreach ($entry in @($Entries)) {
        $seconds = Get-EmployeeDirectoryEntrySeconds -Entry $entry
        $status = Get-EmployeeDirectoryEntryStatus -Entry $entry
        $entryType = if ($entry.PSObject.Properties.Name -contains "entryType") { ([string]$entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }
        if ($entryType -eq "diverse") {
            $diverseCount++
            $diverseSeconds += $seconds
            if ($status -eq "approved") {
                $approvedCount++
            }
            elseif ($status -eq "rejected") {
                $rejectedCount++
            }
            elseif ($status -eq "live") {
                $liveCount++
            }
            else {
                $pendingCount++
            }
            continue
        }

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

    $projectStatsList = New-Object System.Collections.ArrayList
    foreach ($projectCode in ($projectBuckets.Keys | Sort-Object)) {
        $bucket = $projectBuckets[$projectCode]
        [void]$projectStatsList.Add([PSCustomObject]@{
            projectCode = [string]$bucket.projectCode
            entryCount = [int]$bucket.entryCount
            totalOvertimeSeconds = [int]$bucket.totalOvertimeSeconds
            totalOvertime = Convert-SecondsToTimeText -Seconds ([int]$bucket.totalOvertimeSeconds)
            approvedCount = [int]$bucket.approvedCount
            pendingCount = [int]$bucket.pendingCount
            rejectedCount = [int]$bucket.rejectedCount
            liveCount = [int]$bucket.liveCount
        })
    }

    return [PSCustomObject]@{
        totalOvertimeSeconds = [int]$totalSeconds
        totalOvertime = Convert-SecondsToTimeText -Seconds $totalSeconds
        approvedCount = [int]$approvedCount
        pendingCount = [int]$pendingCount
        rejectedCount = [int]$rejectedCount
        liveCount = [int]$liveCount
        diverseCount = [int]$diverseCount
        diverseSeconds = [int]$diverseSeconds
        diverseDuration = Convert-SecondsToTimeText -Seconds $diverseSeconds
        projectStats = @($projectStatsList.ToArray())
    }
}

function New-EmployeeDirectoryProjectReference {
    param(
        $Project,
        [Parameter(Mandatory = $true)][string]$Responsibility
    )

    $projectCode = if ($null -ne $Project) { ([string]$Project.projectCode).Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($projectCode)) {
        return $null
    }

    $projectName = if ($Project.PSObject.Properties.Name -contains "projectName") { [string]$Project.projectName } else { $projectCode }
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = $projectCode
    }

    $sector = if ($Project.PSObject.Properties.Name -contains "sector") { [string]$Project.sector } else { "" }

    return [PSCustomObject]@{
        projectCode    = $projectCode
        projectName    = $projectName
        sector         = $sector
        responsibility = $Responsibility
        archived       = Test-ProjectArchived -Project $Project
    }
}

function Add-EmployeeDirectoryProjectResponsibility {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Index,
        [string]$EmployeeCode,
        $Project,
        [Parameter(Mandatory = $true)][string]$Responsibility
    )

    $normalizedEmployeeCode = ([string]$EmployeeCode).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedEmployeeCode)) {
        return
    }

    $projectReference = New-EmployeeDirectoryProjectReference -Project $Project -Responsibility $Responsibility
    if ($null -eq $projectReference) {
        return
    }

    if (-not $Index.ContainsKey($normalizedEmployeeCode)) {
        $Index[$normalizedEmployeeCode] = [PSCustomObject]@{
            supervised = @()
            backup     = @()
        }
    }

    $record = $Index[$normalizedEmployeeCode]
    $targetList = if ($Responsibility -eq "backup") { @($record.backup) } else { @($record.supervised) }
    $exists = @($targetList | Where-Object { [string]$_.projectCode -eq [string]$projectReference.projectCode }).Count -gt 0
    if ($exists) {
        return
    }

    if ($Responsibility -eq "backup") {
        $record.backup = @($record.backup) + $projectReference
    }
    else {
        $record.supervised = @($record.supervised) + $projectReference
    }
}

function New-EmployeeDirectoryProjectResponsibilityIndex {
    param($Projects)

    $index = @{}
    foreach ($project in @($Projects)) {
        foreach ($employeeCode in @(Get-ProjectAdminCodes -Project $project)) {
            Add-EmployeeDirectoryProjectResponsibility -Index $index -EmployeeCode $employeeCode -Project $project -Responsibility "supervised"
        }

        foreach ($employeeCode in @(Get-ProjectBackupAdminCodes -Project $project)) {
            Add-EmployeeDirectoryProjectResponsibility -Index $index -EmployeeCode $employeeCode -Project $project -Responsibility "backup"
        }
    }

    return $index
}

function Get-EmployeeDirectoryProjectResponsibilities {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Index,
        [string]$EmployeeCode
    )

    $normalizedEmployeeCode = ([string]$EmployeeCode).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedEmployeeCode) -or -not $Index.ContainsKey($normalizedEmployeeCode)) {
        return [PSCustomObject]@{
            supervised = @()
            backup     = @()
            all        = @()
        }
    }

    $record = $Index[$normalizedEmployeeCode]
    $supervised = @($record.supervised | Sort-Object projectCode)
    $backup = @($record.backup | Sort-Object projectCode)
    $seenProjectCodes = @{}
    $allList = New-Object System.Collections.ArrayList

    foreach ($project in @($supervised + $backup)) {
        $projectCode = ([string]$project.projectCode).Trim()
        if ([string]::IsNullOrWhiteSpace($projectCode) -or $seenProjectCodes.ContainsKey($projectCode)) {
            continue
        }

        $seenProjectCodes[$projectCode] = $true
        [void]$allList.Add($project)
    }

    return [PSCustomObject]@{
        supervised = $supervised
        backup     = $backup
        all        = @($allList.ToArray() | Sort-Object projectCode)
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

    $directoryList = New-Object System.Collections.ArrayList
    $visibleProjectCodeSet = @{}
    $isScopedManager = $false
    $accessModel = $null
    if ($null -ne $CurrentUser -and -not (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) -and (Test-CurrentUserManager -CurrentUser $CurrentUser)) {
        $isScopedManager = $true
        $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
        $visibleProjectCodeSet = $accessModel.ProjectCodeSet
    }
    elseif ($null -ne $CurrentUser) {
        $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    }

    $responsibilityProjects = if ($null -ne $accessModel) { @($accessModel.Projects) } else { @() }
    $responsibilityIndex = New-EmployeeDirectoryProjectResponsibilityIndex -Projects $responsibilityProjects

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
        $responsibilities = Get-EmployeeDirectoryProjectResponsibilities -Index $responsibilityIndex -EmployeeCode $employeeCode
        $hasVisibleResponsibility = (@($responsibilities.supervised).Count + @($responsibilities.backup).Count) -gt 0
        if ($isScopedManager) {
            $entries = @($entries | Where-Object { $visibleProjectCodeSet.ContainsKey([string]$_.projectCode) })
            if ($visibleProjectCodeSet.Count -eq 0 -and $entries.Count -eq 0 -and -not $hasVisibleResponsibility) {
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
        $responsibleProjectCodes = @(
            @($responsibilities.all) |
                ForEach-Object { [string]$_.projectCode } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        [void]$directoryList.Add([PSCustomObject]@{
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
            supervisedProjects   = @($responsibilities.supervised)
            backupProjects       = @($responsibilities.backup)
            responsibleProjects  = @($responsibilities.all)
            responsibleProjectCodes = $responsibleProjectCodes
            timeEntryTypes       = @(Get-EmployeeTimeEntryTypesFromUserRecord -UserRecord $user)
            archived             = $isArchived
            role                 = Get-EffectiveUserRole -UserRecord $user
        })
    }

    return @($directoryList.ToArray())
}

function Add-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$InitialPassword,
        [bool]$MustChangePassword = $true,
        [string]$Role = "employee",
        $TimeEntryTypes = @("overtime")
    )

    $userResult = Ensure-EmployeeUser -EmployeeCode $EmployeeCode -DisplayName $DisplayName -InitialPassword $InitialPassword -MustChangePassword $MustChangePassword -Role $Role -TimeEntryTypes $TimeEntryTypes
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
        [string]$Role,
        $TimeEntryTypes = $null
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
    if ($null -ne $TimeEntryTypes) {
        $userUpdated = (Set-EmployeeUserTimeEntryTypes -EmployeeCode $EmployeeCode -TimeEntryTypes $TimeEntryTypes) -or $userUpdated
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
