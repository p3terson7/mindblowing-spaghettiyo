$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/ControlService.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

$instanceToken = "0123456789abcdef0123456789abcdef"
$otherToken = "fedcba9876543210fedcba9876543210"

$ordinaryRequest = Resolve-SaphirControlRequest `
    -Method "GET" `
    -Path "/health" `
    -RemoteAddress "127.0.0.1" `
    -ExpectedToken $instanceToken `
    -ProvidedToken ""
Assert-True -Condition (-not $ordinaryRequest.IsControlRequest) -Message "ordinary API routes must remain outside service control"

$wrongMethod = Resolve-SaphirControlRequest `
    -Method "GET" `
    -Path $script:SaphirControlShutdownPath `
    -RemoteAddress "127.0.0.1" `
    -ExpectedToken $instanceToken `
    -ProvidedToken $instanceToken
Assert-Equal -Expected 405 -Actual $wrongMethod.StatusCode -Message "the shutdown endpoint must accept POST only"
Assert-True -Condition (-not $wrongMethod.ShouldShutdown) -Message "a GET request must never stop SAPHIR"

$remoteRequest = Resolve-SaphirControlRequest `
    -Method "POST" `
    -Path $script:SaphirControlShutdownPath `
    -RemoteAddress "192.0.2.10" `
    -ExpectedToken $instanceToken `
    -ProvidedToken $instanceToken
Assert-Equal -Expected 403 -Actual $remoteRequest.StatusCode -Message "non-loopback callers must be denied"
Assert-True -Condition (-not $remoteRequest.ShouldShutdown) -Message "a remote caller must never stop SAPHIR"

$missingServerToken = Resolve-SaphirControlRequest `
    -Method "POST" `
    -Path $script:SaphirControlShutdownPath `
    -RemoteAddress "::1" `
    -ExpectedToken "" `
    -ProvidedToken $instanceToken
Assert-Equal -Expected 503 -Actual $missingServerToken.StatusCode -Message "a directly started backend without managed metadata must disable service control"

$incorrectToken = Resolve-SaphirControlRequest `
    -Method "POST" `
    -Path $script:SaphirControlShutdownPath `
    -RemoteAddress ([System.Net.IPAddress]::Loopback) `
    -ExpectedToken $instanceToken `
    -ProvidedToken $otherToken
Assert-Equal -Expected 403 -Actual $incorrectToken.StatusCode -Message "a different instance token must be denied"
Assert-True -Condition (-not $incorrectToken.ShouldShutdown) -Message "an incorrect token must never stop SAPHIR"

$caseChangedToken = $instanceToken.ToUpperInvariant()
Assert-True `
    -Condition (-not (Test-SaphirControlToken -ExpectedToken $instanceToken -ProvidedToken $caseChangedToken)) `
    -Message "instance tokens must be compared case-sensitively"

foreach ($loopbackAddress in @("127.0.0.1", "::1", "::ffff:127.0.0.1")) {
    $authorized = Resolve-SaphirControlRequest `
        -Method "POST" `
        -Path $script:SaphirControlShutdownPath `
        -RemoteAddress $loopbackAddress `
        -ExpectedToken $instanceToken `
        -ProvidedToken $instanceToken
    Assert-Equal -Expected 202 -Actual $authorized.StatusCode -Message "valid local control must be accepted for $loopbackAddress"
    Assert-True -Condition $authorized.ShouldShutdown -Message "valid local control must request shutdown for $loopbackAddress"
}

$adminServerSource = [System.IO.File]::ReadAllText(
    (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/admin-server.ps1")
)
$serverControlSource = [System.IO.File]::ReadAllText(
    (Join-Path -Path $repoRoot -ChildPath "scripts/lib/ServerControl.ps1")
)
$controlResolutionIndex = $adminServerSource.IndexOf("Resolve-SaphirControlRequest", [System.StringComparison]::Ordinal)
$normalRouteIndex = $adminServerSource.IndexOf("Resolve-AdminTopLevelRouteScript", [System.StringComparison]::Ordinal)
Assert-True -Condition ($controlResolutionIndex -ge 0) -Message "the backend request loop must invoke the control guard"
Assert-True -Condition ($normalRouteIndex -gt $controlResolutionIndex) -Message "the independently authenticated control endpoint must be handled before normal API dispatch"
Assert-True `
    -Condition ($adminServerSource.IndexOf('Access-Control-Allow-Headers", "Content-Type, Authorization"', [System.StringComparison]::Ordinal) -ge 0) `
    -Message "ordinary CORS preflight must not authorize the service-control token header"
Assert-True `
    -Condition ($serverControlSource.IndexOf('[int]$TimeoutMilliseconds = 30000', [System.StringComparison]::Ordinal) -ge 0) `
    -Message "graceful shutdown must wait behind legitimate serialized data writes before force fallback"

Write-Host "Graceful shutdown control tests passed."
