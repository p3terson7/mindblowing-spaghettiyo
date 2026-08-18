$entryStateModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.EntryState.psd1"
if ($null -eq (Get-Module -Name "Saphir.EntryState")) {
    Import-Module -Name $entryStateModuleManifest -ErrorAction Stop | Out-Null
}
Remove-Variable -Name entryStateModuleManifest -ErrorAction SilentlyContinue

if (-not $script:ReadModelCache) {
    $script:ReadModelCache = @{}
}

if (-not $script:ReadModelCacheVersion) {
    $script:ReadModelCacheVersion = $null
}

if (-not $script:EmployeeEntryFileCache) {
    $script:EmployeeEntryFileCache = @{}
}

if (-not $script:ReadModelSyncState) {
    $script:ReadModelSyncState = $null
}

if ($null -eq $script:ReadModelFactoryDepth) {
    $script:ReadModelFactoryDepth = 0
}

function Get-ReadModelSyncStateKey {
    param($State)

    if ($null -eq $State) {
        return "0"
    }

    if ($State.PSObject.Properties.Name -contains "changeId" -and -not [string]::IsNullOrWhiteSpace([string]$State.changeId)) {
        return [string]$State.changeId
    }

    return ("{0}|{1}|{2}|{3}" -f [string]$State.version, [string]$State.updatedAtUtc, [string]$State.category, [string]$State.resource)
}

function Test-ReadModelGuidValue {
    param($Value)

    $parsedGuid = [Guid]::Empty
    return (-not [string]::IsNullOrWhiteSpace([string]$Value) -and
        [Guid]::TryParse([string]$Value, [ref]$parsedGuid) -and
        $parsedGuid -ne [Guid]::Empty)
}

function Test-ReadModelEmployeeCode {
    param($Value)

    return (-not [string]::IsNullOrWhiteSpace([string]$Value) -and
        ([string]$Value).Trim() -match "^\d+$")
}

function Test-ReadModelSyncStateRevisionSchema {
    param($State)

    if ($null -eq $State) {
        return $false
    }

    $propertyNames = @($State.PSObject.Properties.Name)
    if (-not ($propertyNames -contains "changeId") -or
        -not ($propertyNames -contains "employeeDataEpoch") -or
        -not ($propertyNames -contains "employeeDataRevisions") -or
        -not (Test-ReadModelGuidValue -Value $State.changeId) -or
        -not (Test-ReadModelGuidValue -Value $State.employeeDataEpoch)) {
        return $false
    }

    $revisions = $State.employeeDataRevisions
    if ($null -eq $revisions -or
        -not (($revisions -is [System.Collections.IDictionary]) -or
        ($revisions.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject"))) {
        return $false
    }

    $revisionMap = ConvertTo-ReadModelEmployeeRevisionMap -Value $revisions
    foreach ($employeeCode in @($revisionMap.Keys)) {
        if (-not (Test-ReadModelEmployeeCode -Value $employeeCode) -or
            -not (Test-ReadModelGuidValue -Value $revisionMap[$employeeCode])) {
            return $false
        }
    }

    return $true
}

function ConvertTo-ReadModelEmployeeRevisionMap {
    param($Value)

    $result = @{}
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $result[[string]$key] = [string]$Value[$key]
        }
        return $result
    }

    if ($null -ne $Value -and ($Value.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject")) {
        foreach ($property in @($Value.PSObject.Properties)) {
            $result[[string]$property.Name] = [string]$property.Value
        }
    }

    return $result
}

function Test-ReadModelCurrentStateSupportsTargeting {
    param($State)

    if (-not (Test-ReadModelSyncStateRevisionSchema -State $State)) {
        return $false
    }

    $category = ([string]$State.category).Trim().ToLowerInvariant()
    if (@("history", "project", "auth") -contains $category) {
        return $true
    }

    if (@("employee", "employee-directory") -notcontains $category) {
        return $false
    }

    $resource = ([string]$State.resource).Trim()
    $changeId = [string]$State.changeId
    $revisionMap = ConvertTo-ReadModelEmployeeRevisionMap -Value $State.employeeDataRevisions
    if ($resource -eq "*") {
        foreach ($revision in @($revisionMap.Values)) {
            if ([string]$revision -eq $changeId) {
                return $true
            }
        }
        return $false
    }

    return ((Test-ReadModelEmployeeCode -Value $resource) -and
        $revisionMap.ContainsKey($resource) -and
        [string]$revisionMap[$resource] -eq $changeId)
}

function Clear-EmployeeEntryCacheForCode {
    param([Parameter(Mandatory = $true)][string]$EmployeeCode)

    $normalizedCode = $EmployeeCode.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedCode) -or
        $normalizedCode -eq "*" -or
        -not (Test-ReadModelEmployeeCode -Value $normalizedCode) -or
        [System.IO.Path]::GetFileName($normalizedCode) -ne $normalizedCode) {
        return $false
    }

    $dataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $normalizedCode)
    Clear-CachedFileContent -Path $dataFile
    if ($script:EmployeeEntryFileCache.ContainsKey($dataFile)) {
        $script:EmployeeEntryFileCache.Remove($dataFile) | Out-Null
    }
    return $true
}

function Clear-AllEmployeeEntryCaches {
    $employeeDataPaths = @{}
    foreach ($path in @($script:EmployeeEntryFileCache.Keys)) {
        $employeeDataPaths[[string]$path] = $true
    }

    foreach ($cacheName in @("TextFileCache", "BinaryFileCache", "FileMetadataCache")) {
        $cacheVariable = Get-Variable -Name $cacheName -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $cacheVariable -or $null -eq $cacheVariable.Value) {
            continue
        }

        foreach ($path in @($cacheVariable.Value.Keys)) {
            if ([System.IO.Path]::GetFileName([string]$path) -like "*_data.json") {
                $employeeDataPaths[[string]$path] = $true
            }
        }
    }

    foreach ($path in @($employeeDataPaths.Keys)) {
        Clear-CachedFileContent -Path ([string]$path)
    }
    $script:EmployeeEntryFileCache = @{}
}

function Clear-ReadModelFileCache {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace([string]$Path)) {
        Clear-CachedFileContent -Path ([string]$Path)
    }
}

function Clear-AllReadModelCoreFileCaches {
    foreach ($corePath in @(
        $projectsFile,
        $mappingFile,
        $usersFile,
        $sessionsFile,
        $historyFile,
        $overtimeCodesFile,
        $paymentOptionsFile,
        $reasonCodesFile
    )) {
        Clear-ReadModelFileCache -Path ([string]$corePath)
    }

    $script:ProjectsCache = $null
    $script:EmployeeNameMapCache = $null
    $script:JsonOptionArrayCache = @{}
    if (Get-Command -Name Clear-AuthRuntimeCaches -ErrorAction SilentlyContinue) {
        Clear-AuthRuntimeCaches
    }
}

function Clear-ReadModelCoreCachesForChange {
    param(
        [string]$Category,
        [bool]$CanUseTargetedInvalidation
    )

    if (-not $CanUseTargetedInvalidation) {
        Clear-AllReadModelCoreFileCaches
        return
    }

    switch (([string]$Category).Trim().ToLowerInvariant()) {
        "history" {
            Clear-ReadModelFileCache -Path $historyFile
        }
        "employee" {
            # Entry mutations normally append audit history before publishing
            # their single employee revision. Some employee changes do not add
            # history, but clearing one small core cache is safer than retaining
            # an audit projection after a coalesced mutation.
            Clear-ReadModelFileCache -Path $historyFile
        }
        "project" {
            Clear-ReadModelFileCache -Path $projectsFile
            Clear-ReadModelFileCache -Path $historyFile
            $script:ProjectsCache = $null
            if (Get-Command -Name Clear-ProjectAccessRuntimeCaches -ErrorAction SilentlyContinue) {
                Clear-ProjectAccessRuntimeCaches
            }
            elseif (Get-Command -Name Clear-AuthRuntimeCaches -ErrorAction SilentlyContinue) {
                Clear-AuthRuntimeCaches
            }
        }
        "auth" {
            Clear-ReadModelFileCache -Path $usersFile
            Clear-ReadModelFileCache -Path $sessionsFile
            Clear-ReadModelFileCache -Path $historyFile
            if (Get-Command -Name Clear-AuthRuntimeCaches -ErrorAction SilentlyContinue) {
                Clear-AuthRuntimeCaches
            }
        }
        "employee-directory" {
            Clear-ReadModelFileCache -Path $usersFile
            Clear-ReadModelFileCache -Path $sessionsFile
            Clear-ReadModelFileCache -Path $mappingFile
            Clear-ReadModelFileCache -Path $historyFile
            $script:EmployeeNameMapCache = $null
            if (Get-Command -Name Clear-AuthRuntimeCaches -ErrorAction SilentlyContinue) {
                Clear-AuthRuntimeCaches
            }
        }
        default {
            Clear-AllReadModelCoreFileCaches
        }
    }
}

