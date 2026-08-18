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

function Assert-Contains {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$ExpectedText,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Value -notlike "*$ExpectedText*") {
        throw "$Message Expected '$Value' to contain '$ExpectedText'."
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$routePath = Join-Path -Path $repoRoot -ChildPath "app/backend/routes/auth.routes.ps1"
$script:demoSeedEnabled = $false
$script:gc179ImportEnabled = $true
$script:Payload = $null
$script:BodyFailure = ""
$script:CapturedStatus = 0
$script:CapturedMessage = ""
$script:CurrentUser = $null
$script:UserRecord = $null
$script:UserLookupFailure = ""
$script:PasswordMatches = $true
$script:PasswordUpdateResult = $true
$script:PasswordUpdateFailure = ""
$script:ThrottleAllowed = $true
$script:ThrottleRetryAfter = 0
$script:FailedLoginRegistrations = 0
$script:ThrottleClears = 0
$script:SessionRevokeFailure = ""
$script:SessionRevokeCalls = 0
$script:PublishFailure = ""
$script:PublishCalls = 0

function Reset-Scenario {
    $script:Payload = $null
    $script:BodyFailure = ""
    $script:CapturedStatus = 0
    $script:CapturedMessage = ""
    $script:CurrentUser = $null
    $script:UserRecord = $null
    $script:UserLookupFailure = ""
    $script:PasswordMatches = $true
    $script:PasswordUpdateResult = $true
    $script:PasswordUpdateFailure = ""
    $script:ThrottleAllowed = $true
    $script:ThrottleRetryAfter = 0
    $script:FailedLoginRegistrations = 0
    $script:ThrottleClears = 0
    $script:SessionRevokeFailure = ""
    $script:SessionRevokeCalls = 0
    $script:PublishFailure = ""
    $script:PublishCalls = 0
}

function Read-JsonRequestBody {
    param($Request)

    switch ($script:BodyFailure) {
        "format" { throw [System.FormatException]::new("Request body must contain valid JSON.") }
        "large" { throw [System.IO.InvalidDataException]::new("sensitive byte limit details") }
        "timeout" { throw [System.TimeoutException]::new("sensitive transport details") }
    }
    return $script:Payload
}

function respondWithSuccess {
    param($Response, [string]$Message)
    $script:CapturedStatus = 200
    $script:CapturedMessage = $Message
}

function respondWithError {
    param($Response, [int]$StatusCode, [string]$Message)
    $script:CapturedStatus = $StatusCode
    $script:CapturedMessage = $Message
}

function Rethrow-HttpStatusException {
    param($Exception)
    if ($null -ne $Exception -and
        $null -ne $Exception.Data -and
        $Exception.Data.Contains("SaphirHttpStatusCode")) {
        throw $Exception
    }
}

function Get-AuthenticatedUserFromRequest {
    param($Request)
    return $script:CurrentUser
}

function Get-UserByUsername {
    param([string]$Username)
    if (-not [string]::IsNullOrWhiteSpace($script:UserLookupFailure)) {
        throw $script:UserLookupFailure
    }
    return $script:UserRecord
}

function Test-PasswordCredential {
    param([string]$Password, $UserRecord)
    return [bool]$script:PasswordMatches
}

function Test-NewPasswordPolicy {
    param([string]$Password)
    return $null
}

function Set-UserPassword {
    param([string]$Username, [string]$NewPassword)
    if (-not [string]::IsNullOrWhiteSpace($script:PasswordUpdateFailure)) {
        throw $script:PasswordUpdateFailure
    }
    return [bool]$script:PasswordUpdateResult
}

function Revoke-SessionsForUsername {
    param([string]$Username, [string]$ExcludeToken)
    $script:SessionRevokeCalls++
    if (-not [string]::IsNullOrWhiteSpace($script:SessionRevokeFailure)) {
        throw $script:SessionRevokeFailure
    }
}

function Publish-DataChange {
    param([string]$Category, [string]$Resource)
    $script:PublishCalls++
    if (-not [string]::IsNullOrWhiteSpace($script:PublishFailure)) {
        throw $script:PublishFailure
    }
}

function Invoke-PostCommitActionSafely {
    param([string]$Description, [scriptblock]$Action)
    try {
        & $Action | Out-Null
        return ""
    }
    catch {
        return "$Description`: $($_.Exception.Message)"
    }
}

function Get-LoginThrottleDecision {
    param($Request, [string]$Username)
    return [PSCustomObject]@{
        Allowed = [bool]$script:ThrottleAllowed
        RetryAfterSeconds = [int]$script:ThrottleRetryAfter
    }
}

function Register-FailedLoginAttempt {
    param($Request, [string]$Username)
    $script:FailedLoginRegistrations++
}

function Clear-LoginThrottleForPrincipal {
    param($Request, [string]$Username)
    $script:ThrottleClears++
}

function Get-DummyLoginCredential {
    return [PSCustomObject]@{ passwordSalt = "dummy"; passwordHash = "dummy" }
}

function New-SessionForUser {
    param($UserRecord)
    return "session-token"
}

function New-AuthenticatedUserProjection {
    param($UserRecord, [string]$Token)
    return [PSCustomObject]@{
        username = [string]$UserRecord.username
        displayName = "Test User"
        role = "employee"
        employeeCode = "000000001"
        mustChangePassword = $false
        timeEntryTypes = @("overtime")
        gc179Profile = $null
    }
}

function Get-SessionCookieHeader {
    param([string]$Token)
    return "session-cookie"
}

function Revoke-SessionToken { param([string]$Token) }
function Get-ExpiredSessionCookieHeader { return "expired-cookie" }

function Invoke-AuthRoute {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $request = [PSCustomObject]@{
        HttpMethod = $Method
        Url = [System.Uri]("http://localhost:8081{0}" -f $Path)
        Headers = @{}
        RemoteEndPoint = [PSCustomObject]@{ Address = "127.0.0.1" }
    }
    $response = [PSCustomObject]@{ Headers = @{} }
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . $routePath
    }
    return $response
}

