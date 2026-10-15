[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$backendDir = Join-Path -Path $repoRoot -ChildPath "app/backend"

if (-not (Test-Path -Path $backendDir)) {
    throw "Unable to locate backend folder at $backendDir"
}

$scriptDir = $backendDir
. (Join-Path -Path $backendDir -ChildPath "lib/AppContext.ps1")
. (Join-Path -Path $backendDir -ChildPath "lib/FileStore.ps1")
. (Join-Path -Path $backendDir -ChildPath "services/SyncService.ps1")

function Write-JsonLocked {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Value,
        [int]$Depth = 8
    )

    $lockHandle = Acquire-ResourceLock -ResourcePath $Path
    try {
        Write-JsonAtomic -Path $Path -Value $Value -Depth $Depth
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

$projectCount = @(Read-JsonArrayFile -Path $projectsFile).Count

Write-Host "Data folder: $sharedFolder"
Write-Host "Projects file: $projectsFile"
Write-Host "Current project count: $projectCount"

if (-not $Force) {
    Write-Host ""
    Write-Host "This will clear all projects from projects.json."
    Write-Host "Employee records, time entries, users, and history will not be deleted."
    $confirmation = Read-Host "Type CLEAR to continue"
    if ($confirmation -ne "CLEAR") {
        Write-Host "Cancelled."
        exit 0
    }
}

Write-JsonLocked -Path $projectsFile -Value ([object[]]@()) -Depth 8
[void](Publish-DataChange -Category "project" -Resource "clear-projects")

Write-Host "Cleared $projectCount project(s)."