function Sync-ReadModelCaches {
    $state = Get-SyncState
    $stateKey = Get-ReadModelSyncStateKey -State $state
    if ($script:ReadModelCacheVersion -eq $stateKey) {
        return
    }

    $previousState = $script:ReadModelSyncState
    $script:ReadModelCache = @{}
    $previousVersion = -1
    $currentVersion = -1
    $hasPreviousVersion = $null -ne $previousState -and
        ($previousState.PSObject.Properties.Name -contains "version") -and
        [int]::TryParse([string]$previousState.version, [ref]$previousVersion)
    $hasCurrentVersion = $null -ne $state -and
        ($state.PSObject.Properties.Name -contains "version") -and
        [int]::TryParse([string]$state.version, [ref]$currentVersion)
    $isSequentialChange = $hasPreviousVersion -and
        $hasCurrentVersion -and
        $currentVersion -eq ($previousVersion + 1)

    $canTargetEmployeeCaches = (Test-ReadModelSyncStateRevisionSchema -State $previousState) -and
        (Test-ReadModelSyncStateRevisionSchema -State $state) -and
        (Test-ReadModelCurrentStateSupportsTargeting -State $state) -and
        ([string]$previousState.employeeDataEpoch -eq [string]$state.employeeDataEpoch)

    if (-not $canTargetEmployeeCaches) {
        Clear-AllEmployeeEntryCaches
    }
    else {
        $previousRevisions = ConvertTo-ReadModelEmployeeRevisionMap -Value $previousState.employeeDataRevisions
        $currentRevisions = ConvertTo-ReadModelEmployeeRevisionMap -Value $state.employeeDataRevisions
        $revisionCodes = @{}
        foreach ($employeeCode in @($previousRevisions.Keys)) {
            $revisionCodes[[string]$employeeCode] = $true
        }
        foreach ($employeeCode in @($currentRevisions.Keys)) {
            $revisionCodes[[string]$employeeCode] = $true
        }

        foreach ($employeeCode in @($revisionCodes.Keys)) {
            $previousRevision = if ($previousRevisions.ContainsKey($employeeCode)) { [string]$previousRevisions[$employeeCode] } else { "" }
            $currentRevision = if ($currentRevisions.ContainsKey($employeeCode)) { [string]$currentRevisions[$employeeCode] } else { "" }
            if ($previousRevision -ne $currentRevision) {
                if (-not (Clear-EmployeeEntryCacheForCode -EmployeeCode ([string]$employeeCode))) {
                    Clear-AllEmployeeEntryCaches
                    break
                }
            }
        }
    }

    Clear-ReadModelCoreCachesForChange `
        -Category ([string]$state.category) `
        -CanUseTargetedInvalidation:$isSequentialChange
    $script:ReadModelSyncState = $state
    $script:ReadModelCacheVersion = $stateKey
}

function Invoke-ReadModelCache {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][scriptblock]$Factory
    )

    if ($script:ReadModelFactoryDepth -le 0) {
        Sync-ReadModelCaches
    }

    if ($script:ReadModelCache.ContainsKey($Key)) {
        return $script:ReadModelCache[$Key]
    }

    $script:ReadModelFactoryDepth++
    try {
        $value = & $Factory
    }
    finally {
        $script:ReadModelFactoryDepth--
    }
    $script:ReadModelCache[$Key] = $value
    return $value
}

function Convert-SecondsToTimeText {
    param([double]$Seconds)

    $safeSeconds = [math]::Max(0, [int][math]::Round([double]$Seconds))
    $hours = [math]::Floor($safeSeconds / 3600)
    $minutes = [math]::Floor(($safeSeconds % 3600) / 60)
    $remainingSeconds = $safeSeconds % 60
    return ("{0:00}:{1:00}:{2:00}" -f $hours, $minutes, $remainingSeconds)
}

function Get-OvertimeSecondsFromText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or [string]$Value -eq "N/A") {
        return 0
    }

    try {
        return [int][math]::Round(([TimeSpan]::Parse([string]$Value)).TotalSeconds)
    }
    catch {
        return 0
    }
}

function Get-EntryDateOrNull {
    param($Entry)

    try {
        return [DateTime]::ParseExact([string]$Entry.date, "yyyy-MM-dd", $null)
    }
    catch {
        return $null
    }
}

function Get-EntryDateTimeOrMin {
    param($Entry)

    try {
        return [DateTime]::ParseExact(("{0} {1}" -f [string]$Entry.date, [string]$Entry.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Test-EntryOpen {
    param($Entry)

    return (Saphir.EntryState\Test-EntryOpen -Entry $Entry)
}

function New-EmployeeEntryProjection {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [Parameter(Mandatory = $true)]$Entry,
        [string]$EmployeeRole = "employee"
    )

    $entryType = if ($Entry.PSObject.Properties.Name -contains "entryType" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.entryType)) { ([string]$Entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }

    return [PSCustomObject]@{
        entryId       = Get-EntryIdentifierValue -Entry $Entry
        entryType     = $entryType
        name          = [string]$Entry.name
        date          = [string]$Entry.date
        punchIn       = [string]$Entry.punchIn
        exactPunchIn  = Get-EntryExactPunchInText -Entry $Entry
        punchOut      = if ($null -ne $Entry.punchOut) { [string]$Entry.punchOut } else { $null }
        exactPunchOut = Get-EntryExactPunchOutText -Entry $Entry
        overtime      = if ($null -ne $Entry.overtime) { [string]$Entry.overtime } else { $null }
        status        = if ($null -ne $Entry.status) { [string]$Entry.status } else { "pending" }
        message       = if ($null -ne $Entry.message) { [string]$Entry.message } else { "" }
        projectCode   = if ($null -ne $Entry.projectCode) { [string]$Entry.projectCode } else { "" }
        overtimeCode  = if ($null -ne $Entry.overtimeCode) { [string]$Entry.overtimeCode } else { "" }
        paymentOption = if ($null -ne $Entry.paymentOption -and -not [string]::IsNullOrWhiteSpace([string]$Entry.paymentOption)) { [string]$Entry.paymentOption } elseif ($entryType -eq "diverse") { "" } else { "cash" }
        reasonCode    = if ($null -ne $Entry.reasonCode) { [string]$Entry.reasonCode } else { "" }
        workComment   = if ($Entry.PSObject.Properties.Name -contains "workComment") { [string]$Entry.workComment } else { "" }
        diverseReason = if ($Entry.PSObject.Properties.Name -contains "diverseReason") { [string]$Entry.diverseReason } else { "" }
        diverseSummary = if ($Entry.PSObject.Properties.Name -contains "diverseSummary") { [string]$Entry.diverseSummary } else { "" }
        forgottenClockOut = Test-EntryForgottenClockOut -Entry $Entry
        needsClockOutReview = Test-EntryForgottenClockOut -Entry $Entry
        forgottenClockOutAttemptedDate = if ($Entry.PSObject.Properties.Name -contains "forgottenClockOutAttemptedDate") { [string]$Entry.forgottenClockOutAttemptedDate } else { "" }
        forgottenClockOutAttemptedTime = if ($Entry.PSObject.Properties.Name -contains "forgottenClockOutAttemptedTime") { [string]$Entry.forgottenClockOutAttemptedTime } else { "" }
        forgottenClockOutDetectedAtUtc = if ($Entry.PSObject.Properties.Name -contains "forgottenClockOutDetectedAtUtc") { [string]$Entry.forgottenClockOutDetectedAtUtc } else { "" }
        employeeCode  = $EmployeeCode
        employeeName  = $EmployeeName
        employeeRole  = Get-NormalizedRoleName -Role $EmployeeRole
    }
}

function Add-EntryPermissionProjection {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        $CurrentUser,
        [string]$EmployeeRole = "employee"
    )

    $canModify = Test-CurrentUserCanManageEntry -CurrentUser $CurrentUser -Entry $Entry
    $canApproveEmployeeRole = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $EmployeeRole
    $canApprove = ($canModify -and $canApproveEmployeeRole)
    $permissionReason = "editable"

    if (-not $canModify) {
        $permissionReason = "readOnlyProject"
    }
    elseif (-not $canApproveEmployeeRole) {
        $permissionReason = "superAdminApproval"
    }

    $Entry | Add-Member -NotePropertyName canModify -NotePropertyValue ([bool]$canModify) -Force
    $Entry | Add-Member -NotePropertyName canApprove -NotePropertyValue ([bool]$canApprove) -Force
    $Entry | Add-Member -NotePropertyName permissionReason -NotePropertyValue $permissionReason -Force
    return $Entry
}

function Add-EntryPermissionProjectionFromAccessModel {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$ModifyProjectCodeSet,
        [bool]$IsSuperAdmin = $false,
        [bool]$CanApproveEmployeeRole = $true
    )

    $entryType = if ($Entry.PSObject.Properties.Name -contains "entryType") { ([string]$Entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }
    $projectCode = if ($Entry.PSObject.Properties.Name -contains "projectCode") { [string]$Entry.projectCode } else { "" }
    $canModify = $false

    if ($IsSuperAdmin) {
        $canModify = $true
    }
    elseif ($entryType -ne "diverse" -and -not [string]::IsNullOrWhiteSpace($projectCode)) {
        $canModify = $ModifyProjectCodeSet.ContainsKey($projectCode)
    }

    $canApprove = ($canModify -and $CanApproveEmployeeRole)
    $permissionReason = "editable"

    if (-not $canModify) {
        $permissionReason = "readOnlyProject"
    }
    elseif (-not $CanApproveEmployeeRole) {
        $permissionReason = "superAdminApproval"
    }

    $Entry | Add-Member -NotePropertyName canModify -NotePropertyValue ([bool]$canModify) -Force
    $Entry | Add-Member -NotePropertyName canApprove -NotePropertyValue ([bool]$canApprove) -Force
    $Entry | Add-Member -NotePropertyName permissionReason -NotePropertyValue $permissionReason -Force
    return $Entry
}

function New-EmployeeEntryProjectionForCurrentUser {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [Parameter(Mandatory = $true)]$Entry,
        $CurrentUser,
        [string]$EmployeeRole = "employee"
    )

    $projection = New-EmployeeEntryProjection -EmployeeCode $EmployeeCode -EmployeeName $EmployeeName -Entry $Entry -EmployeeRole $EmployeeRole
    return (Add-EntryPermissionProjection -Entry $projection -CurrentUser $CurrentUser -EmployeeRole $EmployeeRole)
}

function New-EmployeeEntryProjectionForAccessModel {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$EmployeeName,
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$ModifyProjectCodeSet,
        [string]$EmployeeRole = "employee",
        [bool]$IsSuperAdmin = $false,
        [bool]$CanApproveEmployeeRole = $true
    )

    $projection = New-EmployeeEntryProjection -EmployeeCode $EmployeeCode -EmployeeName $EmployeeName -Entry $Entry -EmployeeRole $EmployeeRole
    return (Add-EntryPermissionProjectionFromAccessModel -Entry $projection -ModifyProjectCodeSet $ModifyProjectCodeSet -IsSuperAdmin:$IsSuperAdmin -CanApproveEmployeeRole:$CanApproveEmployeeRole)
}

