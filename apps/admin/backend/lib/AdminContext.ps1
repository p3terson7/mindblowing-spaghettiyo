# Initializes shared backend context variables.
$repoRoot = (Get-Item -Path $scriptDir).Parent.Parent.Parent.FullName
$configPath = Join-Path -Path $scriptDir -ChildPath "admin-config.psd1"

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
    "http://localhost:8081/"
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

# Ensure shared folder exists
if (!(Test-Path -Path $sharedFolder)) {
    New-Item -ItemType Directory -Path $sharedFolder | Out-Null
}

# Ensure history.json exists (as an empty array if not)
if (!(Test-Path -Path $historyFile)) {
    @() | ConvertTo-Json -Depth 2 | Set-Content -Path $historyFile -Encoding UTF8
}

# Ensure projects.json exists (as an array of project objects) in the shared folder.
$projectsFile = Join-Path -Path $sharedFolder -ChildPath "projects.json"
if (!(Test-Path -Path $projectsFile)) {
    # Define default projects.
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
    # Save the default projects to projects.json.
    $defaultProjects | ConvertTo-Json -Depth 3 | Set-Content -Path $projectsFile -Encoding UTF8
}

# Ensure overtimeCodes.json exists (as an array of overtime code objects) in the shared folder.
$overtimeCodesFile = Join-Path -Path $sharedFolder -ChildPath "overtimeCodes.json"
if (!(Test-Path -Path $overtimeCodesFile)) {
    $defaultOvertimeCodes = @(
        @{
            code  = "OT-OPS"
            label = "Operational Support"
        },
        @{
            code  = "OT-MNT"
            label = "Maintenance Window"
        },
        @{
            code  = "OT-REL"
            label = "Release / Deployment"
        },
        @{
            code  = "OT-CLS"
            label = "Month-End / Closeout"
        }
    )
    $defaultOvertimeCodes | ConvertTo-Json -Depth 3 | Set-Content -Path $overtimeCodesFile -Encoding UTF8
}

# Ensure employeeNames mapping exists.
$mappingFile = Join-Path -Path $sharedFolder -ChildPath "employeeNames.json"
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
