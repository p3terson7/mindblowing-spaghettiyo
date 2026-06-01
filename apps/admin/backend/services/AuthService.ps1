if ($null -eq $script:AuthStorageEnsured) {
    $script:AuthStorageEnsured = $false
}

if (-not $script:AuthArrayFileCache) {
    $script:AuthArrayFileCache = @{}
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

function Get-EffectiveUserRole {
    param($UserRecord)

    if ($null -eq $UserRecord) {
        return "employee"
    }

    $role = Get-NormalizedRoleName -Role ([string]$UserRecord.role)
    $employeeCode = Get-UserEmployeeCodeValue -UserRecord $UserRecord

    if ($role -eq "admin" -and [string]::IsNullOrWhiteSpace($employeeCode)) {
        return "superAdmin"
    }

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
        token              = $Token
    }
}

function Get-ProjectCodesForCurrentUser {
    param($CurrentUser)

    if ($null -eq $CurrentUser) {
        return @()
    }

    $role = Get-NormalizedRoleName -Role ([string]$CurrentUser.role)
    if ($role -eq "superAdmin") {
        return @((Get-Projects) | ForEach-Object { [string]$_.projectCode } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }

    if ($role -ne "admin" -or [string]::IsNullOrWhiteSpace([string]$CurrentUser.employeeCode)) {
        return @()
    }

    $employeeCode = [string]$CurrentUser.employeeCode
    $projectCodes = @()
    foreach ($project in @(Get-Projects)) {
        $admins = @(Get-ProjectAdminCodes -Project $project)
        $backupAdmins = @(Get-ProjectBackupAdminCodes -Project $project)
        if ($admins -contains $employeeCode -or $backupAdmins -contains $employeeCode) {
            $projectCodes += [string]$project.projectCode
        }
    }

    return @($projectCodes | Sort-Object -Unique)
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

    return (@(Get-ProjectCodesForCurrentUser -CurrentUser $CurrentUser) -contains [string]$ProjectCode)
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

    $projectCode = if ($Entry.PSObject.Properties.Name -contains "projectCode") { [string]$Entry.projectCode } else { "" }
    return (Test-CurrentUserCanAccessProjectCode -CurrentUser $CurrentUser -ProjectCode $projectCode)
}

function Get-ProjectsForCurrentUser {
    param($CurrentUser)

    if (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser) {
        return @(Get-Projects)
    }

    $projectCodes = @(Get-ProjectCodesForCurrentUser -CurrentUser $CurrentUser)
    if ($projectCodes.Count -eq 0) {
        return @()
    }

    return @((Get-Projects) | Where-Object { $projectCodes -contains [string]$_.projectCode })
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

function Ensure-AuthStorage {
    if ($script:AuthStorageEnsured) {
        return
    }

    $sessionsLock = Acquire-ResourceLock -ResourcePath $sessionsFile
    try {
        if (!(Test-Path -Path $sessionsFile)) {
            Write-JsonAtomic -Path $sessionsFile -Value @()
        }
    }
    finally {
        Release-ResourceLock -LockHandle $sessionsLock
    }

    $usersLock = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        if (!(Test-Path -Path $usersFile)) {
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

            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
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

    try {
        $raw = Read-TextFileCached -Path $metadata.Path
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "null") {
            return @()
        }

        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) {
            return @()
        }

        if (-not ($parsed -is [System.Collections.IEnumerable]) -or ($parsed -is [string])) {
            $items = @($parsed)
            $script:AuthArrayFileCache[$cacheKey] = [PSCustomObject]@{
                LastWriteTicks = $metadata.LastWriteTicks
                Length         = $metadata.Length
                Items          = $items
            }
            return $items
        }

        $items = @($parsed)
        $script:AuthArrayFileCache[$cacheKey] = [PSCustomObject]@{
            LastWriteTicks = $metadata.LastWriteTicks
            Length         = $metadata.Length
            Items          = $items
        }
        return $items
    }
    catch {
        return @()
    }
}

function Get-Users {
    Ensure-AuthStorage
    return (Read-AuthArrayFileCached -Path $usersFile)
}

function Get-Sessions {
    Ensure-AuthStorage
    return (Read-AuthArrayFileCached -Path $sessionsFile)
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

    return ("overtimeSession={0}; Path=/; HttpOnly; SameSite=Lax" -f [System.Uri]::EscapeDataString($Token))
}

function Get-ExpiredSessionCookieHeader {
    return "overtimeSession=; Path=/; HttpOnly; SameSite=Lax; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
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
        if ($name -ne "overtimeSession") {
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

function Get-AuthenticatedUserFromRequest {
    param($Request)

    $token = Get-AuthorizationTokenFromRequest -Request $Request
    if ([string]::IsNullOrWhiteSpace($token)) {
        return $null
    }

    $tokenHash = Get-TokenHash -Token $token
    $nowUtc = (Get-Date).ToUniversalTime()
    $session = Get-Sessions | Where-Object {
        $_.tokenHash -eq $tokenHash -and
        [DateTime]::Parse($_.expiresAtUtc).ToUniversalTime() -gt $nowUtc
    } | Select-Object -First 1

    if ($null -eq $session) {
        return $null
    }

    $user = Get-Users | Where-Object { $_.username -eq $session.username -and -not $_.disabled } | Select-Object -First 1
    if ($null -eq $user) {
        return $null
    }

    return (New-AuthenticatedUserProjection -UserRecord $user -Token $token)
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
        Write-JsonAtomic -Path $sessionsFile -Value $sessions -Depth 8
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
        $sessions = Read-JsonArrayFile -Path $sessionsFile
        $sessions = $sessions | Where-Object { $_.tokenHash -ne $tokenHash }
        Write-JsonAtomic -Path $sessionsFile -Value $sessions -Depth 8
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
        $sessions = Read-JsonArrayFile -Path $sessionsFile
        $sessions = @($sessions | Where-Object {
            if ($_.username -ne $Username) {
                return $true
            }

            if ($excludeTokenHash -and $_.tokenHash -eq $excludeTokenHash) {
                return $true
            }

            return $false
        })
        Write-JsonAtomic -Path $sessionsFile -Value $sessions -Depth 8
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
        $users = Read-JsonArrayFile -Path $usersFile
        foreach ($user in $users) {
            if ($user.username -eq $Username) {
                $user.passwordSalt = $secret.passwordSalt
                $user.passwordHash = $secret.passwordHash
                $user.passwordIterations = $secret.passwordIterations
                $user.passwordAlgorithm = $secret.passwordAlgorithm
                $user.mustChangePassword = $MustChangePassword
                $updated = $true
                break
            }
        }
        if ($updated) {
            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
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
        $users = Read-JsonArrayFile -Path $usersFile
        $targetUser = $users | Where-Object { $_.username -eq $EmployeeCode } | Select-Object -First 1

        if ($null -eq $targetUser) {
            $users += [PSCustomObject]@{
                username           = $EmployeeCode
                displayName        = [string](Get-EmployeeName $EmployeeCode)
                role               = "employee"
                employeeCode       = $EmployeeCode
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
            $targetUser.displayName = [string](Get-EmployeeName $EmployeeCode)
            $targetUser.employeeCode = $EmployeeCode
            $targetUser.disabled = $false
            $targetUser.passwordSalt = $secret.passwordSalt
            $targetUser.passwordHash = $secret.passwordHash
            $targetUser.passwordIterations = $secret.passwordIterations
            $targetUser.passwordAlgorithm = $secret.passwordAlgorithm
            $targetUser.mustChangePassword = $MustChangePassword
            $updated = $true
        }

        if ($updated) {
            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
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
        [string]$Role = "employee"
    )

    $effectivePassword = if ([string]::IsNullOrWhiteSpace($InitialPassword)) {
        "Temp!$EmployeeCode"
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

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = Read-JsonArrayFile -Path $usersFile
        $targetUser = $users | Where-Object { $_.username -eq $EmployeeCode } | Select-Object -First 1

        if ($null -eq $targetUser) {
            $users += [PSCustomObject]@{
                username           = $EmployeeCode
                displayName        = [string]$DisplayName
                role               = $effectiveRole
                employeeCode       = $EmployeeCode
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
            $targetUser.displayName = [string]$DisplayName
            $targetUser.employeeCode = $EmployeeCode
            $targetUser.role = $effectiveRole
            $targetUser.disabled = $false
            $targetUser.passwordSalt = $secret.passwordSalt
            $targetUser.passwordHash = $secret.passwordHash
            $targetUser.passwordIterations = $secret.passwordIterations
            $targetUser.passwordAlgorithm = $secret.passwordAlgorithm
            $targetUser.mustChangePassword = $MustChangePassword
            $updated = $true
            $reactivated = $true
        }

        if ($updated) {
            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
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

function Set-EmployeeUserDisplayName {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $updated = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = Read-JsonArrayFile -Path $usersFile
        foreach ($user in $users) {
            if ($user.username -eq $EmployeeCode -and (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $EmployeeCode)) {
                $user.displayName = [string]$DisplayName
                $user.employeeCode = $EmployeeCode
                $updated = $true
                break
            }
        }

        if ($updated) {
            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updated
}

function Set-EmployeeUserRole {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $effectiveRole = Get-NormalizedRoleName -Role $Role
    $updated = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = Read-JsonArrayFile -Path $usersFile
        foreach ($user in $users) {
            if ($user.username -eq $EmployeeCode -and (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $EmployeeCode)) {
                $user.role = $effectiveRole
                $user.employeeCode = $EmployeeCode
                $updated = $true
                break
            }
        }

        if ($updated) {
            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return $updated
}

function Disable-EmployeeUser {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $updated = $false

    $lockHandle = Acquire-ResourceLock -ResourcePath $usersFile
    try {
        $users = Read-JsonArrayFile -Path $usersFile
        foreach ($user in $users) {
            if ($user.username -eq $EmployeeCode -and (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $EmployeeCode)) {
                $user.disabled = $true
                $updated = $true
                break
            }
        }

        if ($updated) {
            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
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
        $users = Read-JsonArrayFile -Path $usersFile
        foreach ($user in $users) {
            if ($user.username -eq $EmployeeCode -and (Test-EmployeeUserRecord -UserRecord $user -EmployeeCode $EmployeeCode)) {
                $user.disabled = $false
                $updated = $true
                break
            }
        }

        if ($updated) {
            Write-JsonAtomic -Path $usersFile -Value $users -Depth 8
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
