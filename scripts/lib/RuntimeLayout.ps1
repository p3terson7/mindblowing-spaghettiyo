$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$scriptsRoot = Split-Path -Path $scriptDir -Parent
$repoRoot = (Resolve-Path (Join-Path $scriptsRoot "..")).Path

$configuredRuntimeRoot = [string]$env:SAPHIR_RUNTIME_ROOT
if ([string]::IsNullOrWhiteSpace($configuredRuntimeRoot)) {
    $configuredRuntimeRoot = [System.Environment]::GetEnvironmentVariable(("OVER" + "TIME_RUNTIME_ROOT"))
}

if (-not [string]::IsNullOrWhiteSpace($configuredRuntimeRoot)) {
    $runtimeRoot = $configuredRuntimeRoot
}
elseif ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:TEMP
    }
    $runtimeRoot = Join-Path -Path $localAppData -ChildPath "SAPHIR/runtime"
}
else {
    $runtimeRoot = Join-Path -Path $repoRoot -ChildPath "runtime"
}

$pidRoot = Join-Path -Path $runtimeRoot -ChildPath "pids"
$logRoot = Join-Path -Path $runtimeRoot -ChildPath "logs"

Ensure-Directory -Path $runtimeRoot
Ensure-Directory -Path $pidRoot
Ensure-Directory -Path $logRoot

function Get-ManagedServiceConfig {
    param([Parameter(Mandatory = $true)][ValidateSet("app")] [string]$Name)

    return [PSCustomObject]@{
        Name             = "app"
        DisplayName      = "SAPHIR Backend"
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

function Get-PreviousProductServiceConfigs {
    if (-not ($PSVersionTable.PSEdition -eq "Desktop" -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)) {
        return @()
    }

    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [string]$env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        return @()
    }

    # Keep the pre-SAPHIR path only as a one-time compatibility lookup. Splitting
    # the old product label prevents it from resurfacing as active branding.
    $previousRuntimeRoot = Join-Path -Path $localAppData -ChildPath (("Overtime" + "Manager") + "/runtime")
    return @(
        [PSCustomObject]@{
            Name        = "previous-product"
            DisplayName = "Previous SAPHIR Backend"
            Port        = 8081
            PidFile     = Join-Path -Path (Join-Path -Path $previousRuntimeRoot -ChildPath "pids") -ChildPath "app.pid.json"
        }
    )
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