function Get-CachedEmployeeEntriesForFile {
    param([Parameter(Mandatory = $true)][string]$DataFile)

    # Invoke-ReadModelCache reconciles once before entering a model factory.
    # Avoid repeating the same sync-state lookup for every employee in a
    # multi-file snapshot while retaining safe direct-call behavior.
    if ($script:ReadModelFactoryDepth -le 0) {
        Sync-ReadModelCaches
    }
    $metadata = Get-FileMetadataSnapshot -Path $DataFile
    if ($null -eq $metadata) {
        if ($script:EmployeeEntryFileCache.ContainsKey($DataFile)) {
            $script:EmployeeEntryFileCache.Remove($DataFile) | Out-Null
        }
        return @()
    }

    $cacheEntry = $script:EmployeeEntryFileCache[$DataFile]
    if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
        return $cacheEntry.Entries
    }

    $entriesList = New-Object System.Collections.ArrayList
    foreach ($entry in @(Read-JsonArrayFile -Path $DataFile)) {
        [void]$entriesList.Add((Convert-ToNormalizedEntryObject -Entry $entry))
    }
    $entries = @($entriesList.ToArray())
    $script:EmployeeEntryFileCache[$DataFile] = [PSCustomObject]@{
        LastWriteTicks = $metadata.LastWriteTicks
        Length         = $metadata.Length
        Entries        = $entries
    }

    return $entries
}

function Get-EmployeeDataSnapshot {
    return (Invoke-ReadModelCache -Key "employee-data-snapshot" -Factory {
        $employeesList = New-Object System.Collections.ArrayList
        $entriesByEmployee = @{}
        $flattenedEntriesList = New-Object System.Collections.ArrayList
        $users = @(Get-Users | Where-Object { (Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode "") -and -not [bool]$_.disabled } | Sort-Object username)

        foreach ($user in $users) {
            $employeeCode = Get-UserEmployeeCodeValue -UserRecord $user
            $displayName = if ($user.displayName) { [string]$user.displayName } else { [string](Get-EmployeeName $employeeCode) }
            $effectiveRole = Get-EffectiveUserRole -UserRecord $user
            $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode
            $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)

            $projectCodes = @(
                $entries |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.projectCode) } |
                    ForEach-Object { [string]$_.projectCode } |
                    Sort-Object -Unique
            )

            [void]$employeesList.Add([PSCustomObject]@{
                code       = $employeeCode
                name       = $displayName
                entryCount = $entries.Count
                projectCodes = $projectCodes
                role       = $effectiveRole
                timeEntryTypes = @(Get-EmployeeTimeEntryTypesFromUserRecord -UserRecord $user)
            })

            $entriesByEmployee[$employeeCode] = $entries

            foreach ($entry in $entries) {
                [void]$flattenedEntriesList.Add((New-EmployeeEntryProjection -EmployeeCode $employeeCode -EmployeeName $displayName -Entry $entry -EmployeeRole $effectiveRole))
            }
        }

        return [PSCustomObject]@{
            employees        = @($employeesList.ToArray())
            entriesByEmployee = $entriesByEmployee
            flattenedEntries = @($flattenedEntriesList.ToArray())
        }
    })
}

function Get-ScopedEmployeeDataSnapshot {
    param($CurrentUser)

    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) {
        return [PSCustomObject]@{
            employees         = @()
            entriesByEmployee = @{}
            flattenedEntries  = @()
        }
    }

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $visibleProjectCodeSet = $accessModel.ProjectCodeSet
    $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    if (-not $isSuperAdmin -and $accessModel.ProjectCodes.Count -eq 0) {
        return [PSCustomObject]@{
            employees         = @()
            entriesByEmployee = @{}
            flattenedEntries  = @()
        }
    }

    $scopeKey = if ($isSuperAdmin) { "global" } else { (@($accessModel.ProjectCodes) -join ",") }
    $modifyScopeKey = if ($isSuperAdmin) { "global" } else { (@($modifyAccessModel.ProjectCodes) -join ",") }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $cacheKey = "scoped-employee-data-snapshot|{0}|{1}|{2}" -f $scopeKey, $modifyScopeKey, $userScopeKey

    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $snapshot = Get-EmployeeDataSnapshot
        $employeesList = New-Object System.Collections.ArrayList
        $entriesByEmployee = @{}
        $flattenedEntriesList = New-Object System.Collections.ArrayList

        foreach ($employee in @($snapshot.employees)) {
            $employeeCode = [string]$employee.code
            $employeeRole = if ($employee.PSObject.Properties.Name -contains "role") { [string]$employee.role } else { "employee" }
            $entries = if ($snapshot.entriesByEmployee.ContainsKey($employeeCode)) { @($snapshot.entriesByEmployee[$employeeCode]) } else { @() }
            $visibleEntries = if ($isSuperAdmin) {
                @($entries)
            }
            else {
                @($entries | Where-Object { $visibleProjectCodeSet.ContainsKey([string]$_.projectCode) })
            }
            if ($visibleEntries.Count -eq 0) {
                continue
            }

            $projectCodes = @(
                $visibleEntries |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.projectCode) } |
                    ForEach-Object { [string]$_.projectCode } |
                    Sort-Object -Unique
            )

            [void]$employeesList.Add([PSCustomObject]@{
                code         = $employeeCode
                name         = [string]$employee.name
                entryCount   = $visibleEntries.Count
                projectCodes = $projectCodes
                role         = $employeeRole
                timeEntryTypes = if ($employee.PSObject.Properties.Name -contains "timeEntryTypes") { @($employee.timeEntryTypes) } else { @("overtime") }
            })

            $canApproveEmployeeRole = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $employeeRole
            $projectedEntriesList = New-Object System.Collections.ArrayList
            foreach ($entry in $visibleEntries) {
                $projectedEntry = New-EmployeeEntryProjectionForAccessModel -EmployeeCode $employeeCode -EmployeeName ([string]$employee.name) -Entry $entry -ModifyProjectCodeSet $modifyAccessModel.ProjectCodeSet -EmployeeRole $employeeRole -IsSuperAdmin:$isSuperAdmin -CanApproveEmployeeRole:$canApproveEmployeeRole
                [void]$projectedEntriesList.Add($projectedEntry)
                [void]$flattenedEntriesList.Add($projectedEntry)
            }

            $entriesByEmployee[$employeeCode] = @($projectedEntriesList.ToArray())
        }

        return [PSCustomObject]@{
            employees         = @($employeesList.ToArray())
            entriesByEmployee = $entriesByEmployee
            flattenedEntries  = @($flattenedEntriesList.ToArray())
        }
    })
}

