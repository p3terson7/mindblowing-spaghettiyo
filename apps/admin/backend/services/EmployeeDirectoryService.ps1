function ConvertTo-EmployeeNameDictionary {
    param($NameMap)

    $dictionary = @{}
    if ($null -eq $NameMap) {
        return $dictionary
    }

    if ($NameMap -is [hashtable]) {
        foreach ($key in $NameMap.Keys) {
            $dictionary[[string]$key] = [string]$NameMap[$key]
        }
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
    $script:EmployeeNameMapCache = $null
}

function Set-EmployeeDirectoryNameMapping {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $mappingLock = Acquire-ResourceLock -ResourcePath $mappingFile
    try {
        $employeeNames = ConvertTo-EmployeeNameDictionary -NameMap (Read-EmployeeNameMapFromDisk)
        $employeeNames[$EmployeeCode] = [string]$DisplayName
        Write-EmployeeNameDictionary -EmployeeNames $employeeNames
    }
    finally {
        Release-ResourceLock -LockHandle $mappingLock
    }
}

function Invoke-EmployeeDirectorySecondaryActionSafely {
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

function Get-EmployeeDataFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $normalizedEmployeeCode = $EmployeeCode.Trim()
    if ($normalizedEmployeeCode -notmatch "^\d+$") {
        throw [System.ArgumentException]::new("Employee code must contain digits only.", "EmployeeCode")
    }

    return (Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $normalizedEmployeeCode))
}

function Ensure-EmployeeDataFile {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $dataFile = Get-EmployeeDataFilePath -EmployeeCode $EmployeeCode

    # Existing employee files are the overwhelmingly common case. A read-only
    # request must not create and delete a shared .lock file merely to confirm
    # that the data file is already present.
    if ([System.IO.File]::Exists($dataFile)) {
        return $dataFile
    }

    # Creation remains serialized and repeats the existence check after the
    # lock is acquired so concurrent first access cannot race.
    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
    try {
        if (-not [System.IO.File]::Exists($dataFile)) {
            Write-JsonArrayAtomic -Path $dataFile -Items @()
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
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
        $entries = @(Read-JsonArrayFile -Path $dataFile)
        foreach ($entry in $entries) {
            if ([string]$entry.name -ne $DisplayName) {
                $entry.name = [string]$DisplayName
                $updatedCount++
            }
        }

        if ($updatedCount -gt 0) {
            Write-JsonArrayAtomic -Path $dataFile -Items $entries -Depth 6
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updatedCount
}

function Get-EmployeeDirectoryListUncached {
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
            gc179Profile         = Get-Gc179ProfileFromUserRecord -UserRecord $user
            archived             = $isArchived
            role                 = Get-EffectiveUserRole -UserRecord $user
        })
    }

    return @($directoryList.ToArray())
}

function Get-EmployeeDirectoryList {
    param(
        [bool]$IncludeDisabled = $false,
        $CurrentUser
    )

    $userScopeKey = if ($null -ne $CurrentUser -and (Get-Command -Name Get-ProjectAccessCacheUserKey -ErrorAction SilentlyContinue)) {
        Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    }
    elseif ($null -ne $CurrentUser -and $CurrentUser.PSObject.Properties.Name -contains "username") {
        [string]$CurrentUser.username
    }
    else {
        "anonymous"
    }

    $cacheKey = "employee-directory-list|{0}|{1}" -f [bool]$IncludeDisabled, $userScopeKey
    if (Get-Command -Name Invoke-ReadModelCache -ErrorAction SilentlyContinue) {
        return (Invoke-ReadModelCache -Key $cacheKey -Factory {
            Get-EmployeeDirectoryListUncached -IncludeDisabled:$IncludeDisabled -CurrentUser $CurrentUser
        })
    }

    return (Get-EmployeeDirectoryListUncached -IncludeDisabled:$IncludeDisabled -CurrentUser $CurrentUser)
}

function Get-EmployeeDirectoryRecordMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [bool]$IncludeDisabled = $false
    )

    $normalizedEmployeeCode = $EmployeeCode.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedEmployeeCode)) {
        return $null
    }

    $user = Get-EmployeeUserByCode -EmployeeCode $normalizedEmployeeCode
    if ($null -eq $user -or -not (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $normalizedEmployeeCode)) {
        return $null
    }

    $isArchived = [bool]$user.disabled
    if ($isArchived -and -not $IncludeDisabled) {
        return $null
    }

    $displayName = if ($user.displayName) {
        [string]$user.displayName
    }
    else {
        [string](Get-EmployeeName $normalizedEmployeeCode)
    }

    return [PSCustomObject]@{
        code     = $normalizedEmployeeCode
        name     = $displayName
        archived = $isArchived
    }
}

