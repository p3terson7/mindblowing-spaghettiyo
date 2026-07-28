param([switch]$Force)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path -Path $scriptDir -ChildPath "lib/ServerControl.ps1")
. (Join-Path -Path $scriptDir -ChildPath "lib/RuntimeLayout.ps1")

function Test-FrontendUrlAvailable {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = 3000
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $response.Close()
        return ($statusCode -ge 200 -and $statusCode -lt 400)
    }
    catch {
        return $false
    }
}

$service = Get-ManagedServiceConfig -Name "app"

# A backend started before the SAPHIR rebrand is tracked under the previous
# AppData root. Stop only that verified PID before inspecting the shared port;
# an unrelated process on 8081 remains protected by ServerControl.
foreach ($previousService in @(Get-PreviousProductServiceConfigs)) {
    $previousStatus = Get-ServiceStatus -Name $previousService.Name -DisplayName $previousService.DisplayName -Port $previousService.Port -PidFile $previousService.PidFile
    if ($previousStatus.TrackedProcessId) {
        Write-Host "Stopping a verified pre-SAPHIR backend..."
        [void](Stop-ManagedService -Name $previousService.Name -DisplayName $previousService.DisplayName -Port $previousService.Port -PidFile $previousService.PidFile -Quiet)
    }
}

$status = Get-ServiceStatus -Name $service.Name -DisplayName $service.DisplayName -Port $service.Port -PidFile $service.PidFile
$expectedScriptPath = [System.IO.Path]::GetFullPath($service.ServerScript)
$trackedScriptPath = if ($status.Metadata -and $status.Metadata.scriptPath) {
    try { [System.IO.Path]::GetFullPath([string]$status.Metadata.scriptPath) } catch { "" }
}
else {
    ""
}
$scriptPathComparison = if (Test-IsWindowsHost) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
$isExpectedManagedInstance = $status.TrackedProcessId -and
    -not [string]::IsNullOrWhiteSpace($trackedScriptPath) -and
    $trackedScriptPath.Equals($expectedScriptPath, $scriptPathComparison)
$frontendIsAvailable = $isExpectedManagedInstance -and (Test-ManagedServiceHealthyForScript `
    -Name $service.Name `
    -DisplayName $service.DisplayName `
    -ServerScript $service.ServerScript `
    -Port $service.Port `
    -PidFile $service.PidFile `
    -FrontendUrl $service.FrontendUrl `
    -TimeoutMilliseconds 3000)
$launchPlan = Get-ManagedServiceLaunchPlan `
    -IsRunning ([bool]$status.IsRunning) `
    -HasTrackedProcess ([bool]$status.TrackedProcessId) `
    -IsExpectedManagedInstance ([bool]$isExpectedManagedInstance) `
    -FrontendIsAvailable ([bool]$frontendIsAvailable) `
    -Force:$Force

if ($launchPlan.Action -eq "Reuse") {
    Write-Host "$($service.DisplayName) is already available at $($service.FrontendUrl)."
}
else {
    if ($launchPlan.Action -eq "Block") {
        throw "Port $($service.Port) is already used by another program. SAPHIR did not stop or replace that program."
    }

    Start-ManagedService -Name $service.Name -DisplayName $service.DisplayName -ServerScript $service.ServerScript -Port $service.Port -PidFile $service.PidFile -StdOutLog $service.StdOutLog -StdErrLog $service.StdErrLog -WorkingDirectory $service.WorkingDirectory -Force:([bool]$launchPlan.ForceRestart) | Out-Null
}

if (-not (Test-FrontendUrlAvailable -Url $service.FrontendUrl)) {
    try {
        [void](Stop-ManagedService -Name $service.Name -DisplayName $service.DisplayName -Port $service.Port -PidFile $service.PidFile -ServerScript $service.ServerScript -Quiet)
    }
    catch {
        Write-Warning "SAPHIR did not become ready, and its local backend could not be stopped cleanly."
    }
    throw "SAPHIR started but did not pass its local web readiness check at $($service.FrontendUrl)."
}

Write-Host ""
Write-Host "Opening SAPHIR..."
try {
    Open-UriInDefaultBrowser -Uri $service.FrontendUrl
}
catch {
    Write-Warning "SAPHIR is ready, but the browser could not be opened automatically. Open $($service.FrontendUrl) manually."
    if (Test-IsWindowsHost) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.Popup("SAPHIR is ready. Open $($service.FrontendUrl) in your browser.", 0, "SAPHIR is ready", 64)
        }
        catch {
        }
    }
}
Write-Host "SAPHIR is ready at $($service.FrontendUrl)"