function Get-FilteredEmployeeEntriesSnapshot {
    param(
        [string]$StartDate,
        [string]$EndDate
    )

    $cacheKey = "filtered-employee-entries|{0}|{1}" -f [string]$StartDate, [string]$EndDate
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $snapshot = Get-EmployeeDataSnapshot
        $entries = @($snapshot.flattenedEntries)
        $startDt = $null
        $endDt = $null

        if ($StartDate) {
            try {
                $startDt = [DateTime]::ParseExact($StartDate, "yyyy-MM-dd", $null)
            }
            catch { }
        }

        if ($EndDate) {
            try {
                $endDt = [DateTime]::ParseExact($EndDate, "yyyy-MM-dd", $null)
            }
            catch { }
        }

        if (-not $startDt -and -not $endDt) {
            return $entries
        }

        $filteredList = New-Object System.Collections.ArrayList
        foreach ($entry in $entries) {
            $entryDate = Get-EntryDateOrNull -Entry $entry
            if ($null -eq $entryDate) {
                continue
            }

            if ($startDt -and $entryDate -lt $startDt) {
                continue
            }

            if ($endDt -and $entryDate -gt $endDt) {
                continue
            }

            [void]$filteredList.Add($entry)
        }

        return @($filteredList.ToArray())
    })
}

function Get-HistoryEntriesSnapshot {
    return (Invoke-ReadModelCache -Key "history-entries" -Factory {
        if (-not (Test-SaphirFileExists -Path $historyFile)) {
            return @()
        }

        return @(Read-JsonArrayFile -Path $historyFile)
    })
}

function Get-SortedHistoryEntriesSnapshot {
    return (Invoke-ReadModelCache -Key "history-entries-sorted" -Factory {
        return @(Get-HistoryEntriesSnapshot | Sort-Object {
            try {
                [DateTime]::Parse(($_.timestamp -replace " ", "T"))
            }
            catch {
                [DateTime]::MinValue
            }
        } -Descending)
    })
}

function Get-RecentHistoryEntriesSnapshot {
    param([int]$Limit = 7)

    $entries = @(Get-SortedHistoryEntriesSnapshot)

    if ($Limit -le 0) {
        return $entries
    }

    return @($entries | Select-Object -First $Limit)
}

function Get-DashboardBootstrapModel {
    param(
        [string]$SelectedEmployeeCode,
        $CurrentUser
    )

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $scopeKey = if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) { "global" } else { (@($accessModel.ProjectCodes) -join ",") }
    $modifyScopeKey = if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) { "global" } else { (@($modifyAccessModel.ProjectCodes) -join ",") }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $cacheKey = "dashboard-bootstrap|{0}|{1}|{2}|{3}" -f [string]$SelectedEmployeeCode, $scopeKey, $modifyScopeKey, $userScopeKey
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $snapshot = Get-ScopedEmployeeDataSnapshot -CurrentUser $CurrentUser
        $flattenedEntries = @($snapshot.flattenedEntries)
        $now = Get-Date
        $totalSeconds = 0

        foreach ($entry in $flattenedEntries) {
            $entryType = if ($entry.PSObject.Properties.Name -contains "entryType") { ([string]$entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }
            if ($entryType -eq "diverse") {
                continue
            }

            $entryDate = Get-EntryDateOrNull -Entry $entry
            if ($null -eq $entryDate) {
                continue
            }

            if ($entryDate.Month -eq $now.Month -and $entryDate.Year -eq $now.Year) {
                $totalSeconds += Get-OvertimeSecondsFromText -Value ([string]$entry.overtime)
            }
        }

        $pendingEntries = @($flattenedEntries | Where-Object { [string]$_.status -eq "pending" -and -not (Test-EntryOpen $_) } | Sort-Object { Get-EntryDateTimeOrMin -Entry $_ } -Descending)
        $activeEntries = @($flattenedEntries | Where-Object { Test-EntryOpen $_ } | Sort-Object { Get-EntryDateTimeOrMin -Entry $_ } -Descending)
        $preferredEntry = $pendingEntries | Select-Object -First 1
        $defaultEmployeeCode = if ($preferredEntry) { [string]$preferredEntry.employeeCode } elseif ($snapshot.employees.Count -gt 0) { [string]$snapshot.employees[0].code } else { "" }
        $resolvedEmployeeCode = if ([string]::IsNullOrWhiteSpace([string]$SelectedEmployeeCode)) { $defaultEmployeeCode } else { [string]$SelectedEmployeeCode }
        if ($resolvedEmployeeCode -and -not $snapshot.entriesByEmployee.ContainsKey($resolvedEmployeeCode)) {
            $resolvedEmployeeCode = $defaultEmployeeCode
        }
        $selectedEmployeeEntries = if ($resolvedEmployeeCode -and $snapshot.entriesByEmployee.ContainsKey($resolvedEmployeeCode)) { @($snapshot.entriesByEmployee[$resolvedEmployeeCode]) } else { @() }

        return [PSCustomObject]@{
            employees             = $snapshot.employees
            totalOvertime         = Convert-SecondsToTimeText -Seconds $totalSeconds
            pendingApprovals      = @($flattenedEntries | Where-Object { [string]$_.status -eq "pending" }).Count
            activeEmployees       = $activeEntries.Count
            trackedEmployees      = $snapshot.employees.Count
            projects              = @(Get-ProjectsForCurrentUser -CurrentUser $CurrentUser -Scope "all")
            pendingQueue          = @($pendingEntries | Select-Object -First 6)
            activeSessions        = @($activeEntries | Select-Object -First 6)
            recentHistory         = Get-RecentHistoryEntriesSnapshot -Limit 7
            defaultEmployeeCode   = $defaultEmployeeCode
            selectedEmployeeCode  = $resolvedEmployeeCode
            selectedEmployeeEntries = $selectedEmployeeEntries
        }
    })
}

function Get-ApprovalsEntriesModel {
    param($CurrentUser)

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $scopeKey = if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) { "global" } else { (@($accessModel.ProjectCodes) -join ",") }
    $modifyScopeKey = if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) { "global" } else { (@($modifyAccessModel.ProjectCodes) -join ",") }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    return (Invoke-ReadModelCache -Key "approvals-entries|$scopeKey|$modifyScopeKey|$userScopeKey" -Factory {
        return @((Get-ScopedEmployeeDataSnapshot -CurrentUser $CurrentUser).flattenedEntries | Sort-Object { Get-EntryDateTimeOrMin -Entry $_ } -Descending)
    })
}

function Get-ProjectEntryType {
    param($Entry)

    if ($null -eq $Entry -or -not ($Entry.PSObject.Properties.Name -contains "entryType") -or [string]::IsNullOrWhiteSpace([string]$Entry.entryType)) {
        return "overtime"
    }

    return ([string]$Entry.entryType).Trim().ToLowerInvariant()
}

function Get-ProjectEntryStatus {
    param($Entry)

    if ($null -eq $Entry -or -not ($Entry.PSObject.Properties.Name -contains "status") -or [string]::IsNullOrWhiteSpace([string]$Entry.status)) {
        return "pending"
    }

    return ([string]$Entry.status).Trim().ToLowerInvariant()
}

function Test-ProjectEntryClosed {
    param($Entry)

    if ($null -eq $Entry -or
        -not ($Entry.PSObject.Properties.Name -contains "punchOut") -or
        [string]::IsNullOrWhiteSpace([string]$Entry.punchOut)) {
        return $false
    }

    return (-not (Test-EntryForgottenClockOut -Entry $Entry))
}

function Get-ProjectEntryStatusBucketName {
    param($Entry)

    if (-not (Test-ProjectEntryClosed -Entry $Entry)) {
        return "open"
    }

    $status = Get-ProjectEntryStatus -Entry $Entry
    if (@("approved", "pending", "rejected") -contains $status) {
        return $status
    }

    return "other"
}

