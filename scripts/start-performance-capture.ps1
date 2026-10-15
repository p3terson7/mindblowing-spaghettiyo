param([ValidateSet("summary", "detailed")][string]$Level = "detailed", [switch]$NoBrowser)
$ErrorActionPreference = "Stop"
$applicationRoot = Split-Path $PSScriptRoot -Parent
$launchScript = Join-Path $PSScriptRoot "launch-app.ps1"
if (-not (Test-Path -LiteralPath (Join-Path $applicationRoot "app/backend/saphir-server.ps1") -PathType Leaf)) {
    # Share-side deployments contain the bootstrap, not the application itself.
    # Use the normal cached launcher to select/install the published release and
    # preserve its real shared DATA configuration and runtime ownership checks.
    if (-not (Test-Path -LiteralPath (Join-Path $applicationRoot "deployment/current.json") -PathType Leaf)) {
        throw "No published SAPHIR release found. Run this from the deployed SAPHIR-Distribution folder or an installed application folder."
    }
    $launchScript = Join-Path $PSScriptRoot "launch-cached-app.ps1"
}
if (-not (Test-Path -LiteralPath $launchScript -PathType Leaf)) {
    throw "The SAPHIR launch script is missing: $launchScript"
}
$savedTrace = $env:SAPHIR_PERFORMANCE_TRACE
$savedLegacy = $env:SAPHIR_PERF_TRACE
$savedLevel = $env:SAPHIR_TRACE_LEVEL
try {
    $env:SAPHIR_PERFORMANCE_TRACE = "1"
    $env:SAPHIR_PERF_TRACE = "1"
    $env:SAPHIR_TRACE_LEVEL = $Level
    # Force only the existing verified SAPHIR backend through its normal
    # launcher safety checks. No shared configuration or DATA file is changed.
    & $launchScript -Force -NoBrowser
    if (-not $?) { throw "SAPHIR could not start; performance capture was not enabled." }
    if (-not $NoBrowser) {
        . (Join-Path $PSScriptRoot "lib/ServerControl.ps1")
        Open-UriInDefaultBrowser -Uri ("http://localhost:8081/?saphirTrace=" + $Level)
    }
    $directory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "SAPHIR/diagnostics/performance"
    Write-Host "Performance capture is enabled for this backend process."
    Write-Host "Local traces: $directory"
    Write-Host "Use 'Export performance trace' in the browser after loading finishes."
    Write-Host "To stop tracing, restart SAPHIR normally without diagnostic environment variables."
} finally {
    $env:SAPHIR_PERFORMANCE_TRACE = $savedTrace; $env:SAPHIR_PERF_TRACE = $savedLegacy; $env:SAPHIR_TRACE_LEVEL = $savedLevel
}
