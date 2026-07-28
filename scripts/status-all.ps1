#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath "lib/ServerControl.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/RuntimeLayout.ps1")

$service = Get-ManagedServiceConfig -Name "app"
[void](Show-ServiceStatus -Name $service.Name -DisplayName $service.DisplayName -Port $service.Port -PidFile $service.PidFile)

foreach ($previousService in @(Get-PreviousProductServiceConfigs)) {
    $previousStatus = Get-ServiceStatus -Name $previousService.Name -DisplayName $previousService.DisplayName -Port $previousService.Port -PidFile $previousService.PidFile
    if ($previousStatus.Metadata) {
        [void](Show-ServiceStatus -Name $previousService.Name -DisplayName $previousService.DisplayName -Port $previousService.Port -PidFile $previousService.PidFile)
    }
}

foreach ($legacyService in Get-LegacyServiceConfigs) {
    $legacyStatus = Get-ServiceStatus -Name $legacyService.Name -DisplayName $legacyService.DisplayName -Port $legacyService.Port -PidFile $legacyService.PidFile
    if ($legacyStatus.Metadata) {
        [void](Show-ServiceStatus -Name $legacyService.Name -DisplayName $legacyService.DisplayName -Port $legacyService.Port -PidFile $legacyService.PidFile)
    }
}