function New-ProjectStatisticsBasis {
    return [PSCustomObject]@{
        id               = "approvedClosedOvertime"
        entryType        = "overtime"
        status           = "approved"
        requiresPunchOut = $true
    }
}

function New-ProjectStatusAccumulatorSet {
    $result = @{}
    foreach ($bucketName in @("approved", "pending", "rejected", "open", "other")) {
        $result[$bucketName] = [PSCustomObject]@{
            count   = 0
            seconds = [long]0
        }
    }
    return $result
}

function ConvertTo-ProjectStatusBucketModel {
    param($Buckets)

    $result = [ordered]@{}
    foreach ($bucketName in @("approved", "pending", "rejected", "open", "other")) {
        $bucket = if ($null -ne $Buckets -and $Buckets.ContainsKey($bucketName)) { $Buckets[$bucketName] } else { $null }
        $seconds = if ($null -ne $bucket) { [long]$bucket.seconds } else { [long]0 }
        $result[$bucketName] = [PSCustomObject]@{
            count    = if ($null -ne $bucket) { [int]$bucket.count } else { 0 }
            seconds  = $seconds
            overtime = Convert-SecondsToTimeText -Seconds $seconds
        }
    }
    return [PSCustomObject]$result
}

function ConvertTo-ProjectDateOrNull {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    $parsed = [DateTime]::MinValue
    $isValid = [DateTime]::TryParseExact(
        ([string]$Value).Trim(),
        "yyyy-MM-dd",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
    if (-not $isValid) {
        return $null
    }
    return $parsed.Date
}

function New-ProjectPeriodModel {
    param(
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate
    )

    $start = ConvertTo-ProjectDateOrNull -Value $StartDate
    $end = ConvertTo-ProjectDateOrNull -Value $EndDate
    return [PSCustomObject]@{
        startDate = if ($null -ne $start) { $start.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) } else { "" }
        endDate   = if ($null -ne $end) { $end.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) } else { "" }
    }
}