Reset-Scenario
$script:Payload = [PSCustomObject]@{ username = "employee"; password = "wrong" }
$script:ThrottleAllowed = $false
$script:ThrottleRetryAfter = 42
$blockedResponse = Invoke-AuthRoute -Method "POST" -Path "/auth/login"
Assert-Equal -Expected 429 -Actual $script:CapturedStatus -Message "A throttled login did not return HTTP 429."
Assert-Equal -Expected 42 -Actual ([string]$blockedResponse.Headers["Retry-After"]) -Message "A throttled login did not return Retry-After."

Reset-Scenario
$script:Payload = [PSCustomObject]@{ username = "missing"; password = "wrong" }
$script:PasswordMatches = $false
Invoke-AuthRoute -Method "POST" -Path "/auth/login" | Out-Null
Assert-Equal -Expected 401 -Actual $script:CapturedStatus -Message "Invalid credentials did not return HTTP 401."
Assert-Equal -Expected 1 -Actual $script:FailedLoginRegistrations -Message "An invalid login was not registered with the throttle."

Reset-Scenario
$script:Payload = [PSCustomObject]@{ username = "employee"; password = "correct" }
$script:UserRecord = [PSCustomObject]@{ username = "employee"; disabled = $false }
$successfulLoginResponse = Invoke-AuthRoute -Method "POST" -Path "/auth/login"
Assert-Equal -Expected 200 -Actual $script:CapturedStatus -Message "A valid login did not succeed."
Assert-Equal -Expected 1 -Actual $script:ThrottleClears -Message "A valid login did not clear its principal throttle bucket."
Assert-Equal -Expected "no-store" -Actual ([string]$successfulLoginResponse.Headers["Cache-Control"]) -Message "A login response was cacheable."

