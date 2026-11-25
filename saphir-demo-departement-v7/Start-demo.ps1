[CmdletBinding()]
param([switch]$NoBrowser, [switch]$Stop)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "scripts/lib/ServerControl.ps1")
$backend = Join-Path $PSScriptRoot "app/backend"
$config = Import-PowerShellDataFile (Join-Path $backend "saphir-config.psd1")
$url = [uri]$config.ListenerPrefix
if ($url.Scheme -ne "http" -or $url.Host -ne "localhost") {
    throw "The demo must listen on localhost."
}
$runtime = Join-Path $PSScriptRoot "runtime"
$service = @{
    Name = "department-demo"
    DisplayName = "SAPHIR - Demo"
    ServerScript = Join-Path $backend "saphir-server.ps1"
    Port = $url.Port
    PidFile = Join-Path $runtime "demo.pid.json"
}
if ($Stop) {
    Stop-ManagedService @service | Out-Null
    return
}
Start-ManagedService @service -WorkingDirectory $PSScriptRoot `
    -StdOutLog (Join-Path $runtime "demo.stdout.log") `
    -StdErrLog (Join-Path $runtime "demo.stderr.log") | Out-Null
Write-Host "SAPHIR (demo) : $($url.AbsoluteUri)"
if (-not $NoBrowser) { Open-UriInDefaultBrowser -Uri $url.AbsoluteUri }