function Get-ProjectStatisticsEntriesSnapshot {
    param($CurrentUser)

    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) {
        return @()
    }

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $scopeKey = if ($isSuperAdmin) { "global" } else { (@($accessModel.ProjectCodes) -join ",") }
    $modifyScopeKey = if ($isSuperAdmin) { "global" } else { (@($modifyAccessModel.ProjectCodes) -join ",") }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $cacheKey = "project-statistics-entry-snapshot|{0}|{1}|{2}" -f $scopeKey, $modifyScopeKey, $userScopeKey

    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $entriesList = New-Object System.Collections.ArrayList
        $seenEmployeeCodes = @{}
        $users = @(Get-Users | Where-Object { Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode "" } | Sort-Object username)

        foreach ($user in $users) {
            $employeeCode = Get-UserEmployeeCodeValue -UserRecord $user
            if ([string]::IsNullOrWhiteSpace($employeeCode) -or $seenEmployeeCodes.ContainsKey($employeeCode)) {
                continue
            }
            $seenEmployeeCodes[$employeeCode] = $true

            $displayName = if ($user.PSObject.Properties.Name -contains "displayName") { ([string]$user.displayName).Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = [string](Get-EmployeeName $employeeCode)
            }
            $employeeRole = Get-EffectiveUserRole -UserRecord $user
            $employeeArchived = ($user.PSObject.Properties.Name -contains "disabled" -and [bool]$user.disabled)
            $canApproveEmployeeRole = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $employeeRole
            $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode

            foreach ($entry in @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)) {
                $projectCode = if ($entry.PSObject.Properties.Name -contains "projectCode") { ([string]$entry.projectCode).Trim() } else { "" }
                if ([string]::IsNullOrWhiteSpace($projectCode) -or (-not $isSuperAdmin -and -not $accessModel.ProjectCodeSet.ContainsKey($projectCode))) {
                    continue
                }

                $projection = New-EmployeeEntryProjectionForAccessModel `
                    -EmployeeCode $employeeCode `
                    -EmployeeName $displayName `
                    -Entry $entry `
                    -ModifyProjectCodeSet $modifyAccessModel.ProjectCodeSet `
                    -EmployeeRole $employeeRole `
                    -IsSuperAdmin:$isSuperAdmin `
                    -CanApproveEmployeeRole:$canApproveEmployeeRole
                $projection | Add-Member -NotePropertyName employeeArchived -NotePropertyValue ([bool]$employeeArchived) -Force
                [void]$entriesList.Add($projection)
            }
        }

        return @($entriesList.ToArray())
    })
}

function Get-ProjectStatisticsEntriesForPeriod {
    param(
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate,
        $CurrentUser
    )

    $start = ConvertTo-ProjectDateOrNull -Value $StartDate
    $end = ConvertTo-ProjectDateOrNull -Value $EndDate
    $entries = @(Get-ProjectStatisticsEntriesSnapshot -CurrentUser $CurrentUser)
    if ($null -eq $start -and $null -eq $end) {
        return $entries
    }

    $filteredList = New-Object System.Collections.ArrayList
    foreach ($entry in $entries) {
        $entryDate = Get-EntryDateOrNull -Entry $entry
        if ($null -eq $entryDate -or ($null -ne $start -and $entryDate -lt $start) -or ($null -ne $end -and $entryDate -gt $end)) {
            continue
        }
        [void]$filteredList.Add($entry)
    }
    return @($filteredList.ToArray())
}

function New-ProjectEntryDetailProjection {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$StatusBucket,
        [Parameter(Mandatory = $true)][long]$DurationSeconds
    )

    $employeeCode = if ($Entry.PSObject.Properties.Name -contains "employeeCode") { [string]$Entry.employeeCode } else { "" }
    $employeeName = if ($Entry.PSObject.Properties.Name -contains "employeeName") { [string]$Entry.employeeName } elseif ($Entry.PSObject.Properties.Name -contains "name") { [string]$Entry.name } else { "" }
    return [PSCustomObject]@{
        entryId          = if ($Entry.PSObject.Properties.Name -contains "entryId") { [string]$Entry.entryId } else { "" }
        employeeCode     = $employeeCode
        employeeName     = $employeeName
        employeeArchived = if ($Entry.PSObject.Properties.Name -contains "employeeArchived") { [bool]$Entry.employeeArchived } else { $false }
        entryType        = Get-ProjectEntryType -Entry $Entry
        date             = if ($Entry.PSObject.Properties.Name -contains "date") { [string]$Entry.date } else { "" }
        punchIn          = if ($Entry.PSObject.Properties.Name -contains "punchIn") { [string]$Entry.punchIn } else { "" }
        exactPunchIn     = if ($Entry.PSObject.Properties.Name -contains "exactPunchIn") { [string]$Entry.exactPunchIn } else { "" }
        punchOut         = if ($Entry.PSObject.Properties.Name -contains "punchOut") { [string]$Entry.punchOut } else { "" }
        exactPunchOut    = if ($Entry.PSObject.Properties.Name -contains "exactPunchOut") { [string]$Entry.exactPunchOut } else { "" }
        overtime         = Convert-SecondsToTimeText -Seconds $DurationSeconds
        durationSeconds  = $DurationSeconds
        status           = Get-ProjectEntryStatus -Entry $Entry
        statusBucket     = $StatusBucket
        isOpen           = ($StatusBucket -eq "open")
        workComment      = if ($Entry.PSObject.Properties.Name -contains "workComment") { [string]$Entry.workComment } else { "" }
        diverseSummary   = if ($Entry.PSObject.Properties.Name -contains "diverseSummary") { [string]$Entry.diverseSummary } else { "" }
        message          = if ($Entry.PSObject.Properties.Name -contains "message") { [string]$Entry.message } else { "" }
        paymentOption    = if ($Entry.PSObject.Properties.Name -contains "paymentOption") { [string]$Entry.paymentOption } else { "" }
        overtimeCode     = if ($Entry.PSObject.Properties.Name -contains "overtimeCode") { [string]$Entry.overtimeCode } else { "" }
        reasonCode       = if ($Entry.PSObject.Properties.Name -contains "reasonCode") { [string]$Entry.reasonCode } else { "" }
        canModify        = if ($Entry.PSObject.Properties.Name -contains "canModify") { [bool]$Entry.canModify } else { $false }
        canApprove       = if ($Entry.PSObject.Properties.Name -contains "canApprove") { [bool]$Entry.canApprove } else { $false }
        permissionReason = if ($Entry.PSObject.Properties.Name -contains "permissionReason") { [string]$Entry.permissionReason } else { "readOnlyProject" }
    }
}

function Get-ProjectStatisticsOverview {
    param(
        [string]$StartDate,
        [string]$EndDate,
        [bool]$IncludeBreakdown = $true,
        $CurrentUser
    )

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $scopeKey = if ($isSuperAdmin) { "global" } else { (@($accessModel.ProjectCodes) -join ",") }
    $modifyScopeKey = if ($isSuperAdmin) { "global" } else { (@($modifyAccessModel.ProjectCodes) -join ",") }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $detailKey = if ($IncludeBreakdown) { "detail" } else { "summary" }
    $cacheKey = "project-statistics-overview|{0}|{1}|{2}|{3}|{4}|{5}" -f [string]$StartDate, [string]$EndDate, $scopeKey, $modifyScopeKey, $userScopeKey, $detailKey
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $stats = @{}
        $entries = @(Get-ProjectStatisticsEntriesForPeriod -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser)
        $visibleProjectCodeSet = $accessModel.ProjectCodeSet

        foreach ($entry in $entries) {
            if ((Get-ProjectEntryType -Entry $entry) -ne "overtime") {
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.projectCode)) {
                continue
            }

            $projectCode = [string]$entry.projectCode
            if (-not $visibleProjectCodeSet.ContainsKey($projectCode)) {
                continue
            }

            $seconds = [long](Get-OvertimeSecondsFromText -Value ([string]$entry.overtime))
            $statusBucket = Get-ProjectEntryStatusBucketName -Entry $entry

            if (-not $stats.ContainsKey($projectCode)) {
                $stats[$projectCode] = [PSCustomObject]@{
                    totalSeconds   = [long]0
                    trackedSeconds = [long]0
                    entryCount     = 0
                    approvedEntryCount = 0
                    minSeconds     = $null
                    maxSeconds     = $null
                    statusBuckets  = (New-ProjectStatusAccumulatorSet)
                    breakdown      = if ($IncludeBreakdown) { @{} } else { $null }
                }
            }

            $stats[$projectCode].trackedSeconds += $seconds
            $stats[$projectCode].entryCount++
            $stats[$projectCode].statusBuckets[$statusBucket].count++
            $stats[$projectCode].statusBuckets[$statusBucket].seconds += $seconds
            if ($statusBucket -eq "approved") {
                $stats[$projectCode].totalSeconds += $seconds
                $stats[$projectCode].approvedEntryCount++
                if ($null -eq $stats[$projectCode].minSeconds -or $seconds -lt $stats[$projectCode].minSeconds) {
                    $stats[$projectCode].minSeconds = $seconds
                }
                if ($null -eq $stats[$projectCode].maxSeconds -or $seconds -gt $stats[$projectCode].maxSeconds) {
                    $stats[$projectCode].maxSeconds = $seconds
                }
            }

            if (-not $IncludeBreakdown) {
                continue
            }

            $employeeName = if ($entry.employeeName) { [string]$entry.employeeName } else { [string]$entry.name }
            $employeeCode = if ($entry.employeeCode) { [string]$entry.employeeCode } else { [string]$employeeName }
            if (-not $stats[$projectCode].breakdown.ContainsKey($employeeCode)) {
                $stats[$projectCode].breakdown[$employeeCode] = @{
                    employeeCode = $employeeCode
                    employeeName = $employeeName
                    employeeArchived = if ($entry.PSObject.Properties.Name -contains "employeeArchived") { [bool]$entry.employeeArchived } else { $false }
                    totalSeconds = [long]0
                    trackedSeconds = [long]0
                    entryCount   = 0
                    approvedEntryCount = 0
                    pendingCount = 0
                    pendingSeconds = [long]0
                    openCount = 0
                    lastActivityDate = ""
                    lastActivityAt = ""
                    entries      = (New-Object System.Collections.ArrayList)
                }
            }

            $employeeBucket = $stats[$projectCode].breakdown[$employeeCode]
            $employeeBucket.trackedSeconds += $seconds
            $employeeBucket.entryCount++
            if ($statusBucket -eq "approved") {
                $employeeBucket.totalSeconds += $seconds
                $employeeBucket.approvedEntryCount++
            }
            elseif ($statusBucket -eq "pending") {
                $employeeBucket.pendingCount++
                $employeeBucket.pendingSeconds += $seconds
            }
            elseif ($statusBucket -eq "open") {
                $employeeBucket.openCount++
            }

            $entryDateTime = Get-EntryDateTimeOrMin -Entry $entry
            if ($entryDateTime -ne [DateTime]::MinValue) {
                $entryActivityAt = $entryDateTime.ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
                if ([string]::IsNullOrWhiteSpace([string]$employeeBucket.lastActivityAt) -or $entryActivityAt -gt [string]$employeeBucket.lastActivityAt) {
                    $employeeBucket.lastActivityAt = $entryActivityAt
                    $employeeBucket.lastActivityDate = $entryDateTime.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
                }
            }

            [void]$employeeBucket.entries.Add((New-ProjectEntryDetailProjection -Entry $entry -StatusBucket $statusBucket -DurationSeconds $seconds))
        }

        return $stats
    })
}

function Get-ProjectSummaryList {
    param(
        [string]$StartDate,
        [string]$EndDate,
        $CurrentUser
    )

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser
    $scopeKey = if ($isSuperAdmin) { "global" } else { (@($accessModel.ProjectCodes) -join ",") }
    $modifyScopeKey = if ($isSuperAdmin) { "global" } else { (@($modifyAccessModel.ProjectCodes) -join ",") }
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $cacheKey = "project-summary-list|{0}|{1}|{2}|{3}|{4}" -f [string]$StartDate, [string]$EndDate, $scopeKey, $modifyScopeKey, $userScopeKey
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $projects = @($accessModel.Projects)
        $projectMap = @{}
        foreach ($project in $projects) {
            $projectMap[[string]$project.projectCode] = $project
        }

        $stats = Get-ProjectStatisticsOverview -StartDate $StartDate -EndDate $EndDate -IncludeBreakdown:$false -CurrentUser $CurrentUser
        $departmentApprovedSeconds = [long]0
        foreach ($statProjectCode in @($stats.Keys)) {
            $departmentApprovedSeconds += [long]$stats[$statProjectCode].totalSeconds
        }
        $orderedCodes = New-Object System.Collections.ArrayList
        $employeeNameMap = Get-EmployeeNameMap
        $basis = New-ProjectStatisticsBasis
        $period = New-ProjectPeriodModel -StartDate $StartDate -EndDate $EndDate

        foreach ($project in ($projects | Sort-Object projectCode)) {
            if (-not $orderedCodes.Contains([string]$project.projectCode)) {
                [void]$orderedCodes.Add([string]$project.projectCode)
            }
        }

        foreach ($projectCode in ($stats.Keys | Sort-Object)) {
            if (-not $orderedCodes.Contains([string]$projectCode)) {
                [void]$orderedCodes.Add([string]$projectCode)
            }
        }

        $summariesList = New-Object System.Collections.ArrayList
        foreach ($projectCode in $orderedCodes) {
            $project = if ($projectMap.ContainsKey([string]$projectCode)) { $projectMap[[string]$projectCode] } else { $null }
            $projectStats = if ($stats.ContainsKey($projectCode)) { $stats[$projectCode] } else { $null }
            $totalSeconds = if ($projectStats) { [long]$projectStats.totalSeconds } else { [long]0 }
            $trackedSeconds = if ($projectStats) { [long]$projectStats.trackedSeconds } else { [long]0 }
            $entryCount = if ($projectStats) { [int]$projectStats.entryCount } else { 0 }
            $approvedEntryCount = if ($projectStats) { [int]$projectStats.approvedEntryCount } else { 0 }
            $averageSeconds = if ($approvedEntryCount -gt 0) { [long][math]::Round($totalSeconds / $approvedEntryCount) } else { [long]0 }
            $minSeconds = if ($projectStats -and $null -ne $projectStats.minSeconds) { [long]$projectStats.minSeconds } else { [long]0 }
            $maxSeconds = if ($projectStats -and $null -ne $projectStats.maxSeconds) { [long]$projectStats.maxSeconds } else { [long]0 }
            $adminCodes = if ($project) { @(Get-ProjectAdminCodes -Project $project) } else { @() }
            $backupAdminCodes = if ($project) { @(Get-ProjectBackupAdminCodes -Project $project) } else { @() }
            $statusBuckets = ConvertTo-ProjectStatusBucketModel -Buckets $(if ($projectStats) { $projectStats.statusBuckets } else { $null })
            $sharePercent = if ($departmentApprovedSeconds -gt 0) { [math]::Round(($totalSeconds / [double]$departmentApprovedSeconds) * 100, 2) } else { 0 }

            [void]$summariesList.Add([PSCustomObject]@{
                projectCode     = [string]$projectCode
                projectName     = if ($project) { [string]$project.projectName } else { [string]$projectCode }
                sector          = if ($project) { [string]$project.sector } else { "" }
                admins          = $adminCodes
                backupAdmins    = $backupAdminCodes
                adminDisplay    = @(New-ProjectAdminDisplayList -Codes $adminCodes -EmployeeNameMap $employeeNameMap)
                backupAdminDisplay = @(New-ProjectAdminDisplayList -Codes $backupAdminCodes -EmployeeNameMap $employeeNameMap)
                archived        = if ($project) { Test-ProjectArchived -Project $project } else { $false }
                colorKey        = Resolve-ProjectColorKey -ColorKey $(if ($project -and $project.PSObject.Properties.Name -contains "colorKey") { [string]$project.colorKey } else { "" }) -ProjectCode ([string]$projectCode)
                basis           = $basis
                period          = $period
                totalSeconds    = $totalSeconds
                totalOvertime   = Convert-SecondsToTimeText -Seconds $totalSeconds
                trackedSeconds  = $trackedSeconds
                trackedOvertime = Convert-SecondsToTimeText -Seconds $trackedSeconds
                entryCount      = $entryCount
                allEntryCount   = $entryCount
                approvedEntryCount = $approvedEntryCount
                averageSeconds  = $averageSeconds
                averageOvertime = Convert-SecondsToTimeText -Seconds $averageSeconds
                minSeconds      = $minSeconds
                minOvertime     = Convert-SecondsToTimeText -Seconds $minSeconds
                maxSeconds      = $maxSeconds
                maxOvertime     = Convert-SecondsToTimeText -Seconds $maxSeconds
                statusBuckets   = $statusBuckets
                departmentShare = [PSCustomObject]@{
                    scope                     = "visibleProjects"
                    projectApprovedSeconds    = $totalSeconds
                    departmentApprovedSeconds = $departmentApprovedSeconds
                    percent                   = $sharePercent
                }
            })
        }

        return @($summariesList.ToArray())
    })
}

function New-ProjectAdminDisplayList {
    param(
        $Codes,
        $EmployeeNameMap = $null
    )

    $employeeNameMap = if ($null -ne $EmployeeNameMap) { $EmployeeNameMap } else { Get-EmployeeNameMap }
    $displayList = New-Object System.Collections.ArrayList
    foreach ($code in @(ConvertTo-CodeArray -Value $Codes)) {
        $displayName = if ($employeeNameMap -and ($employeeNameMap.PSObject.Properties.Name -contains [string]$code)) { [string]$employeeNameMap.$code } else { [string]$code }
        [void]$displayList.Add([PSCustomObject]@{
            code = [string]$code
            name = $displayName
        })
    }

    return @($displayList.ToArray())
}

function Get-ProjectPreviousEquivalentPeriod {
    param(
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate
    )

    $start = ConvertTo-ProjectDateOrNull -Value $StartDate
    $end = ConvertTo-ProjectDateOrNull -Value $EndDate
    if ($null -eq $start -or $null -eq $end -or $start -gt $end) {
        return [PSCustomObject]@{
            available = $false
            startDate = ""
            endDate   = ""
        }
    }

    $dayCount = [int](($end - $start).TotalDays) + 1
    $previousEnd = $start.AddDays(-1)
    $previousStart = $previousEnd.AddDays(-($dayCount - 1))
    return [PSCustomObject]@{
        available = $true
        startDate = $previousStart.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
        endDate   = $previousEnd.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function New-ProjectComparisonModel {
    param(
        [Parameter(Mandatory = $true)][long]$CurrentSeconds,
        [AllowNull()][string]$StartDate,
        [AllowNull()][string]$EndDate,
        [Parameter(Mandatory = $true)][string]$ProjectCode,
        $CurrentUser
    )

    $currentPeriod = New-ProjectPeriodModel -StartDate $StartDate -EndDate $EndDate
    $previousPeriod = Get-ProjectPreviousEquivalentPeriod -StartDate $StartDate -EndDate $EndDate
    $previousSeconds = [long]0
    if ([bool]$previousPeriod.available) {
        $previousStats = Get-ProjectStatisticsOverview -StartDate $previousPeriod.startDate -EndDate $previousPeriod.endDate -IncludeBreakdown:$false -CurrentUser $CurrentUser
        if ($previousStats.ContainsKey($ProjectCode)) {
            $previousSeconds = [long]$previousStats[$ProjectCode].totalSeconds
        }
    }

    $deltaSeconds = $CurrentSeconds - $previousSeconds
    $direction = if (-not [bool]$previousPeriod.available) { "unavailable" } elseif ($deltaSeconds -gt 0) { "up" } elseif ($deltaSeconds -lt 0) { "down" } else { "same" }
    $percentChange = if ([bool]$previousPeriod.available -and $previousSeconds -gt 0) {
        [math]::Round(($deltaSeconds / [double]$previousSeconds) * 100, 1)
    }
    else {
        $null
    }

    return [PSCustomObject]@{
        available = [bool]$previousPeriod.available
        current   = [PSCustomObject]@{
            startDate = [string]$currentPeriod.startDate
            endDate   = [string]$currentPeriod.endDate
            seconds   = $CurrentSeconds
            overtime  = Convert-SecondsToTimeText -Seconds $CurrentSeconds
        }
        previous  = [PSCustomObject]@{
            startDate = [string]$previousPeriod.startDate
            endDate   = [string]$previousPeriod.endDate
            seconds   = $previousSeconds
            overtime  = Convert-SecondsToTimeText -Seconds $previousSeconds
        }
        deltaSeconds = $deltaSeconds
        percentChange = $percentChange
        direction    = $direction
    }
}

function Get-ProjectDetailModel {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectCode,
        [string]$StartDate,
        [string]$EndDate,
        $CurrentUser
    )

    $summaries = @(Get-ProjectSummaryList -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser)
    $projectSummary = $summaries | Where-Object { [string]$_.projectCode -eq [string]$ProjectCode } | Select-Object -First 1
    if ($null -eq $projectSummary) {
        return $null
    }

    $stats = Get-ProjectStatisticsOverview -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser
    $projectStats = if ($stats.ContainsKey($ProjectCode)) { $stats[$ProjectCode] } else { $null }
    $contributorsList = New-Object System.Collections.ArrayList
    $recentEntriesList = New-Object System.Collections.ArrayList

    if ($projectStats) {
        foreach ($employeeCode in @($projectStats.breakdown.Keys)) {
            $employeeStats = $projectStats.breakdown[$employeeCode]
            $approvedSeconds = [long]$employeeStats.totalSeconds
            $approvedEntryCount = [int]$employeeStats.approvedEntryCount
            $averageApprovedSeconds = if ($approvedEntryCount -gt 0) { [long][math]::Round($approvedSeconds / $approvedEntryCount) } else { [long]0 }
            $sharePercent = if ([long]$projectStats.totalSeconds -gt 0) { [math]::Round(($approvedSeconds / [double]$projectStats.totalSeconds) * 100, 2) } else { 0 }
            $entries = @($employeeStats.entries | Sort-Object date, punchIn)
            foreach ($entry in $entries) {
                [void]$recentEntriesList.Add($entry)
            }

            [void]$contributorsList.Add([PSCustomObject]@{
                employeeCode = [string]$employeeStats.employeeCode
                employee     = [string]$employeeStats.employeeName
                employeeArchived = [bool]$employeeStats.employeeArchived
                approvedSeconds = $approvedSeconds
                overtime     = Convert-SecondsToTimeText -Seconds $approvedSeconds
                approvedEntryCount = $approvedEntryCount
                entryCount   = [int]$employeeStats.entryCount
                pendingCount = [int]$employeeStats.pendingCount
                pendingSeconds = [long]$employeeStats.pendingSeconds
                pendingOvertime = Convert-SecondsToTimeText -Seconds ([long]$employeeStats.pendingSeconds)
                openCount    = [int]$employeeStats.openCount
                sharePercent = $sharePercent
                averageApprovedSeconds = $averageApprovedSeconds
                averageOvertime = Convert-SecondsToTimeText -Seconds $averageApprovedSeconds
                lastActivityDate = [string]$employeeStats.lastActivityDate
                lastActivityAt = [string]$employeeStats.lastActivityAt
                entries      = $entries
            })
        }
    }

    $contributors = @($contributorsList.ToArray() | Sort-Object `
        @{ Expression = { [long]$_.approvedSeconds }; Descending = $true }, `
        @{ Expression = { [string]$_.employee }; Descending = $false }, `
        @{ Expression = { [string]$_.employeeCode }; Descending = $false })
    $recentEntries = @($recentEntriesList.ToArray() | Sort-Object `
        @{ Expression = { Get-EntryDateTimeOrMin -Entry $_ }; Descending = $true }, `
        @{ Expression = { [string]$_.entryId }; Descending = $false } | Select-Object -First 20)
    $comparison = New-ProjectComparisonModel -CurrentSeconds ([long]$projectSummary.totalSeconds) -StartDate $StartDate -EndDate $EndDate -ProjectCode $ProjectCode -CurrentUser $CurrentUser
    $trendModel = Get-ProjectTrendModel -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser
    $approvedTrend = if ($trendModel.ContainsKey($ProjectCode)) { @($trendModel[$ProjectCode]) } else { @() }

    return [PSCustomObject]@{
        projectCode         = [string]$projectSummary.projectCode
        projectName         = [string]$projectSummary.projectName
        sector              = if ($projectSummary.PSObject.Properties.Name -contains "sector") { [string]$projectSummary.sector } else { "" }
        admins              = if ($projectSummary.PSObject.Properties.Name -contains "admins") { @($projectSummary.admins) } else { @() }
        backupAdmins        = if ($projectSummary.PSObject.Properties.Name -contains "backupAdmins") { @($projectSummary.backupAdmins) } else { @() }
        adminDisplay        = if ($projectSummary.PSObject.Properties.Name -contains "adminDisplay") { @($projectSummary.adminDisplay) } else { @() }
        backupAdminDisplay  = if ($projectSummary.PSObject.Properties.Name -contains "backupAdminDisplay") { @($projectSummary.backupAdminDisplay) } else { @() }
        archived            = if ($projectSummary.PSObject.Properties.Name -contains "archived") { [bool]$projectSummary.archived } else { $false }
        colorKey            = Resolve-ProjectColorKey -ColorKey $(if ($projectSummary.PSObject.Properties.Name -contains "colorKey") { [string]$projectSummary.colorKey } else { "" }) -ProjectCode ([string]$projectSummary.projectCode)
        basis               = $projectSummary.basis
        period              = $projectSummary.period
        totalSeconds        = [long]$projectSummary.totalSeconds
        totalOvertime       = [string]$projectSummary.totalOvertime
        trackedSeconds      = [long]$projectSummary.trackedSeconds
        trackedOvertime     = [string]$projectSummary.trackedOvertime
        entryCount          = [int]$projectSummary.entryCount
        allEntryCount       = [int]$projectSummary.allEntryCount
        approvedEntryCount  = [int]$projectSummary.approvedEntryCount
        averageSeconds      = [long]$projectSummary.averageSeconds
        averageOvertime     = [string]$projectSummary.averageOvertime
        minSeconds          = [long]$projectSummary.minSeconds
        minOvertime         = [string]$projectSummary.minOvertime
        maxSeconds          = [long]$projectSummary.maxSeconds
        maxOvertime         = [string]$projectSummary.maxOvertime
        statusBuckets       = $projectSummary.statusBuckets
        departmentShare     = $projectSummary.departmentShare
        comparison          = $comparison
        contributors        = $contributors
        breakdownByEmployee = $contributors
        recentEntries       = $recentEntries
        approvedTrend       = $approvedTrend
        coverage            = [PSCustomObject]@{
            includesArchivedEmployees = $true
        }
    }
}

