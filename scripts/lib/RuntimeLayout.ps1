$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$scriptsRoot = Split-Path -Path $scriptDir -Parent
$repoRoot = (Resolve-Path (Join-Path $scriptsRoot "..")).Path
$runtimeRoot = Join-Path -Path $repoRoot -ChildPath "runtime"
$pidRoot = Join-Path -Path $runtimeRoot -ChildPath "pids"
$logRoot = Join-Path -Path $runtimeRoot -ChildPath "logs"

Ensure-Directory -Path $runtimeRoot
Ensure-Directory -Path $pidRoot
Ensure-Directory -Path $logRoot

function Get-ManagedServiceConfig {
    param([Parameter(Mandatory = $true)][ValidateSet("app")] [string]$Name)

    return [PSCustomObject]@{
        Name             = "app"
        DisplayName      = "Overtime Manager Backend"
        Port             = 8081
        ServerScript     = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/admin-server.ps1"
        PidFile          = Join-Path -Path $pidRoot -ChildPath "app.pid.json"
        StdOutLog        = Join-Path -Path $logRoot -ChildPath "app.stdout.log"
        StdErrLog        = Join-Path -Path $logRoot -ChildPath "app.stderr.log"
        WorkingDirectory = $repoRoot
        FrontendUrl      = "http://localhost:8081/"
        FrontendPath     = Join-Path -Path $repoRoot -ChildPath "apps/admin/frontend/index.html"
    }
}

function Get-LegacyServiceConfigs {
    return @(
        [PSCustomObject]@{
            Name        = "employee-legacy"
            DisplayName = "Legacy Employee Backend"
            Port        = 8080
            PidFile     = Join-Path -Path $pidRoot -ChildPath "employee.pid.json"
        }
    )
}

function Get-LegacyMetadataFiles {
    return @(
        (Join-Path -Path $pidRoot -ChildPath "admin.pid.json"),
        (Join-Path -Path $pidRoot -ChildPath "employee.pid.json")
    )
}
