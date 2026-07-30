$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw $Message
    }
}

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-backend-safety-{0}" -f ([Guid]::NewGuid().ToString("N")))
$script:sharedFolder = $tempFolder
$script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
$script:mappingFile = Join-Path -Path $tempFolder -ChildPath "employeeNames.json"
$script:projectsFile = Join-Path -Path $tempFolder -ChildPath "projects.json"
$script:overtimeCodesFile = Join-Path -Path $tempFolder -ChildPath "overtimeCodes.json"
$script:paymentOptionsFile = Join-Path -Path $tempFolder -ChildPath "paymentOptions.json"
$script:reasonCodesFile = Join-Path -Path $tempFolder -ChildPath "reasonCodes.json"

try {
    New-Item -ItemType Directory -Path $script:sharedFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $script:lockFolder -Force | Out-Null

    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/EntryService.ps1")

    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/DataSchemaService.ps1")
    $schema = Ensure-SaphirDataSchema
    Assert-Equal -Expected 1 -Actual ([int]$schema.schemaVersion) -Message "A legacy folder without metadata was not adopted as schema 1."
    $futureSchemaText = ConvertTo-Json -InputObject ([PSCustomObject]@{
        format = "SAPHIR"
        schemaVersion = 2
        minimumReaderVersion = 2
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    })
    [System.IO.File]::WriteAllText($script:dataSchemaFile, $futureSchemaText, (New-Object System.Text.UTF8Encoding($false)))
    Clear-CachedFileContent -Path $script:dataSchemaFile
    Assert-Throws -Action { Ensure-SaphirDataSchema | Out-Null } -Message "An older server accepted a data folder from a newer incompatible schema."
    Assert-Equal -Expected $futureSchemaText -Actual ([System.IO.File]::ReadAllText($script:dataSchemaFile)) -Message "Compatibility refusal modified the newer data folder."
    Write-JsonAtomic -Path $script:dataSchemaFile -Value ([PSCustomObject]@{
        format = "SAPHIR"
        schemaVersion = 1
        minimumReaderVersion = 1
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }) -Depth 4

    # A process that waited for a writer must not reuse its pre-lock cache and
    # overwrite the writer's completed change.
    $concurrentPath = Join-Path -Path $tempFolder -ChildPath "concurrent.json"
    Write-JsonArrayAtomic -Path $concurrentPath -Items @([PSCustomObject]@{ id = "A" })
    @(Read-JsonArrayFile -Path $concurrentPath) | Out-Null
    [System.IO.File]::WriteAllText(
        $concurrentPath,
        (ConvertTo-Json -InputObject @(
            [PSCustomObject]@{ id = "A" },
            [PSCustomObject]@{ id = "B" }
        )),
        (New-Object System.Text.UTF8Encoding($false))
    )

    $lockHandle = Acquire-ResourceLock -ResourcePath $concurrentPath
    try {
        $current = @(Read-JsonArrayFile -Path $concurrentPath)
        $current += [PSCustomObject]@{ id = "C" }
        Write-JsonArrayAtomic -Path $concurrentPath -Items $current
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    $savedIds = @((Read-JsonArrayFile -Path $concurrentPath) | ForEach-Object { [string]$_.id })
    Assert-Equal -Expected "A,B,C" -Actual ($savedIds -join ",") -Message "A post-lock read lost another writer's committed record."

    # Never break a live lock merely because it looks old. Slow SMB writes can
    # exceed the stale threshold; exclusive ownership is the deciding signal.
    $liveLockResource = Join-Path -Path $tempFolder -ChildPath "live-lock.json"
    $liveLock = Acquire-ResourceLock -ResourcePath $liveLockResource
    try {
        (Get-Item -LiteralPath $liveLock.Path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-10)
        Assert-Throws -Action {
            Acquire-ResourceLock -ResourcePath $liveLockResource -TimeoutMs 100 -StaleLockMs 1 | Out-Null
        } -Message "A live but old-looking resource lock was stolen."
        Assert-True -Condition (Test-Path -LiteralPath $liveLock.Path -PathType Leaf) -Message "A live lock file was deleted by stale-lock cleanup."
    }
    finally {
        Release-ResourceLock -LockHandle $liveLock
    }

    $abandonedLockResource = Join-Path -Path $tempFolder -ChildPath "abandoned-lock.json"
    $abandonedLockPath = Get-LockFilePath -ResourcePath $abandonedLockResource
    [System.IO.File]::WriteAllText($abandonedLockPath, "abandoned")
    (Get-Item -LiteralPath $abandonedLockPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-10)
    $reclaimedLock = Acquire-ResourceLock -ResourcePath $abandonedLockResource -TimeoutMs 1000 -StaleLockMs 1
    Release-ResourceLock -LockHandle $reclaimedLock
    Assert-True -Condition (-not (Test-Path -LiteralPath $abandonedLockPath)) -Message "An abandoned stale resource lock was not reclaimed."

    # Corrupt persistent JSON must stop a mutation and remain byte-identical.
    $corruptPath = Join-Path -Path $tempFolder -ChildPath "corrupt.json"
    $corruptText = '{ "entryId": "unfinished"'
    [System.IO.File]::WriteAllText($corruptPath, $corruptText, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Throws -Action {
        $corruptLock = Acquire-ResourceLock -ResourcePath $corruptPath
        try {
            $items = @(Read-JsonArrayFile -Path $corruptPath)
            $items += [PSCustomObject]@{ entryId = "new" }
            Write-JsonArrayAtomic -Path $corruptPath -Items $items
        }
        finally {
            Release-ResourceLock -LockHandle $corruptLock
        }
    } -Message "Malformed persistent JSON was silently treated as an empty collection."
    Assert-Equal -Expected $corruptText -Actual ([System.IO.File]::ReadAllText($corruptPath)) -Message "A failed mutation overwrote corrupt recoverable data."

    # A failed final move must be terminating and must not leave temporary files.
    $invalidDestination = Join-Path -Path $tempFolder -ChildPath "destination-is-a-directory"
    New-Item -ItemType Directory -Path $invalidDestination | Out-Null
    function Move-Item {
        param($Path, $Destination, [switch]$Force, $ErrorAction)
        throw "simulated final move failure"
    }
    try {
        Assert-Throws -Action {
            Write-TextAtomic -Path $invalidDestination -Content "new data"
        } -Message "Write-TextAtomic reported success after its final move failed."
    }
    finally {
        Remove-Item -Path Function:\Move-Item -ErrorAction SilentlyContinue
    }
    Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $tempFolder -Filter "destination-is-a-directory.tmp.*" -File).Count -Message "A failed atomic write leaked a temporary file."

    # Stable IDs are authoritative. Conflicting date/time metadata must not
    # redirect an operation to another entry.
    $identityEntries = @(
        [PSCustomObject]@{ entryId = "A"; date = "2026-07-01"; punchIn = "08:00:00" },
        [PSCustomObject]@{ entryId = "B"; date = "2026-07-02"; punchIn = "09:00:00" }
    )
    Assert-Equal -Expected 1 -Actual (Find-EntryIndex -Entries $identityEntries -EntryId "B" -Date "2026-07-01" -PunchIn "08:00:00") -Message "Conflicting metadata overrode the requested entry ID."
    Assert-Equal -Expected -1 -Actual (Find-EntryIndex -Entries $identityEntries -EntryId "missing" -Date "2026-07-01" -PunchIn "08:00:00") -Message "A missing supplied ID incorrectly fell back to another entry."
    Assert-Equal -Expected 0 -Actual (Find-EntryIndex -Entries $identityEntries -EntryId "" -Date "2026-07-01" -PunchIn "08:00:00") -Message "Legacy requests without IDs no longer resolve by date and time."
    $identityLookup = New-EntryIndexLookup -Entries $identityEntries
    Assert-Equal -Expected 1 -Actual (Find-EntryIndexFromLookup -Lookup $identityLookup -EntryId "B" -Date "2026-07-01" -PunchIn "08:00:00") -Message "Batch lookup ignored the authoritative entry ID."
    Assert-Equal -Expected -1 -Actual (Find-EntryIndexFromLookup -Lookup $identityLookup -EntryId "missing" -Date "2026-07-01" -PunchIn "08:00:00") -Message "Batch lookup fell back from a missing supplied ID."
    $duplicateIdentityEntries = @(
        [PSCustomObject]@{ entryId = "duplicate"; date = "2026-07-03"; punchIn = "10:00:00" },
        [PSCustomObject]@{ entryId = "duplicate"; date = "2026-07-03"; punchIn = "10:00:00" }
    )
    Assert-Equal -Expected -1 -Actual (Find-EntryIndex -Entries $duplicateIdentityEntries -EntryId "duplicate") -Message "A duplicate stable ID selected an arbitrary entry."
    Assert-Equal -Expected -1 -Actual (Find-EntryIndex -Entries $duplicateIdentityEntries -Date "2026-07-03" -PunchIn "10:00:00") -Message "An ambiguous legacy key selected an arbitrary entry."
    $duplicateIdentityLookup = New-EntryIndexLookup -Entries $duplicateIdentityEntries
    Assert-Equal -Expected -1 -Actual (Find-EntryIndexFromLookup -Lookup $duplicateIdentityLookup -EntryId "duplicate") -Message "Batch lookup selected an arbitrary duplicate stable ID."
    Assert-Equal -Expected -1 -Actual (Find-EntryIndexFromLookup -Lookup $duplicateIdentityLookup -Date "2026-07-03" -PunchIn "10:00:00") -Message "Batch lookup selected an arbitrary ambiguous legacy key."
    Assert-Equal -Expected "2026-02-28" -Actual (Convert-ToNormalizedDateText -DateText "2026-02-28") -Message "A valid entry date was rejected."
    Assert-True -Condition ([string]::IsNullOrWhiteSpace((Convert-ToNormalizedDateText -DateText "2026-02-30"))) -Message "An impossible calendar date was accepted."

    # Validate custom cached stores: malformed data fails closed and project
    # normalization preserves fields introduced by a future release.
    Write-JsonAtomic -Path $script:mappingFile -Value ([PSCustomObject]@{})
    Write-JsonArrayAtomic -Path $script:projectsFile -Items @()
    Write-JsonArrayAtomic -Path $script:overtimeCodesFile -Items @()
    Write-JsonArrayAtomic -Path $script:paymentOptionsFile -Items @()
    Write-JsonArrayAtomic -Path $script:reasonCodesFile -Items @()
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/CommonHelpers.ps1")

    $mappingCorrupt = '{ bad mapping'
    [System.IO.File]::WriteAllText($script:mappingFile, $mappingCorrupt)
    Clear-CachedFileContent -Path $script:mappingFile
    $script:EmployeeNameMapCache = $null
    Assert-Throws -Action { Get-EmployeeNameMap | Out-Null } -Message "A corrupt employee mapping was converted into an empty map."
    Assert-Equal -Expected $mappingCorrupt -Actual ([System.IO.File]::ReadAllText($script:mappingFile)) -Message "Reading a corrupt employee mapping changed it."

    $futureProject = [PSCustomObject]@{
        projectCode = "FUTURE"
        projectName = "Future project"
        archived = $false
        futureField = "preserve-me"
    }
    Write-JsonArrayAtomic -Path $script:projectsFile -Items @($futureProject)
    $script:ProjectsCache = $null
    $project = @(Get-Projects)[0]
    Assert-Equal -Expected "preserve-me" -Actual ([string]$project.futureField) -Message "Project normalization stripped an unknown future field."

    $projectCorrupt = "[{"
    [System.IO.File]::WriteAllText($script:projectsFile, $projectCorrupt)
    Clear-CachedFileContent -Path $script:projectsFile
    $script:ProjectsCache = $null
    Assert-Throws -Action { Get-Projects | Out-Null } -Message "A corrupt project catalog was converted into an empty catalog."
    Assert-Equal -Expected $projectCorrupt -Actual ([System.IO.File]::ReadAllText($script:projectsFile)) -Message "Reading a corrupt project catalog changed it."

    # Auth array writers keep zero/one-item roots stable and password resets do
    # not silently reactivate an archived employee.
    Write-JsonAtomic -Path $script:mappingFile -Value ([PSCustomObject]@{})
    $script:EmployeeNameMapCache = $null
    $script:usersFile = Join-Path -Path $tempFolder -ChildPath "users.json"
    $script:sessionsFile = Join-Path -Path $tempFolder -ChildPath "sessions.json"
    $script:bootstrapAdminUsername = "admin"
    $script:bootstrapAdminPassword = "ChangeMe123!"
    $script:AuthStorageEnsured = $true
    $employeeCode = "000000901"
    Write-JsonArrayAtomic -Path $script:usersFile -Items @([PSCustomObject]@{
        username = $employeeCode
        employeeCode = $employeeCode
        displayName = "Archived Employee"
        role = "employee"
        disabled = $true
        passwordSalt = "old"
        passwordHash = "old"
        passwordIterations = 120000
        passwordAlgorithm = "PBKDF2-HMACSHA1"
    }) -Depth 8
    $token = "single-session-token"
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/AuthService.ps1")
    Write-JsonArrayAtomic -Path $script:sessionsFile -Items @([PSCustomObject]@{
        username = $employeeCode
        tokenHash = Get-TokenHash -Token $token
        issuedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        expiresAtUtc = (Get-Date).ToUniversalTime().AddHours(1).ToString("o")
    }) -Depth 8
    Revoke-SessionToken -Token $token
    Assert-Equal -Expected "[" -Actual ([string]([System.IO.File]::ReadAllText($script:sessionsFile).TrimStart()[0])) -Message "Revoking the only session did not preserve an array root."
    Assert-Equal -Expected 0 -Actual @(Read-JsonArrayFile -Path $script:sessionsFile).Count -Message "Revoking the only session did not produce an empty array."

    $passwordResult = Set-EmployeeUserPassword -EmployeeCode $employeeCode -NewPassword "Secure!Password901" -MustChangePassword $true
    Assert-True -Condition ([bool]$passwordResult.updated) -Message "The archived employee password could not be reset."
    $savedUsers = @(Read-JsonArrayFile -Path $script:usersFile)
    Assert-Equal -Expected 1 -Actual $savedUsers.Count -Message "A one-user auth mutation changed the collection shape."
    Assert-True -Condition ([bool]$savedUsers[0].disabled) -Message "Resetting a password silently reactivated an archived account."
    Assert-Equal -Expected "[" -Actual ([string]([System.IO.File]::ReadAllText($script:usersFile).TrimStart()[0])) -Message "A one-user auth mutation collapsed the JSON array."
    $incompleteAdmin = [PSCustomObject]@{ username = "not-bootstrap"; role = "admin"; employeeCode = "" }
    Assert-Equal -Expected "admin" -Actual (Get-EffectiveUserRole -UserRecord $incompleteAdmin) -Message "An incomplete admin record was promoted to super admin."

    # Automatically generated employee passwords must be unpredictable and
    # login failures must be bounded per principal and per client.
    $temporaryPasswordOne = New-TemporaryPassword
    $temporaryPasswordTwo = New-TemporaryPassword
    Assert-True -Condition ($temporaryPasswordOne -ne $temporaryPasswordTwo) -Message "Temporary employee passwords were deterministic."
    Assert-True -Condition ([string]::IsNullOrWhiteSpace((Test-NewPasswordPolicy -Password $temporaryPasswordOne))) -Message "An automatically generated password did not satisfy the password policy."

    $script:LoginThrottleState = @{}
    $loginRequest = [PSCustomObject]@{
        RemoteEndPoint = [PSCustomObject]@{ Address = "127.0.0.1" }
    }
    $throttleStart = [DateTime]::Parse("2026-07-29T12:00:00Z").ToUniversalTime()
    foreach ($failureNumber in 1..$script:LoginThrottlePrincipalLimit) {
        $preFailureDecision = Get-LoginThrottleDecision -Request $loginRequest -Username "employee" -NowUtc $throttleStart
        Assert-True -Condition ([bool]$preFailureDecision.Allowed) -Message "The login throttle blocked a principal before the configured failure limit."
        Register-FailedLoginAttempt -Request $loginRequest -Username "employee" -NowUtc $throttleStart
    }
    $blockedDecision = Get-LoginThrottleDecision -Request $loginRequest -Username "employee" -NowUtc $throttleStart
    Assert-True -Condition (-not [bool]$blockedDecision.Allowed) -Message "The login throttle did not block a principal at the configured failure limit."
    Assert-True -Condition ([int]$blockedDecision.RetryAfterSeconds -gt 0) -Message "The login throttle did not provide a positive Retry-After interval."
    Clear-LoginThrottleForPrincipal -Request $loginRequest -Username "employee"
    $clearedDecision = Get-LoginThrottleDecision -Request $loginRequest -Username "employee" -NowUtc $throttleStart
    Assert-True -Condition ([bool]$clearedDecision.Allowed) -Message "A successful login could not clear its principal throttle bucket."
    $expiredDecision = Get-LoginThrottleDecision -Request $loginRequest -Username "employee" -NowUtc $throttleStart.AddSeconds($script:LoginThrottleWindowSeconds + 1)
    Assert-True -Condition ([bool]$expiredDecision.Allowed) -Message "An expired login throttle window did not reopen."

    # Corrupt derived sync metadata is backed up and rebuilt so subsequent
    # cross-machine notifications do not remain permanently broken.
    $script:syncStateFile = Join-Path -Path $tempFolder -ChildPath "sync-state.json"
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/SyncService.ps1")
    $corruptSyncText = '{ "version": '
    [System.IO.File]::WriteAllText($script:syncStateFile, $corruptSyncText, (New-Object System.Text.UTF8Encoding($false)))
    Clear-SyncStateCache
    $publishedState = Publish-DataChange -Category "auth" -Resource "recovery-test"
    Assert-Equal -Expected "auth" -Actual ([string]$publishedState.category) -Message "Publishing did not recover from corrupt derived sync metadata."
    $savedSyncState = [System.IO.File]::ReadAllText($script:syncStateFile) | ConvertFrom-Json
    Assert-True -Condition ([int]$savedSyncState.version -ge 1) -Message "Recovered sync metadata did not contain a valid version."
    $syncBackups = @(Get-ChildItem -LiteralPath (Join-Path -Path $tempFolder -ChildPath ".recovery") -Filter "sync-state.corrupt.*.json" -File)
    Assert-Equal -Expected 1 -Actual $syncBackups.Count -Message "Corrupt sync metadata was not preserved exactly once."
    Assert-Equal -Expected $corruptSyncText -Actual ([System.IO.File]::ReadAllText($syncBackups[0].FullName)) -Message "The sync recovery backup did not preserve the corrupt source bytes."

    # Batch payload identifiers cannot escape the configured data directory.
    $script:BatchPayload = [PSCustomObject]@{
        status = "approved"
        message = ""
        entries = @([PSCustomObject]@{
            employeeCode = "../outside/000001"
            entryId = "entry"
        })
    }
    $script:CapturedBatchStatus = 0
    function Read-JsonRequestBody { param($Request) return $script:BatchPayload }
    function respondWithError {
        param($Response, [int]$StatusCode, [string]$Message)
        $script:CapturedBatchStatus = $StatusCode
    }
    function respondWithSuccess {
        param($Response, [string]$Message)
        $script:CapturedBatchStatus = 200
    }
    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url = [PSCustomObject]@{ AbsolutePath = "/employee/approval/batch" }
    }
    $response = [PSCustomObject]@{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/batch-approval.routes.ps1")
    }
    Assert-Equal -Expected 400 -Actual $script:CapturedBatchStatus -Message "Batch approval accepted a path-like employee code."

    # Error responses remain valid JSON and transport failures are contained.
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/ResponseHelpers.ps1")
    $responseStream = New-Object System.IO.MemoryStream
    $jsonResponse = [PSCustomObject]@{
        StatusCode = 0
        ContentType = ""
        ContentLength64 = 0L
        OutputStream = $responseStream
    }
    $jsonResponse | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    respondWithError $jsonResponse 500 "Quoted `"message`"`nnext line"
    $errorPayload = ([System.Text.Encoding]::UTF8.GetString($responseStream.ToArray())) | ConvertFrom-Json
    Assert-Equal -Expected "Quoted `"message`"`nnext line" -Actual ([string]$errorPayload.error) -Message "Error response JSON did not escape quotes/newlines."

    $throwingStream = [PSCustomObject]@{}
    $throwingStream | Add-Member -MemberType ScriptMethod -Name Write -Value { param($Bytes, $Offset, $Count) throw "client disconnected" }
    $abortedResponse = [PSCustomObject]@{
        StatusCode = 0
        ContentType = ""
        ContentLength64 = 0L
        OutputStream = $throwingStream
    }
    $abortedResponse | Add-Member -MemberType ScriptMethod -Name Close -Value { throw "already closed" }
    respondWithSuccess $abortedResponse "{}"

    $sameOriginResponse = [PSCustomObject]@{ Headers = @{} }
    $sameOriginRequest = [PSCustomObject]@{
        Headers = @{ Origin = "http://localhost:8081" }
        Url = [System.Uri]"http://localhost:8081/auth/login"
    }
    Assert-True -Condition (Set-CorsHeadersForRequest -Request $sameOriginRequest -Response $sameOriginResponse) -Message "A same-origin browser request was rejected."
    Assert-Equal -Expected "http://localhost:8081" -Actual ([string]$sameOriginResponse.Headers["Access-Control-Allow-Origin"]) -Message "The CORS response did not echo the validated same origin."
    Assert-Equal -Expected "Origin" -Actual ([string]$sameOriginResponse.Headers["Vary"]) -Message "The CORS response did not vary by Origin."

    $loopbackAliasResponse = [PSCustomObject]@{ Headers = @{} }
    $loopbackAliasRequest = [PSCustomObject]@{
        Headers = @{ Origin = "http://localhost:8081" }
        Url = [System.Uri]"http://127.0.0.1:8081/auth/login"
    }
    Assert-True -Condition (Set-CorsHeadersForRequest -Request $loopbackAliasRequest -Response $loopbackAliasResponse) -Message "Equivalent localhost and loopback API origins were rejected."

    $untrustedOriginResponse = [PSCustomObject]@{ Headers = @{} }
    $untrustedOriginRequest = [PSCustomObject]@{
        Headers = @{ Origin = "https://untrusted.example" }
        Url = [System.Uri]"http://localhost:8081/auth/login"
    }
    Assert-True -Condition (-not (Set-CorsHeadersForRequest -Request $untrustedOriginRequest -Response $untrustedOriginResponse)) -Message "An untrusted cross-origin request was allowed."
    Assert-True -Condition (-not $untrustedOriginResponse.Headers.ContainsKey("Access-Control-Allow-Origin")) -Message "A rejected origin received an allow-origin header."

    $configuredOriginResponse = [PSCustomObject]@{ Headers = @{} }
    Assert-True -Condition (Set-CorsHeadersForRequest -Request $untrustedOriginRequest -Response $configuredOriginResponse -AllowedOrigins @("https://untrusted.example/")) -Message "An explicitly configured origin was rejected."
    Assert-Equal -Expected "https://untrusted.example" -Actual ([string]$configuredOriginResponse.Headers["Access-Control-Allow-Origin"]) -Message "The configured CORS origin was not normalized safely."

    # Restore the production reader after the batch-route stub used above.
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/CommonHelpers.ps1")
    $invalidJsonBytes = [System.Text.Encoding]::UTF8.GetBytes("{")
    $invalidJsonStream = New-Object System.IO.MemoryStream(, $invalidJsonBytes)
    try {
        $invalidJsonRequest = [PSCustomObject]@{
            ContentLength64 = [long]$invalidJsonBytes.Length
            InputStream     = $invalidJsonStream
        }
        $invalidJsonException = $null
        try {
            Read-JsonRequestBody -Request $invalidJsonRequest | Out-Null
        }
        catch {
            $invalidJsonException = $_.Exception
        }
        Assert-True -Condition ($null -ne $invalidJsonException) -Message "Malformed request JSON did not fail."
        Assert-Equal -Expected 400 -Actual ([int]$invalidJsonException.Data["SaphirHttpStatusCode"]) -Message "Malformed request JSON was not classified as a client error."
    }
    finally {
        $invalidJsonStream.Dispose()
    }

    $oversizeRequest = [PSCustomObject]@{
        ContentLength64 = 101L
        InputStream     = (New-Object System.IO.MemoryStream)
    }
    try {
        $oversizeException = $null
        try {
            Read-JsonRequestBody -Request $oversizeRequest -MaxBytes 100 | Out-Null
        }
        catch {
            $oversizeException = $_.Exception
        }
        Assert-True -Condition ($null -ne $oversizeException) -Message "An oversized request body did not fail."
        Assert-Equal -Expected 413 -Actual ([int]$oversizeException.Data["SaphirHttpStatusCode"]) -Message "An oversized request body was not classified as payload too large."
    }
    finally {
        $oversizeRequest.InputStream.Dispose()
    }

    $serverSource = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/admin-server.ps1"))
    Assert-True -Condition $serverSource.Contains('Data["SaphirHttpStatusCode"]') -Message "The server no longer maps typed request-body failures to their HTTP status."

    $frontendRoot = Join-Path -Path $tempFolder -ChildPath "frontend"
    $siblingRoot = Join-Path -Path $tempFolder -ChildPath "frontend-backup"
    New-Item -ItemType Directory -Path $frontendRoot | Out-Null
    New-Item -ItemType Directory -Path $siblingRoot | Out-Null
    [System.IO.File]::WriteAllText((Join-Path -Path $frontendRoot -ChildPath "index.html"), "ok")
    [System.IO.File]::WriteAllText((Join-Path -Path $siblingRoot -ChildPath "secret.txt"), "secret")
    Assert-True -Condition ($null -ne (Resolve-FrontendFilePath -FrontendRoot $frontendRoot -RelativePath "index.html")) -Message "A valid frontend file was rejected."
    Assert-True -Condition ($null -eq (Resolve-FrontendFilePath -FrontendRoot $frontendRoot -RelativePath "../frontend-backup/secret.txt")) -Message "Frontend path containment accepted a sibling-prefix traversal."

    foreach ($contract in @(
        [PSCustomObject]@{ Path = "apps/admin/backend/routes/history.routes.ps1"; Text = "ConvertTo-Json -InputObject @(Get-HistoryEntriesSnapshot)" },
        [PSCustomObject]@{ Path = "apps/admin/backend/routes/employee/list.routes.ps1"; Text = "ConvertTo-Json -InputObject @(`$employees)" },
        [PSCustomObject]@{ Path = "apps/admin/backend/routes/projects/get.routes.ps1"; Text = "ConvertTo-Json -InputObject `$projectsData" },
        [PSCustomObject]@{ Path = "apps/admin/backend/routes/self.routes.ps1"; Text = "ConvertTo-Json -InputObject @(`$entries)" },
        [PSCustomObject]@{ Path = "apps/admin/backend/routes/stats/summary.routes.ps1"; Text = "ConvertTo-Json -InputObject `$result" }
    )) {
        $source = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath $contract.Path))
        Assert-True -Condition ($source.Contains([string]$contract.Text)) -Message "$($contract.Path) no longer guarantees an array JSON response."
    }

    foreach ($guardedRoute in @(
        "apps/admin/backend/routes/employee/add.routes.ps1",
        "apps/admin/backend/routes/employee/update.routes.ps1",
        "apps/admin/backend/routes/self.routes.ps1",
        "apps/admin/backend/routes/employee/gc179-import.routes.ps1",
        "apps/admin/backend/routes/projects/add.routes.ps1",
        "apps/admin/backend/routes/projects/update.routes.ps1",
        "apps/admin/backend/routes/projects/delete.routes.ps1"
    )) {
        $source = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath $guardedRoute))
        Assert-True -Condition $source.Contains("Acquire-ProjectReferenceLock") -Message "$guardedRoute can race project catalog changes without the shared reference guard."
    }

    # PowerShell enumerates function output. A direct assignment from one of
    # these collection readers therefore becomes a PSCustomObject when the
    # file has exactly one record, and a later += raises PSObject.op_Addition.
    # Require callers to put an array expression around the read.
    $collectionReaderNames = @(
        "Read-JsonArrayFile",
        "Read-ProjectsFromDisk",
        "Read-AuthArrayFileCached",
        "Read-Gc179EmployeeDataStrict"
    )
    foreach ($backendScript in @(Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend") -Recurse -File -Filter "*.ps1")) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($backendScript.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal -Expected 0 -Actual @($parseErrors).Count -Message "Backend script has parser errors: $($backendScript.FullName)"

        $readerCommands = @($ast.FindAll({
            param($node)
            if (-not ($node -is [System.Management.Automation.Language.CommandAst])) {
                return $false
            }
            return ($collectionReaderNames -contains [string]$node.GetCommandName())
        }, $true))

        foreach ($readerCommand in $readerCommands) {
            $ancestor = $readerCommand.Parent
            $arrayProtected = $false
            $assignment = $null
            while ($null -ne $ancestor) {
                if ($ancestor -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                    $arrayProtected = $true
                }
                if ($ancestor -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                    $assignment = $ancestor
                    break
                }
                $ancestor = $ancestor.Parent
            }

            if ($null -ne $assignment) {
                Assert-True -Condition $arrayProtected -Message (
                    "Collection reader {0} is assigned without @() in {1}:{2}; one-record data would collapse to PSCustomObject." -f
                    $readerCommand.GetCommandName(),
                    $backendScript.FullName,
                    $readerCommand.Extent.StartLineNumber
                )
            }
        }
    }

    Write-Host "Backend data-safety regressions passed."
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