function Add-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$InitialPassword,
        [bool]$MustChangePassword = $true,
        [string]$Role = "employee",
        $TimeEntryTypes = @("overtime"),
        $Gc179Profile = $null
    )

    $userResult = Ensure-EmployeeUser -EmployeeCode $EmployeeCode -DisplayName $DisplayName -InitialPassword $InitialPassword -MustChangePassword $MustChangePassword -Role $Role -TimeEntryTypes $TimeEntryTypes -Gc179Profile $Gc179Profile
    if (-not $userResult.updated) {
        return $userResult
    }

    # users.json is the canonical employee-directory record. Everything below
    # is repairable derived/secondary state and must not make a committed
    # account creation look like a failed request.
    $warnings = New-Object System.Collections.ArrayList
    $mappingWarning = Invoke-EmployeeDirectorySecondaryActionSafely -Description "Employee account saved, but the employee-name mapping could not be updated" -Action {
        Set-EmployeeDirectoryNameMapping -EmployeeCode $EmployeeCode -DisplayName $DisplayName
    }
    if (-not [string]::IsNullOrWhiteSpace($mappingWarning)) {
        [void]$warnings.Add($mappingWarning)
    }

    $dataFileWarning = Invoke-EmployeeDirectorySecondaryActionSafely -Description "Employee account saved, but the employee data file could not be initialized" -Action {
        Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($dataFileWarning)) {
        [void]$warnings.Add($dataFileWarning)
    }

    $entryNameWarning = Invoke-EmployeeDirectorySecondaryActionSafely -Description "Employee account saved, but existing entry names could not be updated" -Action {
        Update-EmployeeEntryDisplayName -EmployeeCode $EmployeeCode -DisplayName $DisplayName | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($entryNameWarning)) {
        [void]$warnings.Add($entryNameWarning)
    }

    return [PSCustomObject]@{
        updated           = [bool]$userResult.updated
        created           = [bool]$userResult.created
        reactivated       = [bool]$userResult.reactivated
        error             = $userResult.error
        temporaryPassword = [string]$userResult.temporaryPassword
        warnings          = @($warnings.ToArray())
    }
}

function Update-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$Role,
        $TimeEntryTypes = $null,
        $Gc179Profile = $null
    )

    $profileUpdateParameters = @{
        EmployeeCode = $EmployeeCode
        DisplayName  = $DisplayName
    }
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        $profileUpdateParameters["Role"] = $Role
    }
    if ($null -ne $TimeEntryTypes) {
        $profileUpdateParameters["TimeEntryTypes"] = $TimeEntryTypes
    }
    if ($null -ne $Gc179Profile) {
        $profileUpdateParameters["Gc179Profile"] = $Gc179Profile
    }
    $userUpdated = Set-EmployeeUserProfile @profileUpdateParameters
    if (-not $userUpdated) {
        return [PSCustomObject]@{
            updated  = $false
            error    = "Employee account was not found."
            warnings = @()
        }
    }

    $warnings = New-Object System.Collections.ArrayList
    $mappingWarning = Invoke-EmployeeDirectorySecondaryActionSafely -Description "Employee profile saved, but the employee-name mapping could not be updated" -Action {
        Set-EmployeeDirectoryNameMapping -EmployeeCode $EmployeeCode -DisplayName $DisplayName
    }
    if (-not [string]::IsNullOrWhiteSpace($mappingWarning)) {
        [void]$warnings.Add($mappingWarning)
    }

    $entryNameWarning = Invoke-EmployeeDirectorySecondaryActionSafely -Description "Employee profile saved, but existing entry names could not be updated" -Action {
        Update-EmployeeEntryDisplayName -EmployeeCode $EmployeeCode -DisplayName $DisplayName | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($entryNameWarning)) {
        [void]$warnings.Add($entryNameWarning)
    }

    return [PSCustomObject]@{
        updated  = $true
        error    = $null
        warnings = @($warnings.ToArray())
    }
}

function Remove-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $updated = Disable-EmployeeUser -EmployeeCode $EmployeeCode
    $warnings = New-Object System.Collections.ArrayList
    if ($updated) {
        $sessionWarning = Invoke-EmployeeDirectorySecondaryActionSafely -Description "Employee access was disabled, but existing sessions could not be revoked" -Action {
            Revoke-SessionsForUsername -Username $EmployeeCode
        }
        if (-not [string]::IsNullOrWhiteSpace($sessionWarning)) {
            [void]$warnings.Add($sessionWarning)
        }
    }

    return [PSCustomObject]@{
        updated  = $updated
        error    = $null
        warnings = @($warnings.ToArray())
    }
}

function Restore-EmployeeDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $updated = Restore-EmployeeUser -EmployeeCode $EmployeeCode
    $warnings = New-Object System.Collections.ArrayList
    if ($updated) {
        $dataFileWarning = Invoke-EmployeeDirectorySecondaryActionSafely -Description "Employee access was restored, but the employee data file could not be initialized" -Action {
            Ensure-EmployeeDataFile -EmployeeCode $EmployeeCode | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($dataFileWarning)) {
            [void]$warnings.Add($dataFileWarning)
        }
    }

    return [PSCustomObject]@{
        updated  = $updated
        error    = $null
        warnings = @($warnings.ToArray())
    }
}
