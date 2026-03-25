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
        if (Test-Path -Path $usersFile) {
            return
        }

        $users = @()
        $adminSecret = New-PasswordCredential -Password $bootstrapAdminPassword
        $users += [PSCustomObject]@{
            username           = $bootstrapAdminUsername
            displayName        = "Administrator"
            role               = "admin"
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
    finally {
        Release-ResourceLock -LockHandle $usersLock
    }
}

function Get-Users {
    Ensure-AuthStorage
    return (Read-JsonArrayFile -Path $usersFile)
}

function Get-Sessions {
    Ensure-AuthStorage
    return (Read-JsonArrayFile -Path $sessionsFile)
}

function Get-AuthorizationTokenFromRequest {
    param($Request)

    $header = [string]$Request.Headers["Authorization"]
    if ([string]::IsNullOrWhiteSpace($header)) {
        return $null
    }
    if ($header -match "^Bearer\s+(.+)$") {
        return $matches[1].Trim()
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

    return [PSCustomObject]@{
        username           = [string]$user.username
        displayName        = [string]$user.displayName
        role               = [string]$user.role
        employeeCode       = [string]$user.employeeCode
        mustChangePassword = [bool]$user.mustChangePassword
        token              = $token
    }
}

function Test-CurrentUserRole {
    param(
        $CurrentUser,
        [string[]]$AllowedRoles
    )

    if ($null -eq $CurrentUser) {
        return $false
    }
    return ($AllowedRoles -contains [string]$CurrentUser.role)
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
            role         = [string]$UserRecord.role
            employeeCode = [string]$UserRecord.employeeCode
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
        elseif ([string]$targetUser.role -ne "employee") {
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
