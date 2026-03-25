$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath "lib/ServerControl.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/RuntimeLayout.ps1")

$service = Get-ManagedServiceConfig -Name "app"
[void](Stop-ManagedService -Name $service.Name -DisplayName $service.DisplayName -Port $service.Port -PidFile $service.PidFile -Quiet)

foreach ($legacyService in Get-LegacyServiceConfigs) {
    if (Read-ServiceMetadata -PidFile $legacyService.PidFile) {
        [void](Stop-ManagedService -Name $legacyService.Name -DisplayName $legacyService.DisplayName -Port $legacyService.Port -PidFile $legacyService.PidFile -Quiet)
    }
}

foreach ($legacyPidFile in Get-LegacyMetadataFiles) {
    Remove-ServiceMetadata -PidFile $legacyPidFile
}

Write-Host "Stopped the unified backend and cleaned up legacy listeners."
