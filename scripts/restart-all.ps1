$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

& (Join-Path -Path $scriptDir -ChildPath "stop-all.ps1")
& (Join-Path -Path $scriptDir -ChildPath "start-all.ps1")
