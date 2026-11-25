$routingModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.Routing.psd1"
Import-Module -Name $routingModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name routingModuleManifest -ErrorAction SilentlyContinue

# Compatibility facade: keep the historical functions available to callers that
# dot-source this service while the implementation lives in the pure module.
function Get-AdminRouteScriptPaths {
    return @(Saphir.Routing\Get-AdminRouteScriptPaths)
}

function Resolve-AdminTopLevelRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return (Saphir.Routing\Resolve-AdminTopLevelRouteScript -Method $Method -Path $Path)
}

function Resolve-EmployeeRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return (Saphir.Routing\Resolve-EmployeeRouteScript -Method $Method -Path $Path)
}

function Resolve-ProjectRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return (Saphir.Routing\Resolve-ProjectRouteScript -Method $Method -Path $Path)
}

function Resolve-ProjectStatsRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return (Saphir.Routing\Resolve-ProjectStatsRouteScript -Method $Method -Path $Path)
}
