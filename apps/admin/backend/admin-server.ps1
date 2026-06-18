# admin-server.ps1

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# Shared context + helpers + services
. (Join-Path -Path $scriptDir -ChildPath "lib/AdminContext.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/CommonHelpers.ps1")
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
. (Join-Path -Path $scriptDir -ChildPath "services/Gc179ExportService.ps1")

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
@(
    "routes/frontend.routes.ps1",
    "routes/auth.routes.ps1",
    "routes/sync.routes.ps1",
    "routes/seed.routes.ps1",
    "routes/self.routes.ps1",
    "routes/history.routes.ps1",
    "routes/dashboard.routes.ps1",
    "routes/employee.routes.ps1",
    "routes/employee/list.routes.ps1",
    "routes/employee/create-record.routes.ps1",
    "routes/employee/update-record.routes.ps1",
    "routes/employee/delete-record.routes.ps1",
    "routes/employee/restore-record.routes.ps1",
    "routes/employee/password.routes.ps1",
    "routes/employee/get.routes.ps1",
    "routes/employee/add.routes.ps1",
    "routes/employee/update.routes.ps1",
    "routes/employee/batch-approval.routes.ps1",
    "routes/employee/approval.routes.ps1",
    "routes/employee/message.routes.ps1",
    "routes/employee/delete.routes.ps1",
    "routes/project.routes.ps1",
    "routes/projects/get.routes.ps1",
    "routes/projects/bootstrap.routes.ps1",
    "routes/projects/add.routes.ps1",
    "routes/projects/update.routes.ps1",
    "routes/projects/delete.routes.ps1",
    "routes/project-stats.routes.ps1",
    "routes/stats/summary.routes.ps1",
    "routes/stats/trends.routes.ps1",
    "routes/stats/detail.routes.ps1"
) | ForEach-Object { Register-RouteScriptBlock -RelativePath $_ }

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

        # Route handlers are compiled once at startup so every request avoids
        # re-reading dozens of .ps1 route files from slow disks or network paths.
        . $script:RouteScriptBlocks["routes/frontend.routes.ps1"]
        . $script:RouteScriptBlocks["routes/auth.routes.ps1"]
        . $script:RouteScriptBlocks["routes/sync.routes.ps1"]
        . $script:RouteScriptBlocks["routes/seed.routes.ps1"]
        . $script:RouteScriptBlocks["routes/self.routes.ps1"]
        . $script:RouteScriptBlocks["routes/history.routes.ps1"]
        . $script:RouteScriptBlocks["routes/dashboard.routes.ps1"]
        . $script:RouteScriptBlocks["routes/employee.routes.ps1"]
        . $script:RouteScriptBlocks["routes/project.routes.ps1"]
        . $script:RouteScriptBlocks["routes/project-stats.routes.ps1"]

        respondWithError $response 400 "Invalid request"
    }
    catch {
        respondWithError $response 500 $_.Exception.Message
    }
}
