if ($null -eq $script:AuthStorageEnsured) {
    $script:AuthStorageEnsured = $false
}

if (-not $script:AuthArrayFileCache) {
    $script:AuthArrayFileCache = @{}
}

if (-not $script:ProjectAccessModelCache) {
    $script:ProjectAccessModelCache = @{}
}

if (-not $script:AuthenticatedUserRequestCache) {
    $script:AuthenticatedUserRequestCache = @{}
}

if ($null -eq $script:LoginThrottleState) {
    $script:LoginThrottleState = @{}
}

if (-not $script:LoginThrottleWindowSeconds) {
    $script:LoginThrottleWindowSeconds = 300
}

if (-not $script:LoginThrottlePrincipalLimit) {
    $script:LoginThrottlePrincipalLimit = 5
}

if (-not $script:LoginThrottleClientLimit) {
    $script:LoginThrottleClientLimit = 25
}

if (-not $script:AuthenticatedUserRequestCacheTtlMs) {
    $configuredAuthCacheMs = 0
    $configuredAuthCacheValue = [string]$env:SAPHIR_AUTH_CACHE_MS
    if ([string]::IsNullOrWhiteSpace($configuredAuthCacheValue)) {
        $configuredAuthCacheValue = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_AUTH_CACHE_MS"))
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredAuthCacheValue)) {
        [int]::TryParse($configuredAuthCacheValue, [ref]$configuredAuthCacheMs) | Out-Null
    }

    $script:AuthenticatedUserRequestCacheTtlMs = if ($configuredAuthCacheMs -gt 0) { $configuredAuthCacheMs } else { 10000 }
}

if (-not $script:UserLookupCache) {
    $script:UserLookupCache = $null
}

function Clear-AuthRuntimeCaches {
    $script:AuthenticatedUserRequestCache = @{}
    $script:UserLookupCache = $null
    $script:AuthArrayFileCache = @{}
    $script:ProjectAccessModelCache = @{}
}

function Clear-ProjectAccessRuntimeCaches {
    # Project changes affect authorization projections, but they do not change
    # users.json, sessions.json, or an already authenticated request. Keep those
    # caches warm and discard only the project-derived access models.
    $script:ProjectAccessModelCache = @{}
}

function New-PasswordCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$Iterations = 120000
    )

    $saltBytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
    $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $saltBytes, $Iterations)
    try {
        $hashBytes = $deriveBytes.GetBytes(32)
    }
    finally {
        $deriveBytes.Dispose()
    }

    return [PSCustomObject]@{
        passwordSalt       = [System.Convert]::ToBase64String($saltBytes)
        passwordHash       = [System.Convert]::ToBase64String($hashBytes)
        passwordIterations = $Iterations
        passwordAlgorithm  = "PBKDF2-HMACSHA1"
    }
}

function Test-PasswordCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)]$UserRecord
    )

    if (-not $UserRecord.passwordSalt -or -not $UserRecord.passwordHash) {
        return $false
    }

    $saltBytes = [System.Convert]::FromBase64String([string]$UserRecord.passwordSalt)
    $iterations = if ($UserRecord.passwordIterations) { [int]$UserRecord.passwordIterations } else { 120000 }
    $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $saltBytes, $iterations)
    try {
        $hashBytes = $deriveBytes.GetBytes(32)
    }
    finally {
        $deriveBytes.Dispose()
    }

    return ([System.Convert]::ToBase64String($hashBytes) -eq [string]$UserRecord.passwordHash)
}

