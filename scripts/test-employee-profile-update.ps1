$ErrorActionPreference = "Stop"

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Get-Item -Path $scriptRoot).Parent.FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-profile-test-{0}" -f ([Guid]::NewGuid().ToString("N")))

try {
    New-Item -ItemType Directory -Path $tempFolder | Out-Null

    $script:sharedFolder = $tempFolder
    $script:usersFile = Join-Path -Path $tempFolder -ChildPath "users.json"
    $script:sessionsFile = Join-Path -Path $tempFolder -ChildPath "sessions.json"
    $script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
    $script:bootstrapAdminUsername = "admin"
    $script:bootstrapAdminPassword = "ChangeMe123!"

    $targetCode = "000000001"
    $otherCode = "000000002"
    $seedUsers = @(
        [PSCustomObject]@{
            username           = $targetCode
            employeeCode       = $targetCode
            displayName        = "Original Employee"
            role               = "employee"
            disabled           = $false
            timeEntryTypes     = @("overtime")
            gc179Profile       = [PSCustomObject]@{
                surname   = "ORIGINAL"
                givenName = "EMPLOYEE"
            }
            passwordSalt       = "salt-1"
            passwordHash       = "hash-1"
            passwordIterations = 120000
            passwordAlgorithm  = "PBKDF2-HMACSHA1"
        },
        [PSCustomObject]@{
            username           = $otherCode
            employeeCode       = $otherCode
            displayName        = "Other Employee"
            role               = "employee"
            disabled           = $false
            timeEntryTypes     = @("overtime")
            gc179Profile       = [PSCustomObject]@{
                surname   = "OTHER"
                givenName = "EMPLOYEE"
            }
            passwordSalt       = "salt-2"
            passwordHash       = "hash-2"
            passwordIterations = 120000
            passwordAlgorithm  = "PBKDF2-HMACSHA1"
        }
    )

    [System.IO.File]::WriteAllText($script:usersFile, ($seedUsers | ConvertTo-Json -Depth 8))
    [System.IO.File]::WriteAllText($script:sessionsFile, "[]")

    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/AuthService.ps1")

    # Warm both file and parsed auth caches, then simulate a completed write
    # from another lock-respecting process without touching this process's caches.
    @(Read-AuthArrayFileCached -Path $script:usersFile) | Out-Null
    $externalUsers = @(Get-Content -Path $script:usersFile -Raw | ConvertFrom-Json)
    $externalOther = $externalUsers | Where-Object { $_.username -eq $otherCode } | Select-Object -First 1
    $externalOther.displayName = "Externally Updated Employee"
    $externalOther.passwordHash = "external-hash"
    $externalLock = Acquire-ResourceLock -ResourcePath $script:usersFile
    try {
        [System.IO.File]::WriteAllText($script:usersFile, ($externalUsers | ConvertTo-Json -Depth 8))
    }
    finally {
        Release-ResourceLock -LockHandle $externalLock
    }

    $script:OriginalAcquireResourceLock = ${function:Acquire-ResourceLock}
    $script:OriginalReadJsonArrayFile = ${function:Read-JsonArrayFile}
    $script:OriginalWriteJsonAtomic = ${function:Write-JsonAtomic}
    $script:OriginalClearAuthRuntimeCaches = ${function:Clear-AuthRuntimeCaches}
    $script:ProfileLockCount = 0
    $script:ProfileReadCount = 0
    $script:ProfileWriteCount = 0
    $script:ProfileCacheClearCount = 0

    function Acquire-ResourceLock {
        param(
            [Parameter(Mandatory = $true)][string]$ResourcePath,
            [int]$TimeoutMs = 30000,
            [int]$StaleLockMs = 120000
        )

        $script:ProfileLockCount++
        return (& $script:OriginalAcquireResourceLock -ResourcePath $ResourcePath -TimeoutMs $TimeoutMs -StaleLockMs $StaleLockMs)
    }

    function Read-JsonArrayFile {
        param([Parameter(Mandatory = $true)][string]$Path)

        $script:ProfileReadCount++
        return (& $script:OriginalReadJsonArrayFile -Path $Path)
    }

    function Write-JsonAtomic {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)]$Value,
            [int]$Depth = 6
        )

        $script:ProfileWriteCount++
        & $script:OriginalWriteJsonAtomic -Path $Path -Value $Value -Depth $Depth
    }

    function Clear-AuthRuntimeCaches {
        $script:ProfileCacheClearCount++
        & $script:OriginalClearAuthRuntimeCaches
    }

    $profile = [PSCustomObject]@{
        initials           = "JD"
        pri                = "123456789"
        position           = "  sts  "
        level              = "  suf-00  "
        compressedWorkWeek = $true
    }

    $updateParameters = @{
        EmployeeCode   = $targetCode
        DisplayName    = "Jane Doe"
        Role           = "admin"
        TimeEntryTypes = @("overtime")
        Gc179Profile   = $profile
    }
    $updated = Set-EmployeeUserProfile @updateParameters

    Assert-Equal -Expected $true -Actual $updated -Message "The combined profile update should succeed."
    Assert-Equal -Expected 1 -Actual $script:ProfileLockCount -Message "The combined update should acquire one users-file lock."
    Assert-Equal -Expected 1 -Actual $script:ProfileReadCount -Message "The combined update should read users.json once."
    Assert-Equal -Expected 1 -Actual $script:ProfileWriteCount -Message "The combined update should write users.json once."
    Assert-Equal -Expected 1 -Actual $script:ProfileCacheClearCount -Message "The combined update should clear auth caches once."
    Assert-Equal -Expected 0 -Actual $script:AuthArrayFileCache.Count -Message "The combined update should evict parsed auth data."

    $savedUsers = @(Get-Content -Path $script:usersFile -Raw | ConvertFrom-Json)
    $savedTarget = $savedUsers | Where-Object { $_.username -eq $targetCode } | Select-Object -First 1
    $savedOther = $savedUsers | Where-Object { $_.username -eq $otherCode } | Select-Object -First 1

    Assert-Equal -Expected "Jane Doe" -Actual $savedTarget.displayName -Message "Display name was not saved."
    Assert-Equal -Expected "admin" -Actual $savedTarget.role -Message "Role was not normalized and saved."
    Assert-Equal -Expected "overtime" -Actual (@($savedTarget.timeEntryTypes) -join ",") -Message "Time entry types were not saved."
    if (-not ($savedTarget.timeEntryTypes -is [System.Array])) {
        throw "A single time entry type must remain a JSON array."
    }
    Assert-Equal -Expected "DOE" -Actual $savedTarget.gc179Profile.surname -Message "GC179 surname did not use the updated display name."
    Assert-Equal -Expected "JANE" -Actual $savedTarget.gc179Profile.givenName -Message "GC179 given name did not use the updated display name."
    Assert-Equal -Expected "STS" -Actual $savedTarget.gc179Profile.position -Message "The employee-specific GC179 position/group was not normalized and persisted."
    Assert-Equal -Expected "SUF-00" -Actual $savedTarget.gc179Profile.level -Message "The employee-specific GC179 echelon/sub-group was not normalized and persisted."
    Assert-Equal -Expected "hash-1" -Actual $savedTarget.passwordHash -Message "The update changed an unrelated password field."
    Assert-Equal -Expected "Externally Updated Employee" -Actual $savedOther.displayName -Message "The update overwrote a concurrent display-name change."
    Assert-Equal -Expected "external-hash" -Actual $savedOther.passwordHash -Message "The update overwrote a concurrent password change."

    $nonStudentProfile = ConvertTo-Gc179ProfileObject -Value ([PSCustomObject]@{
        position = " as-03() "
        level    = " cr/01!? "
    }) -DisplayName "Non Student"
    Assert-Equal -Expected "AS-03" -Actual $nonStudentProfile.position -Message "A non-student GC179 position code was not preserved."
    Assert-Equal -Expected "CR/01" -Actual $nonStudentProfile.level -Message "A non-student GC179 sub-group code was not preserved."

    $legacyProfile = ConvertTo-Gc179ProfileObject -Value $null -DisplayName "Legacy Employee"
    Assert-Equal -Expected "STS" -Actual $legacyProfile.position -Message "A legacy profile without a position should retain the former GC179 group default."
    Assert-Equal -Expected "SUF-00" -Actual $legacyProfile.level -Message "A legacy profile without an echelon should retain the former GC179 sub-group default."

    Assert-Equal -Expected "ABCDEF" -Actual (ConvertTo-Gc179PositionText -Value "abcdefghi") -Message "GC179 group normalization did not respect the six-character PDF limit."
    Assert-Equal -Expected "ABCDEFGHIJ" -Actual (ConvertTo-Gc179EchelonText -Value "abcdefghijkl") -Message "GC179 sub-group normalization did not respect the ten-character PDF limit."

    Write-Host "Employee profile update test passed: one lock, one read, one write, one cache clear."
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force
    }
}
