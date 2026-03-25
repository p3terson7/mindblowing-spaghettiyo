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
$status = Get-ServiceStatus -Name $service.Name -DisplayName $service.DisplayName -Port $service.Port -PidFile $service.PidFile
if (-not ($status.IsRunning -and (Test-FrontendUrlAvailable -Url $service.FrontendUrl))) {
    Start-ManagedService -Name $service.Name -DisplayName $service.DisplayName -ServerScript $service.ServerScript -Port $service.Port -PidFile $service.PidFile -StdOutLog $service.StdOutLog -StdErrLog $service.StdErrLog -WorkingDirectory $service.WorkingDirectory -Force:$Force | Out-Null
}
else {
    Write-Host "$($service.DisplayName) is already available at $($service.FrontendUrl)."
}

Write-Host ""
Write-Host "Opening GÉEM..."
Open-UriInDefaultBrowser -Uri $service.FrontendUrl
Write-Host "GÉEM is ready at $($service.FrontendUrl)"