function Get-ProjectTrendModel {
    param(
        [string]$StartDate,
        [string]$EndDate,
        $CurrentUser
    )

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $userScopeKey = Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser
    $scopeKey = if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) { "global" } else { (@($accessModel.ProjectCodes) -join ",") }
    $cacheKey = "project-trends|approved-closed|{0}|{1}|{2}|{3}" -f [string]$StartDate, [string]$EndDate, $scopeKey, $userScopeKey
    return (Invoke-ReadModelCache -Key $cacheKey -Factory {
        $trendStats = @{}
        $entries = @(Get-ProjectStatisticsEntriesForPeriod -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser)
        $visibleProjectCodeSet = $accessModel.ProjectCodeSet

        foreach ($entry in $entries) {
            if ((Get-ProjectEntryType -Entry $entry) -ne "overtime" -or (Get-ProjectEntryStatusBucketName -Entry $entry) -ne "approved") {
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.projectCode) -or [string]::IsNullOrWhiteSpace([string]$entry.date) -or [string]$entry.date -notmatch '^\d{4}-\d{2}') {
                continue
            }

            if (-not $visibleProjectCodeSet.ContainsKey([string]$entry.projectCode)) {
                continue
            }

            $month = $entry.date.Substring(0, 7)
            $seconds = Get-OvertimeSecondsFromText -Value ([string]$entry.overtime)

            if (-not $trendStats.ContainsKey([string]$entry.projectCode)) {
                $trendStats[[string]$entry.projectCode] = @{}
            }

            if (-not $trendStats[[string]$entry.projectCode].ContainsKey($month)) {
                $trendStats[[string]$entry.projectCode][$month] = 0
            }

            $trendStats[[string]$entry.projectCode][$month] += $seconds
        }

        $result = @{}
        foreach ($projectCode in $trendStats.Keys) {
            $monthsList = New-Object System.Collections.ArrayList
            foreach ($month in ($trendStats[$projectCode].Keys | Sort-Object)) {
                $seconds = [long]$trendStats[$projectCode][$month]
                [void]$monthsList.Add([PSCustomObject]@{
                    month    = $month
                    overtime = [math]::Round(($seconds / 3600), 2)
                    seconds  = $seconds
                    duration = Convert-SecondsToTimeText -Seconds $seconds
                })
            }

            $result[$projectCode] = @($monthsList.ToArray())
        }

        return $result
    })
}

