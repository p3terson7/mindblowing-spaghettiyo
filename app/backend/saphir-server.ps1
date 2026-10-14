# saphir-server.ps1
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$script:saphirInstanceToken = [string]$env:SAPHIR_INSTANCE_TOKEN

# Shared context + helpers + services
. (Join-Path -Path $scriptDir -ChildPath "lib/PerformanceTrace.ps1")
Start-SaphirPerformanceTrace -Name "startup"
try {
foreach ($startupScript in @(
    "lib/AppContext.ps1", "lib/CommonHelpers.ps1", "lib/ControlService.ps1", "lib/FileStore.ps1", "lib/ResponseHelpers.ps1",
    "services/AuthService.ps1", "services/EntryService.ps1", "services/ReadModelService.ps1", "services/EmployeeDirectoryService.ps1",
    "services/SyncService.ps1", "services/CompensationGridService.ps1", "services/OvertimeCostSnapshotService.ps1", "services/BudgetPeriodService.ps1",
    "services/BugReportService.ps1", "services/ProjectStatsService.ps1", "services/HistoryService.ps1", "services/SeedService.ps1",
    "services/ProjectMutationService.ps1", "services/Gc179ExportService.ps1", "services/Gc179ImportService.ps1", "services/AnalyticsReportService.ps1", "services/RouteDispatchService.ps1"
)) {
    $startupSpan = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name ("Startup.Load." + [IO.Path]::GetFileNameWithoutExtension($startupScript)) -Component "Startup" -Type "infrastructure" } else { $null }
    $startupStatus = "success"; $startupFailure = $null
    try { . (Join-Path $scriptDir $startupScript) }
    catch { $startupStatus = "error"; $startupFailure = $_; throw }
    finally { if ($startupSpan) { Stop-SaphirPerformanceSpan $startupSpan -Status $startupStatus -ErrorRecord $startupFailure } }
}
Register-SaphirPerformanceFunctions -Names @(
    "Get-AuthenticatedUserFromRequest", "Get-AuthSyncVersion", "Read-AuthArrayFileCached", "Get-UserLookupCache",
    "Get-SyncState", "Read-SyncStateFromDisk", "Sync-ReadModelCaches", "Invoke-ReadModelCache",
    "Get-EmployeeDataSnapshot", "Get-ScopedEmployeeDataSnapshot", "Get-CachedEmployeeEntriesForFile",
    "Get-EmployeeDirectoryList", "Get-ProjectStatisticsOverview", "Get-EmployeeCompensationReadEstimates",
    "Get-DashboardBootstrapModel", "Get-SelfBootstrapModel", "Write-HttpResponseSafely"
)
Register-SaphirPerformanceFunctions -BackendRoot $scriptDir

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
$routeLoadSpan = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name "Startup.CompileRoutes" -Component "Startup" -Type "infrastructure" } else { $null }
@(Get-AdminRouteScriptPaths) | ForEach-Object { Register-RouteScriptBlock -RelativePath $_ }
if ($routeLoadSpan) { Stop-SaphirPerformanceSpan $routeLoadSpan }

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
    $listenerSpan = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name "Startup.StartHttpListener" -Component "Startup" -Type "infrastructure" } else { $null }
    $listener.Start()
    if ($listenerSpan) { Stop-SaphirPerformanceSpan $listenerSpan }
}
catch {
    if ($listenerSpan) { Stop-SaphirPerformanceSpan $listenerSpan -Status "error" -ErrorRecord $_ }
    throw "Failed to start SAPHIR listener on $listenerPrefix. $($_.Exception.Message)"
}
Write-Host "SAPHIR Server running on $listenerPrefix"
Stop-SaphirPerformanceTrace -StatusCode 200

$shutdownRequested = $false
try {
    while (-not $shutdownRequested) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        Start-SaphirPerformanceTrace -Name ("{0} {1}" -f $request.HttpMethod, $request.Url.AbsolutePath)
        if ($script:SaphirPerformanceRecord) {
            $response.Headers.Add("X-SAPHIR-Trace", [string]$script:SaphirPerformanceRecord.id)
            $response.Headers.Add("X-SAPHIR-Trace-Level", [string]$script:SaphirPerformanceRecord.level)
        }

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
                $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization, X-SAPHIR-Expected-Revision, X-SAPHIR-File-Name")
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
                $dispatchSpan = if ($script:SaphirPerformanceEnabled) { Start-SaphirPerformanceSpan -Name ("Http.Dispatch." + [IO.Path]::GetFileNameWithoutExtension($routeScriptPath)) -Component "Http" -Type "dispatch" } else { $null }
                $dispatchStatus = "success"; $dispatchFailure = $null
                try { . $script:RouteScriptBlocks[$routeScriptPath] }
                catch { $dispatchStatus = "error"; $dispatchFailure = $_; throw }
                finally { if ($dispatchSpan) { Stop-SaphirPerformanceSpan $dispatchSpan -Status $dispatchStatus -ErrorRecord $dispatchFailure } }
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
        finally {
            Stop-SaphirPerformanceTrace -StatusCode ([int]$response.StatusCode)
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Close-SaphirPerformanceWriter
}

Write-Host "SAPHIR Server stopped."
}
catch {
    if ($script:SaphirPerformanceRecord) {
        Write-SaphirPerformanceEvent "error" $null @{ status = "error"; errorCategory = $_.Exception.GetType().FullName }
        Stop-SaphirPerformanceTrace -StatusCode 500
    }
    throw
}
finally { Close-SaphirPerformanceWriter }
