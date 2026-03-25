param(
    [switch]$Background,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath "lib/ServerControl.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/RuntimeLayout.ps1")

$service = Get-ManagedServiceConfig -Name "app"

if ($Background) {
    Start-ManagedService -Name $service.Name -DisplayName $service.DisplayName -ServerScript $service.ServerScript -Port $service.Port -PidFile $service.PidFile -StdOutLog $service.StdOutLog -StdErrLog $service.StdErrLog -WorkingDirectory $service.WorkingDirectory -Force:$Force | Out-Null
    return
}

Write-Host "Starting the unified backend in the current terminal..."
& $service.ServerScript