function New-RandomToken {
    param([int]$ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = [System.Convert]::ToBase64String($bytes)
    return ($token.TrimEnd("=") -replace "\+", "-" -replace "/", "_")
}

function New-TemporaryPassword {
    # The fixed prefix guarantees the password-policy character classes while
    # the random suffix contributes 144 bits of per-account entropy.
    return ("Sa1!{0}" -f (New-RandomToken -ByteCount 18))
}

function Get-LoginThrottleKeys {
    param(
        $Request,
        [AllowNull()][string]$Username
    )

    $clientAddress = "unknown"
    try {
        if ($null -ne $Request -and $null -ne $Request.RemoteEndPoint -and $null -ne $Request.RemoteEndPoint.Address) {
            $clientAddress = [string]$Request.RemoteEndPoint.Address
        }
    }
    catch {
        # Requests without a usable endpoint share a conservative fallback
        # bucket instead of bypassing throttling.
    }

    $normalizedUsername = ([string]$Username).Trim().ToLowerInvariant()
    return [PSCustomObject]@{
        Principal = "principal|$clientAddress|$normalizedUsername"
        Client    = "client|$clientAddress"
    }
}

function Remove-ExpiredLoginThrottleRecords {
    param([DateTime]$NowUtc = [DateTime]::UtcNow)

    foreach ($key in @($script:LoginThrottleState.Keys)) {
        $record = $script:LoginThrottleState[$key]
        if ($null -eq $record -or
            $null -eq $record.WindowStartedUtc -or
            ([DateTime]$record.WindowStartedUtc).AddSeconds($script:LoginThrottleWindowSeconds) -le $NowUtc) {
            $script:LoginThrottleState.Remove($key)
        }
    }

    # This should never be reached during normal use, but it places an absolute
    # bound on memory if a hostile client continuously invents usernames.
    if ($script:LoginThrottleState.Count -gt 4096) {
        $script:LoginThrottleState = @{}
    }
}

function Get-LoginThrottleDecision {
    param(
        $Request,
        [AllowNull()][string]$Username,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    Remove-ExpiredLoginThrottleRecords -NowUtc $NowUtc
    $keys = Get-LoginThrottleKeys -Request $Request -Username $Username
    $retryAfterSeconds = 0
    foreach ($rule in @(
        [PSCustomObject]@{ Key = [string]$keys.Principal; Limit = [int]$script:LoginThrottlePrincipalLimit },
        [PSCustomObject]@{ Key = [string]$keys.Client; Limit = [int]$script:LoginThrottleClientLimit }
    )) {
        $record = $script:LoginThrottleState[$rule.Key]
        if ($null -eq $record -or [int]$record.Failures -lt [int]$rule.Limit) {
            continue
        }

        $secondsRemaining = [int][Math]::Ceiling(
            (([DateTime]$record.WindowStartedUtc).AddSeconds($script:LoginThrottleWindowSeconds) - $NowUtc).TotalSeconds
        )
        if ($secondsRemaining -gt $retryAfterSeconds) {
            $retryAfterSeconds = $secondsRemaining
        }
    }

    return [PSCustomObject]@{
        Allowed           = $retryAfterSeconds -le 0
        RetryAfterSeconds = [Math]::Max(1, $retryAfterSeconds)
    }
}

function Register-FailedLoginAttempt {
    param(
        $Request,
        [AllowNull()][string]$Username,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    Remove-ExpiredLoginThrottleRecords -NowUtc $NowUtc
    $keys = Get-LoginThrottleKeys -Request $Request -Username $Username
    foreach ($key in @([string]$keys.Principal, [string]$keys.Client)) {
        $record = $script:LoginThrottleState[$key]
        if ($null -eq $record) {
            $script:LoginThrottleState[$key] = [PSCustomObject]@{
                WindowStartedUtc = $NowUtc
                Failures         = 1
            }
        }
        else {
            $record.Failures = [int]$record.Failures + 1
        }
    }
}

function Clear-LoginThrottleForPrincipal {
    param(
        $Request,
        [AllowNull()][string]$Username
    )

    $keys = Get-LoginThrottleKeys -Request $Request -Username $Username
    if ($script:LoginThrottleState.ContainsKey([string]$keys.Principal)) {
        $script:LoginThrottleState.Remove([string]$keys.Principal)
    }
}

function Get-DummyLoginCredential {
    if ($null -eq $script:DummyLoginCredential) {
        $script:DummyLoginCredential = New-PasswordCredential -Password (New-TemporaryPassword)
    }
    return $script:DummyLoginCredential
}

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

function Get-UserEmployeeCodeValue {
    param($UserRecord)

    if ($null -eq $UserRecord) {
        return ""
    }

    if ($UserRecord.PSObject.Properties.Name -contains "employeeCode" -and -not [string]::IsNullOrWhiteSpace([string]$UserRecord.employeeCode)) {
        return [string]$UserRecord.employeeCode
    }

    if ($UserRecord.PSObject.Properties.Name -contains "username" -and [string]$UserRecord.username -match "^\d+$") {
        return [string]$UserRecord.username
    }

    return ""
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

function Set-AuthRecordProperty {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Record.PSObject.Properties.Name -contains $Name) {
        $Record.PSObject.Properties[$Name].Value = $Value
    }
    else {
        $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

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

function ConvertTo-Gc179PositionText {
    param([AllowNull()][string]$Value)

    $normalized = (([string]$Value).Trim().ToUpperInvariant() -replace "[\s_-]", "")
    if ($normalized -eq "CR04" -or $normalized -eq "CR4") {
        return "CR4"
    }
    if ($normalized -eq "AS03" -or $normalized -eq "AS3") {
        return "AS03"
    }
    if ($normalized -eq "AS04" -or $normalized -eq "AS4") {
        return "AS04"
    }

    return ""
}

function ConvertTo-Gc179EchelonText {
    param([AllowNull()][string]$Value)

    $normalized = ([string]$Value).Trim()
    if ($normalized -eq "1" -or $normalized -eq "2" -or $normalized -eq "3" -or $normalized -eq "4") {
        return $normalized
    }

    return ""
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

    $level = Get-ObjectStringProperty -Value $Value -Name "level"
    if ([string]::IsNullOrWhiteSpace($level)) {
        $level = Get-ObjectStringProperty -Value $Value -Name "Level"
    }
    if ([string]::IsNullOrWhiteSpace($level)) {
        $level = Get-ObjectStringProperty -Value $Value -Name "echelon"
    }
    if ([string]::IsNullOrWhiteSpace($level)) {
        $level = Get-ObjectStringProperty -Value $Value -Name "Echelon"
    }

    $position = Get-ObjectStringProperty -Value $Value -Name "position"
    if ([string]::IsNullOrWhiteSpace($position)) {
        $position = Get-ObjectStringProperty -Value $Value -Name "Position"
    }
    if ([string]::IsNullOrWhiteSpace($position)) {
        $position = Get-ObjectStringProperty -Value $Value -Name "poste"
    }
    if ([string]::IsNullOrWhiteSpace($position)) {
        $position = Get-ObjectStringProperty -Value $Value -Name "classification"
    }

    $compressedWorkWeekValue = Get-ObjectPropertyValue -Value $Value -Name "compressedWorkWeek"
    if ($null -eq $compressedWorkWeekValue) {
        $compressedWorkWeekValue = Get-ObjectPropertyValue -Value $Value -Name "isCompressedWorkWeek"
    }
    if ($null -eq $compressedWorkWeekValue) {
        $compressedWorkWeekValue = Get-ObjectPropertyValue -Value $Value -Name "compressed"
    }
    $compressedWorkWeek = ConvertTo-Gc179BooleanValue -Value $compressedWorkWeekValue -DefaultValue $false

    return [PSCustomObject]@{
        surname            = ConvertTo-Gc179UpperText -Value $surname
        givenName          = ConvertTo-Gc179UpperText -Value $givenName
        initials           = ConvertTo-Gc179UpperText -Value $initials
        pri                = ConvertTo-Gc179PriText -Value $pri
        position           = ConvertTo-Gc179PositionText -Value $position
        level              = ConvertTo-Gc179EchelonText -Value $level
        compressedWorkWeek = [bool]$compressedWorkWeek
    }
}

function Get-Gc179ProfileFromUserRecord {
    param($UserRecord)

    if ($null -eq $UserRecord) {
        return (ConvertTo-Gc179ProfileObject -Value $null -DisplayName "")
    }

    $profile = $null
    if ($UserRecord.PSObject.Properties.Name -contains "gc179Profile") {
        $profile = $UserRecord.gc179Profile
    }

    $displayName = if ($UserRecord.PSObject.Properties.Name -contains "displayName") { [string]$UserRecord.displayName } else { "" }
    return (ConvertTo-Gc179ProfileObject -Value $profile -DisplayName $displayName)
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

function Get-EmployeeTimeEntryTypesByCode {
    param([string]$EmployeeCode)

    if ([string]::IsNullOrWhiteSpace($EmployeeCode)) {
        return @("overtime")
    }

    $user = Get-EmployeeUserByCode -EmployeeCode $EmployeeCode
    return @(Get-EmployeeTimeEntryTypesFromUserRecord -UserRecord $user)
}

function Test-EmployeeCanPunchEntryType {
    param(
        [string]$EmployeeCode,
        [string]$EntryType
    )

    $normalizedEntryType = ([string]$EntryType).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedEntryType)) {
        $normalizedEntryType = "overtime"
    }

    return (@(Get-EmployeeTimeEntryTypesByCode -EmployeeCode $EmployeeCode) -contains $normalizedEntryType)
}

function Get-EffectiveUserRole {
    param($UserRecord)

    if ($null -eq $UserRecord) {
        return "employee"
    }

    $role = Get-NormalizedRoleName -Role ([string]$UserRecord.role)
    $employeeCode = Get-UserEmployeeCodeValue -UserRecord $UserRecord

    # Older data may contain the named bootstrap account with the legacy
    # "admin" role. Keep that one explicit compatibility case, but never turn
    # an arbitrary incomplete admin record into a super administrator.
    if ($role -eq "admin" -and [string]$UserRecord.username -eq $bootstrapAdminUsername) {
        return "superAdmin"
    }

    return $role
}

function Test-EmployeeUserRecord {
    param(
        $UserRecord,
        [string]$EmployeeCode
    )

    if ($null -eq $UserRecord) {
        return $false
    }

    $recordEmployeeCode = Get-UserEmployeeCodeValue -UserRecord $UserRecord
    if ([string]::IsNullOrWhiteSpace($recordEmployeeCode)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($EmployeeCode) -and $recordEmployeeCode -ne $EmployeeCode) {
        return $false
    }

    return $true
}

function New-AuthenticatedUserProjection {
    param(
        $UserRecord,
        [string]$Token
    )

    $employeeCode = Get-UserEmployeeCodeValue -UserRecord $UserRecord
    $role = Get-EffectiveUserRole -UserRecord $UserRecord

    return [PSCustomObject]@{
        username           = [string]$UserRecord.username
        displayName        = [string]$UserRecord.displayName
        role               = $role
        employeeCode       = $employeeCode
        mustChangePassword = [bool]$UserRecord.mustChangePassword
        timeEntryTypes     = @(Get-EmployeeTimeEntryTypesFromUserRecord -UserRecord $UserRecord)
        gc179Profile       = Get-Gc179ProfileFromUserRecord -UserRecord $UserRecord
        token              = $Token
    }
}

function Get-ProjectCodesForCurrentUser {
    param($CurrentUser)

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    return @($accessModel.ProjectCodes)
}

function Get-ProjectCodesCurrentUserCanModify {
    param($CurrentUser)

    $accessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    return @($accessModel.ProjectCodes)
}

function Get-ProjectAccessCacheVersionKey {
    $metadata = Get-FileMetadataSnapshot -Path $projectsFile
    if ($null -eq $metadata) {
        return "missing"
    }

    return ("{0}:{1}" -f $metadata.LastWriteTicks, $metadata.Length)
}

function Get-ProjectAccessCacheUserKey {
    param($CurrentUser)

    if ($null -eq $CurrentUser) {
        return "anonymous"
    }

    $role = Get-NormalizedRoleName -Role ([string]$CurrentUser.role)
    $employeeCode = if ($CurrentUser.PSObject.Properties.Name -contains "employeeCode") { [string]$CurrentUser.employeeCode } else { "" }
    $username = if ($CurrentUser.PSObject.Properties.Name -contains "username") { [string]$CurrentUser.username } else { "" }
    return ("{0}|{1}|{2}" -f $role, $employeeCode, $username)
}

function New-ProjectAccessModel {
    param($Projects)

    $projectList = @($Projects)
    $projectCodes = @(
        $projectList |
            ForEach-Object { [string]$_.projectCode } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    $projectCodeSet = @{}
    foreach ($projectCode in $projectCodes) {
        $projectCodeSet[[string]$projectCode] = $true
    }

    return [PSCustomObject]@{
        Projects     = $projectList
        ProjectCodes = $projectCodes
        ProjectCodeSet = $projectCodeSet
    }
}

function Get-ProjectAccessModelForCurrentUser {
    param($CurrentUser)

    if ($null -eq $CurrentUser) {
        return (New-ProjectAccessModel -Projects @())
    }

    $cacheKey = "view|{0}|{1}" -f (Get-ProjectAccessCacheVersionKey), (Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser)
    if ($script:ProjectAccessModelCache.ContainsKey($cacheKey)) {
        return $script:ProjectAccessModelCache[$cacheKey]
    }

    if ($script:ProjectAccessModelCache.Count -gt 64) {
        $script:ProjectAccessModelCache = @{}
    }

    $projects = @(Get-Projects)
    $role = Get-NormalizedRoleName -Role ([string]$CurrentUser.role)
    if ($role -eq "superAdmin" -or $role -eq "admin") {
        $model = New-ProjectAccessModel -Projects $projects
        $script:ProjectAccessModelCache[$cacheKey] = $model
        return $model
    }

    $model = New-ProjectAccessModel -Projects @()
    $script:ProjectAccessModelCache[$cacheKey] = $model
    return $model
}

function Get-ProjectModificationAccessModelForCurrentUser {
    param($CurrentUser)

    if ($null -eq $CurrentUser) {
        return (New-ProjectAccessModel -Projects @())
    }

    $cacheKey = "modify|{0}|{1}" -f (Get-ProjectAccessCacheVersionKey), (Get-ProjectAccessCacheUserKey -CurrentUser $CurrentUser)
    if ($script:ProjectAccessModelCache.ContainsKey($cacheKey)) {
        return $script:ProjectAccessModelCache[$cacheKey]
    }

    if ($script:ProjectAccessModelCache.Count -gt 64) {
        $script:ProjectAccessModelCache = @{}
    }

    $projects = @(Get-Projects)
    $role = Get-NormalizedRoleName -Role ([string]$CurrentUser.role)
    if ($role -eq "superAdmin") {
        $model = New-ProjectAccessModel -Projects $projects
        $script:ProjectAccessModelCache[$cacheKey] = $model
        return $model
    }

    if ($role -ne "admin" -or [string]::IsNullOrWhiteSpace([string]$CurrentUser.employeeCode)) {
        $model = New-ProjectAccessModel -Projects @()
        $script:ProjectAccessModelCache[$cacheKey] = $model
        return $model
    }

    $employeeCode = [string]$CurrentUser.employeeCode
    $modifiableProjects = @()
    foreach ($project in $projects) {
        $admins = @(Get-ProjectAdminCodes -Project $project)
        $backupAdmins = @(Get-ProjectBackupAdminCodes -Project $project)
        if ($admins -contains $employeeCode -or $backupAdmins -contains $employeeCode) {
            $modifiableProjects += $project
        }
    }

    $model = New-ProjectAccessModel -Projects $modifiableProjects
    $script:ProjectAccessModelCache[$cacheKey] = $model
    return $model
}

function Test-CurrentUserSuperAdmin {
    param($CurrentUser)

    if ($null -eq $CurrentUser) {
        return $false
    }

    return ((Get-NormalizedRoleName -Role ([string]$CurrentUser.role)) -eq "superAdmin")
}

function Test-CurrentUserManager {
    param($CurrentUser)

    if ($null -eq $CurrentUser) {
        return $false
    }

    $role = Get-NormalizedRoleName -Role ([string]$CurrentUser.role)
    return ($role -eq "admin" -or $role -eq "superAdmin")
}

function Test-CurrentUserMatchesEmployeeCode {
    param(
        $CurrentUser,
        [string]$EmployeeCode
    )

    if ($null -eq $CurrentUser -or [string]::IsNullOrWhiteSpace($EmployeeCode)) {
        return $false
    }

    $currentEmployeeCode = if ($CurrentUser.PSObject.Properties.Name -contains "employeeCode") { [string]$CurrentUser.employeeCode } else { "" }
    if ([string]::IsNullOrWhiteSpace($currentEmployeeCode)) {
        return $false
    }

    return ($currentEmployeeCode.Trim() -eq $EmployeeCode.Trim())
}

function Test-CurrentUserCanAccessProjectCode {
    param(
        $CurrentUser,
        [string]$ProjectCode
    )

    if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($ProjectCode)) {
        return $false
    }

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    return $accessModel.ProjectCodeSet.ContainsKey([string]$ProjectCode)
}

function Test-CurrentUserCanModifyProjectCode {
    param(
        $CurrentUser,
        [string]$ProjectCode
    )

    if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($ProjectCode)) {
        return $false
    }

    $accessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    return $accessModel.ProjectCodeSet.ContainsKey([string]$ProjectCode)
}

function Test-CurrentUserCanModifyActiveProjectCodeFromDisk {
    param(
        $CurrentUser,
        [string]$ProjectCode
    )

    $candidate = ([string]$ProjectCode).Trim()
    if ($null -eq $CurrentUser -or [string]::IsNullOrWhiteSpace($candidate)) {
        return $false
    }

    $role = Get-NormalizedRoleName -Role ([string]$CurrentUser.role)
    $employeeCode = if ($CurrentUser.PSObject.Properties.Name -contains "employeeCode") {
        ([string]$CurrentUser.employeeCode).Trim()
    }
    else {
        ""
    }

    foreach ($project in @(Read-ProjectsFromDisk)) {
        if ([string]$project.projectCode -ne $candidate -or (Test-ProjectArchived -Project $project)) {
            continue
        }

        if ($role -eq "superAdmin") {
            return $true
        }
        if ($role -ne "admin" -or [string]::IsNullOrWhiteSpace($employeeCode)) {
            return $false
        }

        return (@(Get-ProjectAdminCodes -Project $project) -contains $employeeCode -or
            @(Get-ProjectBackupAdminCodes -Project $project) -contains $employeeCode)
    }

    return $false
}

function Test-CurrentUserCanManageEntry {
    param(
        $CurrentUser,
        $Entry
    )

    if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) {
        return $true
    }

    if ($null -eq $Entry) {
        return $false
    }

    $entryType = if ($Entry.PSObject.Properties.Name -contains "entryType") { ([string]$Entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }
    if ($entryType -eq "diverse") {
        return $false
    }

    $projectCode = if ($Entry.PSObject.Properties.Name -contains "projectCode") { [string]$Entry.projectCode } else { "" }
    return (Test-CurrentUserCanModifyProjectCode -CurrentUser $CurrentUser -ProjectCode $projectCode)
}

function Test-CurrentUserCanApproveEmployeeRole {
    param(
        $CurrentUser,
        [string]$EmployeeRole
    )

    if (-not (Test-CurrentUserManager -CurrentUser $CurrentUser)) {
        return $false
    }

    $normalizedEmployeeRole = Get-NormalizedRoleName -Role $EmployeeRole
    if ($normalizedEmployeeRole -eq "admin" -or $normalizedEmployeeRole -eq "superAdmin") {
        return (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser)
    }

    return $true
}

function Get-EmployeeRoleByCode {
    param([string]$EmployeeCode)

    if ([string]::IsNullOrWhiteSpace($EmployeeCode)) {
        return "employee"
    }

    $user = Get-EmployeeUserByCode -EmployeeCode $EmployeeCode
    if ($null -eq $user) {
        return "employee"
    }

    return (Get-EffectiveUserRole -UserRecord $user)
}

function Test-EmployeeCodeHasAdminRole {
    param([string]$EmployeeCode)

    $role = Get-EmployeeRoleByCode -EmployeeCode $EmployeeCode
    return ($role -eq "admin" -or $role -eq "superAdmin")
}

function Get-ProjectsForCurrentUser {
    param($CurrentUser)

    $accessModel = Get-ProjectAccessModelForCurrentUser -CurrentUser $CurrentUser
    $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $CurrentUser
    $projects = @()
    foreach ($project in @($accessModel.Projects)) {
        $projectCode = [string]$project.projectCode
        $projects += [PSCustomObject]@{
            projectCode  = $projectCode
            projectName  = [string]$project.projectName
            sector       = if ($project.PSObject.Properties.Name -contains "sector") { [string]$project.sector } else { "" }
            admins       = @(Get-ProjectAdminCodes -Project $project)
            backupAdmins = @(Get-ProjectBackupAdminCodes -Project $project)
            archived     = Test-ProjectArchived -Project $project
            canModify    = [bool]$modifyAccessModel.ProjectCodeSet.ContainsKey($projectCode)
        }
    }

    return @($projects)
}

function Get-TokenHash {
    param([Parameter(Mandatory = $true)][string]$Token)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Token))
    }
    finally {
        $sha.Dispose()
    }
    return (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Test-AuthJsonArrayNeedsInitialization {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$InitializeEmptyArray = $false
    )

    if (!(Test-Path -Path $Path)) {
        return $true
    }

    try {
        $raw = Read-TextFileCached -Path $Path
    }
    catch {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "null") {
        return $true
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $false
    }

    if ($null -eq $parsed) {
        return $true
    }

    if ($InitializeEmptyArray) {
        return (@($parsed).Count -eq 0)
    }

    return $false
}

function Ensure-AuthStorage {
    if ($script:AuthStorageEnsured) {
        return
    }

    $sessionsLock = Acquire-ResourceLock -ResourcePath $sessionsFile
    try {
        if (Test-AuthJsonArrayNeedsInitialization -Path $sessionsFile) {
            Write-JsonArrayAtomic -Path $sessionsFile -Items @()
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $sessionsLock
    }

    $usersLock = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        if (Test-AuthJsonArrayNeedsInitialization -Path $usersFile -InitializeEmptyArray $true) {
            $users = @()
            $adminSecret = New-PasswordCredential -Password $bootstrapAdminPassword
            $users += [PSCustomObject]@{
                username           = $bootstrapAdminUsername
                displayName        = "Administrator"
                role               = "superAdmin"
                employeeCode       = $null
                disabled           = $false
                mustChangePassword = $true
                createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
                passwordSalt       = $adminSecret.passwordSalt
                passwordHash       = $adminSecret.passwordHash
                passwordIterations = $adminSecret.passwordIterations
                passwordAlgorithm  = $adminSecret.passwordAlgorithm
            }

            $employeeNames = Get-EmployeeNameMap
            foreach ($code in ($employeeNames.PSObject.Properties.Name | Sort-Object)) {
                $secret = New-PasswordCredential -Password $code
                $users += [PSCustomObject]@{
                    username           = $code
                    displayName        = [string]$employeeNames.$code
                    role               = "employee"
                    employeeCode       = $code
                    disabled           = $false
                    mustChangePassword = $true
                    createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
                    passwordSalt       = $secret.passwordSalt
                    passwordHash       = $secret.passwordHash
                    passwordIterations = $secret.passwordIterations
                    passwordAlgorithm  = $secret.passwordAlgorithm
                }
            }

            Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 8
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $usersLock
    }

    $script:AuthStorageEnsured = $true
}

function Read-AuthArrayFileCached {
    param([Parameter(Mandatory = $true)][string]$Path)

    $metadata = Get-FileMetadataSnapshot -Path $Path
    if ($null -eq $metadata) {
        if ($script:AuthArrayFileCache.ContainsKey($Path)) {
            $script:AuthArrayFileCache.Remove($Path) | Out-Null
        }
        return @()
    }

    $cacheKey = [string]$metadata.Path
    $cacheEntry = $script:AuthArrayFileCache[$cacheKey]
    if ($cacheEntry -and $cacheEntry.LastWriteTicks -eq $metadata.LastWriteTicks -and $cacheEntry.Length -eq $metadata.Length) {
        return $cacheEntry.Items
    }

    $items = @(Read-JsonArrayFile -Path $metadata.Path)
    $script:AuthArrayFileCache[$cacheKey] = [PSCustomObject]@{
        LastWriteTicks = $metadata.LastWriteTicks
        Length         = $metadata.Length
        Items          = $items
    }
    return $items
}

function Get-Users {
    return @((Get-UserLookupCache).Users)
}

function Get-Sessions {
    Ensure-AuthStorage
    return (Read-AuthArrayFileCached -Path $sessionsFile)
}

function Get-UserLookupCache {
    Ensure-AuthStorage

    $metadata = Get-FileMetadataSnapshot -Path $usersFile
    $cacheKey = if ($null -ne $metadata) { "{0}:{1}" -f $metadata.LastWriteTicks, $metadata.Length } else { "missing" }
    if ($script:UserLookupCache -and $script:UserLookupCache.Key -eq $cacheKey) {
        return $script:UserLookupCache
    }

    $users = @(Read-AuthArrayFileCached -Path $usersFile)
    $byUsername = @{}
    $byEmployeeCode = @{}

    foreach ($user in $users) {
        if ($null -eq $user) {
            continue
        }

        $username = if ($user.PSObject.Properties.Name -contains "username") { [string]$user.username } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($username) -and -not $byUsername.ContainsKey($username)) {
            $byUsername[$username] = $user
        }

        $employeeCode = Get-UserEmployeeCodeValue -UserRecord $user
        if (-not [string]::IsNullOrWhiteSpace($employeeCode) -and -not $byEmployeeCode.ContainsKey($employeeCode)) {
            $byEmployeeCode[$employeeCode] = $user
        }
    }

    $script:UserLookupCache = [PSCustomObject]@{
        Key            = $cacheKey
        Users          = $users
        ByUsername     = $byUsername
        ByEmployeeCode = $byEmployeeCode
    }
    return $script:UserLookupCache
}

function Get-UserByUsername {
    param([string]$Username)

    if ([string]::IsNullOrWhiteSpace([string]$Username)) {
        return $null
    }

    $lookup = Get-UserLookupCache
    if ($lookup.ByUsername.ContainsKey([string]$Username)) {
        return $lookup.ByUsername[[string]$Username]
    }

    return $null
}

function Get-EmployeeUserByCode {
    param([string]$EmployeeCode)

    if ([string]::IsNullOrWhiteSpace([string]$EmployeeCode)) {
        return $null
    }

    $lookup = Get-UserLookupCache
    if ($lookup.ByEmployeeCode.ContainsKey([string]$EmployeeCode)) {
        return $lookup.ByEmployeeCode[[string]$EmployeeCode]
    }

    return $null
}

function Get-AuthorizationTokenFromRequest {
    param($Request)

    $header = [string]$Request.Headers["Authorization"]
    if (-not [string]::IsNullOrWhiteSpace($header) -and $header -match "^Bearer\s+(.+)$") {
        return $matches[1].Trim()
    }

    return (Get-SessionTokenFromCookieHeader -CookieHeader ([string]$Request.Headers["Cookie"]))
}

function Get-SessionCookieHeader {
    param([Parameter(Mandatory = $true)][string]$Token)

    return ("saphirSession={0}; Path=/; HttpOnly; SameSite=Lax" -f [System.Uri]::EscapeDataString($Token))
}

function Get-ExpiredSessionCookieHeader {
    return "saphirSession=; Path=/; HttpOnly; SameSite=Lax; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
}

function Get-SessionTokenFromCookieHeader {
    param([string]$CookieHeader)

    if ([string]::IsNullOrWhiteSpace($CookieHeader)) {
        return $null
    }

    $cookieParts = @($CookieHeader -split ";")
    foreach ($part in $cookieParts) {
        $trimmedPart = [string]$part
        $trimmedPart = $trimmedPart.Trim()
        $separatorIndex = $trimmedPart.IndexOf("=")
        if ($separatorIndex -lt 1) {
            continue
        }

        $name = $trimmedPart.Substring(0, $separatorIndex).Trim()
        if ($name -ne "saphirSession") {
            continue
        }

        $value = $trimmedPart.Substring($separatorIndex + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        return [System.Uri]::UnescapeDataString($value)
    }

    return $null
}

function Get-AuthSyncVersion {
    # Authentication depends on users.json and sessions.json, not on the
    # global business-data revision. Keying this cache to sync-state.version
    # made every entry/history/project change reread both auth files over SMB.
    # FileStore metadata is itself bounded and is explicitly cleared whenever
    # an auth/directory change is observed, so this key remains current without
    # coupling authentication to unrelated mutations.
    if (Get-Command -Name Get-FileMetadataSnapshot -ErrorAction SilentlyContinue) {
        try {
            $usersMetadata = Get-FileMetadataSnapshot -Path $usersFile
            $sessionsMetadata = Get-FileMetadataSnapshot -Path $sessionsFile
            $usersKey = if ($null -eq $usersMetadata) {
                "missing"
            }
            else {
                "{0}:{1}" -f [string]$usersMetadata.LastWriteTicks, [string]$usersMetadata.Length
            }
            $sessionsKey = if ($null -eq $sessionsMetadata) {
                "missing"
            }
            else {
                "{0}:{1}" -f [string]$sessionsMetadata.LastWriteTicks, [string]$sessionsMetadata.Length
            }
            return "files|$usersKey|$sessionsKey"
        }
        catch {
            # A transient metadata failure falls back to the existing sync
            # identity. The short authenticated-request TTL still bounds reuse.
        }
    }

    if (Get-Command -Name Get-SyncState -ErrorAction SilentlyContinue) {
        try {
            $state = Get-SyncState
            if ($null -ne $state -and $state.PSObject.Properties.Name -contains "version") {
                return "sync|$([string]$state.version)"
            }
        }
        catch {
            # Fall back to the short local TTL when metadata and sync state are
            # both unavailable.
        }
    }

    return ""
}

function Get-AuthenticatedUserFromRequest {
    param($Request)

    $token = Get-AuthorizationTokenFromRequest -Request $Request
    if ([string]::IsNullOrWhiteSpace($token)) {
        return $null
    }

    $tokenHash = Get-TokenHash -Token $token
    $nowUtc = (Get-Date).ToUniversalTime()
    $authSyncVersion = Get-AuthSyncVersion
    $cachedAuth = $script:AuthenticatedUserRequestCache[$tokenHash]
    if ($cachedAuth -and $cachedAuth.CachedAtUtc -and $cachedAuth.ExpiresAtUtc) {
        $cacheAgeMs = ($nowUtc - $cachedAuth.CachedAtUtc).TotalMilliseconds
        $syncVersionMatches = [string]::IsNullOrWhiteSpace($authSyncVersion) -or
            ([string]$cachedAuth.SyncVersion -eq $authSyncVersion)
        if ($cacheAgeMs -lt $script:AuthenticatedUserRequestCacheTtlMs -and
            $cachedAuth.ExpiresAtUtc -gt $nowUtc -and
            $syncVersionMatches) {
            return $cachedAuth.User
        }

        if (-not $syncVersionMatches) {
            # Another backend published an auth change. Force the next lookup
            # through current sessions/users data instead of 30-second metadata.
            Clear-CachedFileContent -Path $sessionsFile
            Clear-CachedFileContent -Path $usersFile
            $script:AuthArrayFileCache = @{}
            $script:UserLookupCache = $null
            $script:ProjectAccessModelCache = @{}
        }
    }

    $session = $null
    foreach ($candidateSession in @(Get-Sessions)) {
        if ([string]$candidateSession.tokenHash -ne $tokenHash) {
            continue
        }

        try {
            $sessionExpiresUtc = [DateTime]::Parse([string]$candidateSession.expiresAtUtc).ToUniversalTime()
        }
        catch {
            continue
        }

        if ($sessionExpiresUtc -le $nowUtc) {
            continue
        }

        $session = $candidateSession
        break
    }

    if ($null -eq $session) {
        if ($script:AuthenticatedUserRequestCache.ContainsKey($tokenHash)) {
            $script:AuthenticatedUserRequestCache.Remove($tokenHash) | Out-Null
        }
        return $null
    }

    $user = Get-UserByUsername -Username ([string]$session.username)
    if ($null -eq $user) {
        return $null
    }
    if ([bool]$user.disabled) {
        return $null
    }

    $projection = New-AuthenticatedUserProjection -UserRecord $user -Token $token
    $script:AuthenticatedUserRequestCache[$tokenHash] = [PSCustomObject]@{
        CachedAtUtc  = $nowUtc
        ExpiresAtUtc = [DateTime]::Parse([string]$session.expiresAtUtc).ToUniversalTime()
        SyncVersion  = $authSyncVersion
        User         = $projection
    }

    if ($script:AuthenticatedUserRequestCache.Count -gt 128) {
        $script:AuthenticatedUserRequestCache = @{}
    }

    return $projection
}

function Test-CurrentUserRole {
    param(
        $CurrentUser,
        [string[]]$AllowedRoles
    )

    if ($null -eq $CurrentUser) {
        return $false
    }
    return ($AllowedRoles -contains (Get-NormalizedRoleName -Role ([string]$CurrentUser.role)))
}

function New-SessionForUser {
    param($UserRecord)

    $token = New-RandomToken
    $nowUtc = (Get-Date).ToUniversalTime()
    $expiresUtc = $nowUtc.AddHours(12)

    $lockHandle = Acquire-ResourceLock -ResourcePath $sessionsFile
    try {
        $sessions = @(Read-JsonArrayFile -Path $sessionsFile | Where-Object {
            try {
                [DateTime]::Parse($_.expiresAtUtc).ToUniversalTime() -gt $nowUtc
            }
            catch {
                $false
            }
        })
        $sessions += [PSCustomObject]@{
            username     = [string]$UserRecord.username
            role         = Get-EffectiveUserRole -UserRecord $UserRecord
            employeeCode = Get-UserEmployeeCodeValue -UserRecord $UserRecord
            tokenHash    = (Get-TokenHash -Token $token)
            issuedAtUtc  = $nowUtc.ToString("o")
            expiresAtUtc = $expiresUtc.ToString("o")
        }
        Write-JsonArrayAtomic -Path $sessionsFile -Items $sessions -Depth 8
        Clear-AuthRuntimeCaches
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $token
}

function Revoke-SessionToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return
    }

    $tokenHash = Get-TokenHash -Token $Token
    $lockHandle = Acquire-ResourceLock -ResourcePath $sessionsFile
    try {
        $sessions = @(Read-JsonArrayFile -Path $sessionsFile)
        $sessions = @($sessions | Where-Object { $_.tokenHash -ne $tokenHash })
        Write-JsonArrayAtomic -Path $sessionsFile -Items $sessions -Depth 8
        Clear-AuthRuntimeCaches
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

function Revoke-SessionsForUsername {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [string]$ExcludeToken
    )

    $excludeTokenHash = $null
    if (-not [string]::IsNullOrWhiteSpace($ExcludeToken)) {
        $excludeTokenHash = Get-TokenHash -Token $ExcludeToken
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $sessionsFile
    try {
        $sessions = @(Read-JsonArrayFile -Path $sessionsFile)
        $sessions = @($sessions | Where-Object {
            if ($_.username -ne $Username) {
                return $true
            }

            if ($excludeTokenHash -and $_.tokenHash -eq $excludeTokenHash) {
                return $true
            }

            return $false
        })
        Write-JsonArrayAtomic -Path $sessionsFile -Items $sessions -Depth 8
        Clear-AuthRuntimeCaches
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

function Set-UserPassword {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$NewPassword,
        [bool]$MustChangePassword = $false
    )

    $secret = New-PasswordCredential -Password $NewPassword
    $updated = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = @(Read-JsonArrayFile -Path $usersFile)
        foreach ($user in $users) {
            if ($user.username -eq $Username) {
                Set-AuthRecordProperty -Record $user -Name "passwordSalt" -Value $secret.passwordSalt
                Set-AuthRecordProperty -Record $user -Name "passwordHash" -Value $secret.passwordHash
                Set-AuthRecordProperty -Record $user -Name "passwordIterations" -Value $secret.passwordIterations
                Set-AuthRecordProperty -Record $user -Name "passwordAlgorithm" -Value $secret.passwordAlgorithm
                Set-AuthRecordProperty -Record $user -Name "mustChangePassword" -Value $MustChangePassword
                $updated = $true
                break
            }
        }
        if ($updated) {
            Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 8
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updated
}

function Set-EmployeeUserPassword {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$NewPassword,
        [bool]$MustChangePassword = $true
    )

    $secret = New-PasswordCredential -Password $NewPassword
    $updated = $false
    $created = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = @(Read-JsonArrayFile -Path $usersFile)
        $targetUser = $users | Where-Object { $_.username -eq $EmployeeCode } | Select-Object -First 1

        if ($null -eq $targetUser) {
            $displayName = [string](Get-EmployeeName $EmployeeCode)
            $users += [PSCustomObject]@{
                username           = $EmployeeCode
                displayName        = $displayName
                role               = "employee"
                employeeCode       = $EmployeeCode
                gc179Profile       = ConvertTo-Gc179ProfileObject -Value $null -DisplayName $displayName
                disabled           = $false
                mustChangePassword = $MustChangePassword
                createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
                passwordSalt       = $secret.passwordSalt
                passwordHash       = $secret.passwordHash
                passwordIterations = $secret.passwordIterations
                passwordAlgorithm  = $secret.passwordAlgorithm
            }
            $updated = $true
            $created = $true
        }
        elseif (-not (Test-EmployeeUserRecord -UserRecord $targetUser -EmployeeCode $EmployeeCode)) {
            return [PSCustomObject]@{
                updated = $false
                created = $false
                error   = "The target account is not an employee account."
            }
        }
        else {
            Set-AuthRecordProperty -Record $targetUser -Name "displayName" -Value ([string](Get-EmployeeName $EmployeeCode))
            Set-AuthRecordProperty -Record $targetUser -Name "employeeCode" -Value $EmployeeCode
            Set-AuthRecordProperty -Record $targetUser -Name "passwordSalt" -Value $secret.passwordSalt
            Set-AuthRecordProperty -Record $targetUser -Name "passwordHash" -Value $secret.passwordHash
            Set-AuthRecordProperty -Record $targetUser -Name "passwordIterations" -Value $secret.passwordIterations
            Set-AuthRecordProperty -Record $targetUser -Name "passwordAlgorithm" -Value $secret.passwordAlgorithm
            Set-AuthRecordProperty -Record $targetUser -Name "mustChangePassword" -Value $MustChangePassword
            $updated = $true
        }

        if ($updated) {
            Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 8
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return [PSCustomObject]@{
        updated = $updated
        created = $created
        error   = $null
    }
}

function Ensure-EmployeeUser {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$InitialPassword,
        [bool]$MustChangePassword = $true,
        [string]$Role = "employee",
        $TimeEntryTypes = @("overtime"),
        $Gc179Profile = $null
    )

    $effectivePassword = if ([string]::IsNullOrWhiteSpace($InitialPassword)) {
        New-TemporaryPassword
    }
    else {
        $InitialPassword
    }

    $policyError = Test-NewPasswordPolicy -Password $effectivePassword
    if ($policyError) {
        return [PSCustomObject]@{
            updated           = $false
            created           = $false
            reactivated       = $false
            error             = $policyError
            temporaryPassword = $null
        }
    }

    $secret = New-PasswordCredential -Password $effectivePassword
    $updated = $false
    $created = $false
    $reactivated = $false
    $effectiveRole = Get-NormalizedRoleName -Role $Role
    $effectiveTimeEntryTypes = @(ConvertTo-TimeEntryTypeArray -Value $TimeEntryTypes)
    $effectiveGc179Profile = ConvertTo-Gc179ProfileObject -Value $Gc179Profile -DisplayName $DisplayName

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = @(Read-JsonArrayFile -Path $usersFile)
        $targetUser = $users | Where-Object { $_.username -eq $EmployeeCode } | Select-Object -First 1

        if ($null -eq $targetUser) {
            $users += [PSCustomObject]@{
                username           = $EmployeeCode
                displayName        = [string]$DisplayName
                role               = $effectiveRole
                employeeCode       = $EmployeeCode
                timeEntryTypes     = $effectiveTimeEntryTypes
                gc179Profile       = $effectiveGc179Profile
                disabled           = $false
                mustChangePassword = $MustChangePassword
                createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
                passwordSalt       = $secret.passwordSalt
                passwordHash       = $secret.passwordHash
                passwordIterations = $secret.passwordIterations
                passwordAlgorithm  = $secret.passwordAlgorithm
            }
            $updated = $true
            $created = $true
        }
        elseif (-not (Test-EmployeeUserRecord -UserRecord $targetUser -EmployeeCode $EmployeeCode)) {
            return [PSCustomObject]@{
                updated           = $false
                created           = $false
                reactivated       = $false
                error             = "The target account is not an employee account."
                temporaryPassword = $null
            }
        }
        elseif (-not [bool]$targetUser.disabled) {
            return [PSCustomObject]@{
                updated           = $false
                created           = $false
                reactivated       = $false
                error             = "An active employee account already exists for this code."
                temporaryPassword = $null
            }
        }
        else {
            Set-AuthRecordProperty -Record $targetUser -Name "displayName" -Value ([string]$DisplayName)
            Set-AuthRecordProperty -Record $targetUser -Name "employeeCode" -Value $EmployeeCode
            Set-AuthRecordProperty -Record $targetUser -Name "role" -Value $effectiveRole
            if ($targetUser.PSObject.Properties.Name -contains "timeEntryTypes") {
                $targetUser.timeEntryTypes = $effectiveTimeEntryTypes
            }
            else {
                $targetUser | Add-Member -NotePropertyName "timeEntryTypes" -NotePropertyValue $effectiveTimeEntryTypes -Force
            }
            Set-AuthRecordProperty -Record $targetUser -Name "disabled" -Value $false
            if ($targetUser.PSObject.Properties.Name -contains "gc179Profile") {
                $targetUser.gc179Profile = $effectiveGc179Profile
            }
            else {
                $targetUser | Add-Member -NotePropertyName "gc179Profile" -NotePropertyValue $effectiveGc179Profile -Force
            }
            Set-AuthRecordProperty -Record $targetUser -Name "passwordSalt" -Value $secret.passwordSalt
            Set-AuthRecordProperty -Record $targetUser -Name "passwordHash" -Value $secret.passwordHash
            Set-AuthRecordProperty -Record $targetUser -Name "passwordIterations" -Value $secret.passwordIterations
            Set-AuthRecordProperty -Record $targetUser -Name "passwordAlgorithm" -Value $secret.passwordAlgorithm
            Set-AuthRecordProperty -Record $targetUser -Name "mustChangePassword" -Value $MustChangePassword
            $updated = $true
            $reactivated = $true
        }

        if ($updated) {
            Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 8
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return [PSCustomObject]@{
        updated           = $updated
        created           = $created
        reactivated       = $reactivated
        error             = $null
        temporaryPassword = $effectivePassword
    }
}

# Apply all supplied profile fields in one users.json transaction.
function Set-EmployeeUserProfile {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [string]$DisplayName,
        [string]$Role,
        $TimeEntryTypes,
        $Gc179Profile
    )

    $updateDisplayName = $PSBoundParameters.ContainsKey("DisplayName")
    $updateRole = $PSBoundParameters.ContainsKey("Role")
    $updateTimeEntryTypes = $PSBoundParameters.ContainsKey("TimeEntryTypes")
    $updateGc179Profile = $PSBoundParameters.ContainsKey("Gc179Profile")
    if (-not ($updateDisplayName -or $updateRole -or $updateTimeEntryTypes -or $updateGc179Profile)) {
        return $false
    }

    $effectiveRole = if ($updateRole) { Get-NormalizedRoleName -Role $Role } else { $null }
    $effectiveTimeEntryTypes = $null
    if ($updateTimeEntryTypes) {
        $effectiveTimeEntryTypes = @(ConvertTo-TimeEntryTypeArray -Value $TimeEntryTypes)
    }
    $updated = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        # The resource lock coordinates writers, but another process may have
        # committed while this process still had an older metadata snapshot.
        Clear-CachedFileContent -Path $usersFile
        $users = @(Read-JsonArrayFile -Path $usersFile)
        foreach ($user in $users) {
            if ($user.username -eq $EmployeeCode -and (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $EmployeeCode)) {
                if ($updateDisplayName) {
                    Set-AuthRecordProperty -Record $user -Name "displayName" -Value ([string]$DisplayName)
                    Set-AuthRecordProperty -Record $user -Name "employeeCode" -Value $EmployeeCode
                }
                if ($updateRole) {
                    Set-AuthRecordProperty -Record $user -Name "role" -Value $effectiveRole
                    Set-AuthRecordProperty -Record $user -Name "employeeCode" -Value $EmployeeCode
                }
                if ($updateTimeEntryTypes) {
                    if ($user.PSObject.Properties.Name -contains "timeEntryTypes") {
                        $user.timeEntryTypes = $effectiveTimeEntryTypes
                    }
                    else {
                        $user | Add-Member -NotePropertyName "timeEntryTypes" -NotePropertyValue $effectiveTimeEntryTypes -Force
                    }
                }
                if ($updateGc179Profile) {
                    $profileDisplayName = if ($updateDisplayName) {
                        [string]$DisplayName
                    }
                    elseif ($user.PSObject.Properties.Name -contains "displayName") {
                        [string]$user.displayName
                    }
                    else {
                        [string](Get-EmployeeName $EmployeeCode)
                    }
                    $effectiveGc179Profile = ConvertTo-Gc179ProfileObject -Value $Gc179Profile -DisplayName $profileDisplayName
                    if ($user.PSObject.Properties.Name -contains "gc179Profile") {
                        $user.gc179Profile = $effectiveGc179Profile
                    }
                    else {
                        $user | Add-Member -NotePropertyName "gc179Profile" -NotePropertyValue $effectiveGc179Profile -Force
                    }
                }

                $updated = $true
                break
            }
        }

        if ($updated) {
            Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 8
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updated
}

function Set-EmployeeUserDisplayName {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    return (Set-EmployeeUserProfile -EmployeeCode $EmployeeCode -DisplayName $DisplayName)
}

function Set-EmployeeUserRole {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$Role
    )

    return (Set-EmployeeUserProfile -EmployeeCode $EmployeeCode -Role $Role)
}

function Set-EmployeeUserTimeEntryTypes {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        $TimeEntryTypes
    )

    return (Set-EmployeeUserProfile -EmployeeCode $EmployeeCode -TimeEntryTypes $TimeEntryTypes)
}

function Set-EmployeeUserGc179Profile {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        $Gc179Profile
    )

    return (Set-EmployeeUserProfile -EmployeeCode $EmployeeCode -Gc179Profile $Gc179Profile)
}

function Disable-EmployeeUser {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $updated = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = @(Read-JsonArrayFile -Path $usersFile)
        foreach ($user in $users) {
            if ($user.username -eq $EmployeeCode -and (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $EmployeeCode)) {
                Set-AuthRecordProperty -Record $user -Name "disabled" -Value $true
                $updated = $true
                break
            }
        }

        if ($updated) {
            Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 8
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updated
}

function Restore-EmployeeUser {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $updated = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = @(Read-JsonArrayFile -Path $usersFile)
        foreach ($user in $users) {
            if ($user.username -eq $EmployeeCode -and (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $EmployeeCode)) {
                Set-AuthRecordProperty -Record $user -Name "disabled" -Value $false
                $updated = $true
                break
            }
        }

        if ($updated) {
            Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 8
            Clear-AuthRuntimeCaches
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updated
}

function Test-NewPasswordPolicy {
    param([string]$Password)

    if ([string]::IsNullOrWhiteSpace($Password) -or $Password.Length -lt 10) {
        return "Password must be at least 10 characters."
    }
    if ($Password -notmatch "[A-Z]") {
        return "Password must include at least one uppercase letter."
    }
    if ($Password -notmatch "[a-z]") {
        return "Password must include at least one lowercase letter."
    }
    if ($Password -notmatch "[0-9]") {
        return "Password must include at least one digit."
    }
    if ($Password -notmatch "[^A-Za-z0-9]") {
        return "Password must include at least one symbol."
    }
    return $null
}

Ensure-AuthStorage
