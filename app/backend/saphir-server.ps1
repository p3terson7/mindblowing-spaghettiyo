# saphir-server.ps1
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$script:saphirInstanceToken = [string]$env:SAPHIR_INSTANCE_TOKEN

# Shared context + helpers + services
. (Join-Path -Path $scriptDir -ChildPath "lib/AppContext.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/CommonHelpers.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/ControlService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/FileStore.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/ResponseHelpers.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/AuthService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/EntryService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/ReadModelService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/EmployeeDirectoryService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/SyncService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/ProjectStatsService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/HistoryService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/SeedService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/ProjectMutationService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/Gc179ExportService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/Gc179ImportService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/AnalyticsReportService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/RouteDispatchService.ps1")

function Register-RouteScriptBlock {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $routePath = Join-Path -Path $scriptDir -ChildPath $RelativePath
    $script:RouteScriptBlocks[$RelativePath] = [scriptblock]::Create([System.IO.File]::ReadAllText($routePath))
}

function Invoke-CachedRouteScript {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ($script:RouteScriptBlocks -and $script:RouteScriptBlocks.ContainsKey($RelativePath)) {
        . $script:RouteScriptBlocks[$RelativePath]
        return
    }

    . (Join-Path -Path $scriptDir -ChildPath $RelativePath)
}

$script:RouteScriptBlocks = @{}
@(Get-AdminRouteScriptPaths) | ForEach-Object { Register-RouteScriptBlock -RelativePath $_ }

# Initialize HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.IgnoreWriteExceptions = $true
try {
    $listener.TimeoutManager.EntityBody = [TimeSpan]::FromSeconds(15)
    $listener.TimeoutManager.IdleConnection = [TimeSpan]::FromSeconds(30)
}
catch {
    # TimeoutManager is not implemented by every HttpListener runtime. The
    # bounded request-body reader remains the portable enforcement layer.
}
$listener.Prefixes.Add($listenerPrefix)
try {
    $listener.Start()
}
catch {
    throw "Failed to start SAPHIR listener on $listenerPrefix. $($_.Exception.Message)"
}
Write-Host "SAPHIR Server running on $listenerPrefix"

$shutdownRequested = $false
try {
    while (-not $shutdownRequested) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            $response.Headers.Add("X-SAPHIR-App", "SAPHIR")
            if (-not [string]::IsNullOrWhiteSpace($script:saphirInstanceToken)) {
                $response.Headers.Add("X-SAPHIR-Instance", $script:saphirInstanceToken)
            }

            $remoteAddress = if ($null -ne $request.RemoteEndPoint) {
                $request.RemoteEndPoint.Address
            }
            else {
                $null
            }
            $controlDecision = Resolve-SaphirControlRequest `
                -Method ([string]$request.HttpMethod) `
                -Path ([string]$request.Url.AbsolutePath) `
                -RemoteAddress $remoteAddress `
                -ExpectedToken $script:saphirInstanceToken `
                -ProvidedToken ([string]$request.Headers[$script:SaphirControlTokenHeader])

            if ($controlDecision.IsControlRequest) {
                if (-not $controlDecision.ShouldShutdown) {
                    if ([int]$controlDecision.StatusCode -eq 405) {
                        $response.Headers["Allow"] = "POST"
                    }
                    respondWithError $response ([int]$controlDecision.StatusCode) ([string]$controlDecision.Message)
                    continue
                }

                $response.Headers["Cache-Control"] = "no-store"
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes('{ "status": "stopping" }')
                Write-HttpResponseSafely -Response $response -StatusCode ([int]$controlDecision.StatusCode) -Bytes $responseBytes
                $shutdownRequested = $true
                continue
            }

            if (-not (Set-CorsHeadersForRequest -Request $request -Response $response -AllowedOrigins $corsAllowedOrigins)) {
                respondWithError $response 403 "This request origin is not allowed."
                continue
            }

            if ($request.HttpMethod -eq "OPTIONS") {
                $response.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS, PUT, DELETE, POST")
                $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization")
                respondWithSuccess $response '{}'
                continue
            }

            # Observe cross-workstation change notifications before any
            # authorization or validation reads for this request.
            Sync-ReadModelCaches

            # Route handlers are compiled once at startup; resolve the one matching
            # handler instead of evaluating every top-level script on each request.
            $routeScriptPath = Resolve-AdminTopLevelRouteScript -Method ([string]$request.HttpMethod) -Path ([string]$request.Url.AbsolutePath)
            $passwordChangeExempt = $routeScriptPath -eq "routes/frontend.routes.ps1" -or
                $routeScriptPath -eq "routes/auth.routes.ps1" -or
                $request.Url.AbsolutePath -eq "/health"
            if (-not $passwordChangeExempt) {
                $passwordGateUser = Get-AuthenticatedUserFromRequest -Request $request
                if ($null -ne $passwordGateUser -and [bool]$passwordGateUser.mustChangePassword) {
                    respondWithError $response 403 "You must change your temporary password before using the application."
                    continue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($routeScriptPath)) {
                . $script:RouteScriptBlocks[$routeScriptPath]
            }

            respondWithError $response 404 "Route not found."
        }
        catch {
            $requestFailureStatus = 0
            if ($null -ne $_.Exception -and
                $null -ne $_.Exception.Data -and
                $_.Exception.Data.Contains("SaphirHttpStatusCode")) {
                [int]::TryParse([string]$_.Exception.Data["SaphirHttpStatusCode"], [ref]$requestFailureStatus) | Out-Null
            }

            if (@(400, 408, 413) -contains $requestFailureStatus) {
                # Only request-reader validation errors carry this marker; its
                # message is safe for the client. Persistent-data exceptions
                # remain generic 500 responses below.
                respondWithError $response $requestFailureStatus ([string]$_.Exception.Message)
            }
            elseif ($requestFailureStatus -eq 503) {
                # Never expose shared-drive paths or localized OS details.
                # Clients receive a stable transient response they can present
                # without automatically repeating a possibly committed write.
                $response.Headers["Retry-After"] = "1"
                Write-Warning ("Shared data request temporarily unavailable: {0}" -f $_.Exception.Message)
                respondWithError $response 503 "The shared data folder is temporarily unavailable. Please try again."
            }
            else {
                Write-Warning ("Unhandled HTTP request failure: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "The server could not complete this request."
            }
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}

Write-Host "SAPHIR Server stopped."