function Get-ProjectsBootstrapModel {
    param(
        [string]$StartDate,
        [string]$EndDate,
        [string]$SelectedProjectCode,
        [AllowNull()][string]$Scope = "all",
        [bool]$IncludeDetail = $true,
        $CurrentUser
    )

    $normalizedScope = ConvertTo-ProjectArchiveScope -Scope $Scope
    $allSummary = @(Get-ProjectSummaryList -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser)
    $summary = @(Select-ProjectsByArchiveScope -Projects $allSummary -Scope $normalizedScope)
    $allTrends = Get-ProjectTrendModel -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser
    $visibleProjectCodes = @{}
    foreach ($project in $summary) {
        $visibleProjectCodes[[string]$project.projectCode] = $true
    }
    $trends = @{}
    foreach ($projectCode in @($allTrends.Keys)) {
        if ($visibleProjectCodes.ContainsKey([string]$projectCode)) {
            $trends[[string]$projectCode] = $allTrends[$projectCode]
        }
    }

    $resolvedProjectCode = [string]$SelectedProjectCode
    if ([string]::IsNullOrWhiteSpace($resolvedProjectCode) -or -not ($summary | Where-Object { [string]$_.projectCode -eq $resolvedProjectCode })) {
        if ($summary.Count -gt 0) {
            $resolvedProjectCode = [string]$summary[0].projectCode
        }
        else {
            $resolvedProjectCode = ""
        }
    }

    return [PSCustomObject]@{
        summary             = $summary
        trends              = $trends
        scope               = $normalizedScope
        selectedProjectCode = $resolvedProjectCode
        detailIncluded      = [bool]$IncludeDetail
        selectedProject     = if ($IncludeDetail -and $resolvedProjectCode) { Get-ProjectDetailModel -ProjectCode $resolvedProjectCode -StartDate $StartDate -EndDate $EndDate -CurrentUser $CurrentUser } else { $null }
    }
}

function Get-SelfBootstrapModel {
    param([Parameter(Mandatory = $true)][string]$EmployeeCode)

    $dataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $EmployeeCode)
    $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)
    $timeEntryTypes = @(Get-EmployeeTimeEntryTypesByCode -EmployeeCode $EmployeeCode)
    $user = Get-EmployeeUserByCode -EmployeeCode $EmployeeCode

    return [PSCustomObject]@{
        entries        = $entries
        projects       = @(Get-ActiveProjects)
        overtimeCodes  = @(Get-OvertimeCodes)
        paymentOptions = @(Get-PaymentOptions)
        reasonCodes    = @(Get-ReasonCodes)
        timeEntryTypes = $timeEntryTypes
        gc179Profile   = Get-Gc179ProfileFromUserRecord -UserRecord $user
    }
}
