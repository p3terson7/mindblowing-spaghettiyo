$repoRoot = (Get-Item -Path $scriptDir).Parent.Parent.Parent.FullName
$configPath = Join-Path -Path $scriptDir -ChildPath "employee-config.psd1"

$config = @{}
if (Test-Path -Path $configPath) {
    $config = Import-PowerShellDataFile -Path $configPath
}
if (-not $config) {
    $config = @{}
}

$listenerPrefix = if ($config.ContainsKey("ListenerPrefix") -and -not [string]::IsNullOrWhiteSpace([string]$config.ListenerPrefix)) {
    [string]$config.ListenerPrefix
}
else {
    "http://localhost:8080/"
}
if ($listenerPrefix[-1] -ne "/") {
    $listenerPrefix += "/"
}

$configuredDataFolder = if ($config.ContainsKey("DataFolderPath") -and -not [string]::IsNullOrWhiteSpace([string]$config.DataFolderPath)) {
    [string]$config.DataFolderPath
}
else {
    Join-Path -Path $repoRoot -ChildPath "data"
}
if ([System.IO.Path]::IsPathRooted($configuredDataFolder)) {
    $sharedFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($configuredDataFolder)
}
else {
    $sharedFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path -Path $scriptDir -ChildPath $configuredDataFolder))
}

$lockFolder = Join-Path -Path $sharedFolder -ChildPath ".locks"
$historyFile = Join-Path -Path $sharedFolder -ChildPath "history.json"
$projectsFile = Join-Path -Path $sharedFolder -ChildPath "projects.json"
$mappingFile = Join-Path -Path $sharedFolder -ChildPath "employeeNames.json"
$usersFile = Join-Path -Path $sharedFolder -ChildPath "users.json"
$sessionsFile = Join-Path -Path $sharedFolder -ChildPath "sessions.json"
$syncStateFile = Join-Path -Path $sharedFolder -ChildPath "sync-state.json"
$bootstrapAdminUsername = if ($config.ContainsKey("BootstrapAdminUsername") -and -not [string]::IsNullOrWhiteSpace([string]$config.BootstrapAdminUsername)) {
    [string]$config.BootstrapAdminUsername
}
else {
    "admin"
}
$bootstrapAdminPassword = if ($config.ContainsKey("BootstrapAdminPassword") -and -not [string]::IsNullOrWhiteSpace([string]$config.BootstrapAdminPassword)) {
    [string]$config.BootstrapAdminPassword
}
else {
    "ChangeMe123!"
}

if (!(Test-Path -Path $sharedFolder)) {
    New-Item -ItemType Directory -Path $sharedFolder | Out-Null
}

if (!(Test-Path -Path $historyFile)) {
    @() | ConvertTo-Json -Depth 2 | Set-Content -Path $historyFile -Encoding UTF8
}

if (!(Test-Path -Path $projectsFile)) {
    $defaultProjects = @(
        @{
            projectCode = "P001"
            projectName = "Project Alpha"
        },
        @{
            projectCode = "P002"
            projectName = "Project Beta"
        },
        @{
            projectCode = "P003"
            projectName = "Project Gamma"
        },
        @{
            projectCode = "P004"
            projectName = "Project Charlie"
        }
    )
    $defaultProjects | ConvertTo-Json -Depth 3 | Set-Content -Path $projectsFile -Encoding UTF8
}

if (!(Test-Path -Path $mappingFile)) {
    $defaultMapping = @{
        "000379070" = "Peter-Nicholas Sarateanu"
        "000123123" = "Jane Smith"
        "000987654" = "Alice Johnson"
        "000456123" = "Kylian Mbappe"
        "000789123" = "Joe Burrow"
    }
    $defaultMapping | ConvertTo-Json -Depth 3 | Set-Content -Path $mappingFile -Encoding UTF8
}