Reset-Scenario
$script:Payload = [PSCustomObject]@{ username = "employee"; password = "correct" }
$script:UserLookupFailure = "users path C:\secret\users.json is corrupt"
Invoke-AuthRoute -Method "POST" -Path "/auth/login" | Out-Null
Assert-Equal -Expected 500 -Actual $script:CapturedStatus -Message "An internal authentication failure returned the wrong status."
Assert-Equal -Expected "Authentication failed." -Actual $script:CapturedMessage -Message "Authentication leaked an internal exception."

foreach ($bodyCase in @(
    [PSCustomObject]@{ Failure = "format"; Status = 400; Expected = "valid JSON" },
    [PSCustomObject]@{ Failure = "large"; Status = 413; Expected = "too large" },
    [PSCustomObject]@{ Failure = "timeout"; Status = 408; Expected = "Timed out" }
)) {
    Reset-Scenario
    $script:BodyFailure = $bodyCase.Failure
    Invoke-AuthRoute -Method "POST" -Path "/auth/login" | Out-Null
    Assert-Equal -Expected $bodyCase.Status -Actual $script:CapturedStatus -Message "A $($bodyCase.Failure) login body returned the wrong status."
    Assert-Contains -Value $script:CapturedMessage -ExpectedText $bodyCase.Expected -Message "A $($bodyCase.Failure) login body returned the wrong public explanation."
}

Reset-Scenario
$script:CurrentUser = [PSCustomObject]@{ username = "employee"; token = "current-token" }
$script:UserRecord = [PSCustomObject]@{ username = "employee"; disabled = $false }
$script:Payload = [PSCustomObject]@{ currentPassword = "old"; newPassword = "Secure!Password123" }
$script:SessionRevokeFailure = "session store unavailable"
$script:PublishFailure = "sync metadata unavailable"
$changeResponse = Invoke-AuthRoute -Method "POST" -Path "/auth/change-password"
Assert-Equal -Expected 200 -Actual $script:CapturedStatus -Message "A committed self-service password change became a false failure."
Assert-Contains -Value $script:CapturedMessage -ExpectedText "session store unavailable" -Message "The self-service password response lost its revocation warning."
Assert-Contains -Value $script:CapturedMessage -ExpectedText "sync metadata unavailable" -Message "The self-service password response lost its publication warning."
Assert-Equal -Expected 1 -Actual $script:SessionRevokeCalls -Message "Self-service password change did not attempt session revocation."
Assert-Equal -Expected 1 -Actual $script:PublishCalls -Message "Self-service password change did not attempt publication after revocation failed."
Assert-Equal -Expected "no-store" -Actual ([string]$changeResponse.Headers["Cache-Control"]) -Message "A password-change response was cacheable."

Reset-Scenario
$script:CurrentUser = [PSCustomObject]@{ username = "employee"; token = "current-token" }
$script:UserRecord = [PSCustomObject]@{ username = "employee"; disabled = $false }
$script:Payload = [PSCustomObject]@{ currentPassword = "old"; newPassword = "Secure!Password123" }
$script:PasswordUpdateFailure = "users path C:\secret\users.json could not be written"
Invoke-AuthRoute -Method "POST" -Path "/auth/change-password" | Out-Null
Assert-Equal -Expected 500 -Actual $script:CapturedStatus -Message "A pre-commit password failure returned the wrong status."
Assert-Equal -Expected "Password update failed." -Actual $script:CapturedMessage -Message "Password change leaked an internal exception."

$rawExceptionResponsePattern = 'respondWithError\s+\$response\s+500.*(Exception(\.Message)?|\$_|\$seedOperationError)'
foreach ($backendScript in @(Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend") -Filter "*.ps1" -File -Recurse)) {
    $lineNumber = 0
    foreach ($sourceLine in [System.IO.File]::ReadAllLines($backendScript.FullName)) {
        $lineNumber++
        if ($sourceLine -match $rawExceptionResponsePattern) {
            throw "HTTP 500 response exposes raw exception text at $($backendScript.FullName):$lineNumber"
        }
    }
}

Write-Host "Authentication route reliability tests passed."
