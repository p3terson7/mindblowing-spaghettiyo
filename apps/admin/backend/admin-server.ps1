# admin-server.ps1

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# Shared context + helpers + services
. (Join-Path -Path $scriptDir -ChildPath "lib/AdminContext.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/CommonHelpers.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/FileStore.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/ResponseHelpers.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/AuthService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/ReadModelService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/EmployeeDirectoryService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/SyncService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/ProjectStatsService.ps1")
. (Join-Path -Path $scriptDir -ChildPath "services/HistoryService.ps1")

# Initialize HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($listenerPrefix)
try {
    $listener.Start()
}
catch {
    throw "Failed to start admin listener on $listenerPrefix. $($_.Exception.Message)"
}
Write-Host "Manager Server running on $listenerPrefix"

while ($true) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    try {
        $response.Headers.Add("Access-Control-Allow-Origin", "*")

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS, PUT, DELETE, POST")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization")
            respondWithSuccess $response '{}'
            continue
        }

        # Route handlers (continue in dot-sourced files returns to loop)
        . (Join-Path -Path $scriptDir -ChildPath "routes/frontend.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/auth.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/sync.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/self.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/history.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/dashboard.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/employee.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/project.routes.ps1")
        . (Join-Path -Path $scriptDir -ChildPath "routes/project-stats.routes.ps1")

        respondWithError $response 400 "Invalid request"
    }
    catch {
        respondWithError $response 500 $_.Exception.Message
    }
}
