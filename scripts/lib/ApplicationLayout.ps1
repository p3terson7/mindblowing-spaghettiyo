$ErrorActionPreference = "Stop"

function Get-SaphirApplicationLayoutDefinitions {
    # Keep the new topology first. When a transition package accidentally
    # contains both trees, SAPHIR must consistently run the canonical one.
    $definitions = @()
    $definitions += [PSCustomObject]@{
        Kind                      = "Canonical"
        ServerRelativePath        = "app/backend/saphir-server.ps1"
        ConfigRelativePath        = "app/backend/saphir-config.psd1"
        BackendRelativePath       = "app/backend"
        FrontendRelativePath      = "app/frontend"
        FrontendIndexRelativePath = "app/frontend/index.html"
        RouteDispatchRelativePath = "app/backend/services/RouteDispatchService.ps1"
    }
    $definitions += [PSCustomObject]@{
        Kind                      = "Legacy"
        ServerRelativePath        = "apps/admin/backend/admin-server.ps1"
        ConfigRelativePath        = "apps/admin/backend/admin-config.psd1"
        BackendRelativePath       = "apps/admin/backend"
        FrontendRelativePath      = "apps/admin/frontend"
        FrontendIndexRelativePath = "apps/admin/frontend/index.html"
        RouteDispatchRelativePath = "apps/admin/backend/services/RouteDispatchService.ps1"
    }

    return $definitions
}

function Get-SaphirApplicationLayoutCandidates {
    param([Parameter(Mandatory = $true)][string]$ApplicationRoot)

    if ([string]::IsNullOrWhiteSpace($ApplicationRoot)) {
        throw "The SAPHIR application root is required."
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($ApplicationRoot)
    $candidates = @()
    foreach ($definition in @(Get-SaphirApplicationLayoutDefinitions)) {
        $candidates += [PSCustomObject]@{
            Kind                      = [string]$definition.Kind
            ApplicationRoot           = $resolvedRoot
            ServerRelativePath        = [string]$definition.ServerRelativePath
            ServerScript              = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRoot -ChildPath ([string]$definition.ServerRelativePath)))
            ConfigRelativePath        = [string]$definition.ConfigRelativePath
            ConfigPath                = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRoot -ChildPath ([string]$definition.ConfigRelativePath)))
            BackendRelativePath       = [string]$definition.BackendRelativePath
            BackendPath               = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRoot -ChildPath ([string]$definition.BackendRelativePath)))
            FrontendRelativePath      = [string]$definition.FrontendRelativePath
            FrontendPath              = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRoot -ChildPath ([string]$definition.FrontendRelativePath)))
            FrontendIndexRelativePath = [string]$definition.FrontendIndexRelativePath
            FrontendIndexPath         = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRoot -ChildPath ([string]$definition.FrontendIndexRelativePath)))
            RouteDispatchRelativePath = [string]$definition.RouteDispatchRelativePath
            RouteDispatchPath         = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedRoot -ChildPath ([string]$definition.RouteDispatchRelativePath)))
        }
    }

    return $candidates
}

function Test-SaphirApplicationLayout {
    param([Parameter(Mandatory = $true)]$Layout)

    if ($null -eq $Layout) {
        return $false
    }

    foreach ($requiredPath in @(
        [string]$Layout.ServerScript,
        [string]$Layout.ConfigPath,
        [string]$Layout.FrontendIndexPath,
        [string]$Layout.RouteDispatchPath
    )) {
        if ([string]::IsNullOrWhiteSpace($requiredPath) -or
            -not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Resolve-SaphirApplicationLayout {
    param(
        [Parameter(Mandatory = $true)][string]$ApplicationRoot,
        [switch]$Required
    )

    foreach ($candidate in @(Get-SaphirApplicationLayoutCandidates -ApplicationRoot $ApplicationRoot)) {
        if (Test-SaphirApplicationLayout -Layout $candidate) {
            return $candidate
        }
    }

    if ($Required) {
        throw "No complete SAPHIR application layout was found under '$ApplicationRoot'."
    }

    return $null
}
