$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$owned = Join-Path ([IO.Path]::GetTempPath()) ("saphir-capture-launch-" + [Guid]::NewGuid().ToString("N"))
$saved = @{}
foreach ($name in @("SAPHIR_PERFORMANCE_TRACE", "SAPHIR_PERF_TRACE", "SAPHIR_TRACE_LEVEL")) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Assert-Capture { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
try {
    $scripts = Join-Path $owned "scripts"
    [IO.Directory]::CreateDirectory($scripts) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $owned "deployment")) | Out-Null
    [IO.File]::WriteAllText((Join-Path $owned "deployment/current.json"), '{}')
    Copy-Item (Join-Path $repo "scripts/start-performance-capture.ps1") (Join-Path $scripts "start-performance-capture.ps1")
    # Stub only process startup: this test must never restart a real backend.
    $stub = @'
param([switch]$Force, [switch]$NoBrowser)
if (-not $Force -or -not $NoBrowser) { throw "Capture did not use safe restart flags." }
if ($env:SAPHIR_PERFORMANCE_TRACE -ne "1" -or $env:SAPHIR_PERF_TRACE -ne "1") { throw "Tracing was not inherited by launcher." }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "selected.txt"), ([IO.Path]::GetFileName($PSCommandPath) + ":" + $env:SAPHIR_TRACE_LEVEL))
'@
    [IO.File]::WriteAllText((Join-Path $scripts "launch-cached-app.ps1"), $stub)
    [IO.File]::WriteAllText((Join-Path $scripts "launch-app.ps1"), $stub)
    $env:SAPHIR_PERFORMANCE_TRACE = "before"; $env:SAPHIR_PERF_TRACE = "before-legacy"; $env:SAPHIR_TRACE_LEVEL = "before-level"
    & (Join-Path $scripts "start-performance-capture.ps1") -Level summary -NoBrowser
    Assert-Capture ([IO.File]::ReadAllText((Join-Path $scripts "selected.txt")) -eq "launch-cached-app.ps1:summary") "Deployment did not use published-release launcher."
    Assert-Capture ($env:SAPHIR_PERFORMANCE_TRACE -eq "before" -and $env:SAPHIR_PERF_TRACE -eq "before-legacy" -and $env:SAPHIR_TRACE_LEVEL -eq "before-level") "Capture persisted diagnostic environment changes."

    [IO.Directory]::CreateDirectory((Join-Path $owned "app/backend")) | Out-Null
    [IO.File]::WriteAllText((Join-Path $owned "app/backend/saphir-server.ps1"), '# fixture')
    & (Join-Path $scripts "start-performance-capture.ps1") -Level detailed -NoBrowser
    Assert-Capture ([IO.File]::ReadAllText((Join-Path $scripts "selected.txt")) -eq "launch-app.ps1:detailed") "Installed application launch path regressed."

    [IO.File]::WriteAllText((Join-Path $scripts "launch-app.ps1"), 'throw "Expected launch failure"')
    $failed = $false
    try { & (Join-Path $scripts "start-performance-capture.ps1") -NoBrowser } catch { $failed = $_.Exception.Message -eq "Expected launch failure" }
    Assert-Capture $failed "Launch failures were swallowed."
    Assert-Capture ($env:SAPHIR_PERFORMANCE_TRACE -eq "before" -and $env:SAPHIR_TRACE_LEVEL -eq "before-level") "Failed launch leaked tracing environment."
    Write-Host "Deployed performance capture tests passed."
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
