# Initializes shared backend context variables for the unified application.
$backendRoot = Split-Path -Path $PSScriptRoot -Parent
$appRoot = Split-Path -Path $backendRoot -Parent
$repoRoot = Split-Path -Path $appRoot -Parent
$scriptDir = $backendRoot
$configPath = Join-Path -Path $backendRoot -ChildPath "saphir-config.psd1"
$frontendRoot = Join-Path -Path $appRoot -ChildPath "frontend"
$frontendDefaultDocument = Join-Path -Path $frontendRoot -ChildPath "index.html"

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

$demoSeedEnabled = $config.ContainsKey("EnableDemoSeed") -and [bool]$config.EnableDemoSeed
$gc179ImportEnabled = $config.ContainsKey("EnableGc179Import") -and [bool]$config.EnableGc179Import
$corsAllowedOrigins = if ($config.ContainsKey("AllowedOrigins")) {
    @($config.AllowedOrigins | ForEach-Object {
        ([string]$_).Trim().TrimEnd("/")
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
}
else {
    @()
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

# Ensure the shared folder exists without first interpreting a failed SMB
# existence probe as a missing folder. CreateDirectory is idempotent.
try {
    [System.IO.Directory]::CreateDirectory($sharedFolder) | Out-Null
}
catch {
    throw (New-Object System.IO.IOException(
        ("Unable to access or create the SAPHIR data folder: {0}" -f $sharedFolder),
        $_.Exception
    ))
}

# Initialization is a shared-data mutation too. Load the file-store primitives
# here so every entry point (server and maintenance scripts alike) uses the
# same cross-process lock and atomic writer during first startup.
$fileStorePath = Join-Path -Path $scriptDir -ChildPath "lib/FileStore.ps1"
. $fileStorePath

# Refuse incompatible future data before initializing any baseline file. Older
# folders without metadata are adopted as schema 1 without rewriting their
# existing business records.
$dataSchemaServicePath = Join-Path -Path $scriptDir -ChildPath "services/DataSchemaService.ps1"
. $dataSchemaServicePath
$dataSchema = Ensure-SaphirDataSchema

function Test-JsonFileNeedsInitialization {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-SaphirFileExists -Path $Path)) {
        return $true
    }

    try {
        $raw = Read-TextFileWithRetry -Path $Path
    }
    catch {
        Rethrow-SaphirHttpStatusException -Exception $_.Exception
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $true
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return ($null -eq $parsed)
    }
    catch {
        # Do not overwrite non-empty corrupt files automatically; they may need manual recovery.
        return $false
    }
}

function Initialize-JsonFileIfEmpty {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object]$Value,
        [int]$Depth = 6
    )

    if (-not (Test-JsonFileNeedsInitialization -Path $Path)) {
        return
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $Path
    try {
        # Another process may have initialized the resource while this process
        # was waiting for the shared lock.
        if (Test-JsonFileNeedsInitialization -Path $Path) {
            Write-JsonAtomic -Path $Path -Value $Value -Depth $Depth
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}

# Ensure history.json exists (as an empty array if missing or blank)
Initialize-JsonFileIfEmpty -Path $historyFile -Value ([object[]]@()) -Depth 2

# Ensure projects.json exists (as an array of project objects) in the shared folder.
$projectsFile = Join-Path -Path $sharedFolder -ChildPath "projects.json"
# Define default projects.
$demoProjects = @(
    @{
        projectCode = "P001"
        projectName = "Project Alpha"
        sector = ""
        admins = @()
        backupAdmins = @()
        archived = $false
    },
    @{
        projectCode = "P002"
        projectName = "Project Beta"
        sector = ""
        admins = @()
        backupAdmins = @()
        archived = $false
    },
    @{
        projectCode = "P003"
        projectName = "Project Gamma"
        sector = ""
        admins = @()
        backupAdmins = @()
        archived = $false
    },
    @{
        projectCode = "P004"
        projectName = "Project Charlie"
        sector = ""
        admins = @()
        backupAdmins = @()
        archived = $false
    }
)
$defaultProjects = [object[]]@()
if ($demoSeedEnabled) {
    $defaultProjects = @($demoProjects)
}
Initialize-JsonFileIfEmpty -Path $projectsFile -Value $defaultProjects -Depth 3

# Ensure overtimeCodes.json exists (as an array of overtime code objects) in the shared folder.
$overtimeCodesFile = Join-Path -Path $sharedFolder -ChildPath "overtimeCodes.json"
$defaultOvertimeCodes = @(
    @{
        code    = ""
        labelEn = "Overtime Code"
        labelFr = "Code supp."
    },
    @{
        code    = "260"
        labelEn = "OVERTIME, Regular Working Day"
        labelFr = "HEURES SUPPLÉMENTAIRES, Jour ouvrable régulier"
    },
    @{
        code    = "261"
        labelEn = "OVERTIME, First Day of Rest"
        labelFr = "HEURES SUPPLÉMENTAIRES, Premier jour de repos"
    },
    @{
        code    = "262"
        labelEn = "OVERTIME, Second or Subsequent Day of Rest"
        labelFr = "HEURES SUPPLÉMENTAIRES, Deuxième jour de repos subséquent"
    },
    @{
        code    = "263"
        labelEn = "OVERTIME, Designated Holiday"
        labelFr = "HEURES SUPPLÉMENTAIRES, Congé férié"
    },
    @{
        code    = "089"
        labelEn = "TRAVEL TIME, Regular Working Day"
        labelFr = "TEMPS de DÉPLACEMENT, Jour ouvrable régulier"
    },
    @{
        code    = "072"
        labelEn = "TRAVEL TIME, Day of Rest"
        labelFr = "TEMPS de DÉPLACEMENT, Jour de repos"
    },
    @{
        code    = "009"
        labelEn = "CALL BACK"
        labelFr = "RAPPEL AU TRAVAIL"
    },
    @{
        code    = "050"
        labelEn = "REPORTING PAY"
        labelFr = "INDEMNITÉ DE PRÉSENCE"
    },
    @{
        code    = "049"
        labelEn = "PART TIME, Additional Hours"
        labelFr = "TEMPS PARTIEL, Heures additionnelles"
    },
    @{
        code    = "043"
        labelEn = "PART TIME, Premium Pay for Work on a Holiday"
        labelFr = "TEMPS PARTIEL, Prime pour le travail effectué lors d'un jour férié"
    }
)
Initialize-JsonFileIfEmpty -Path $overtimeCodesFile -Value $defaultOvertimeCodes -Depth 3

$paymentOptionsFile = Join-Path -Path $sharedFolder -ChildPath "paymentOptions.json"
$defaultPaymentOptions = @(
    @{
        code    = "cash"
        labelEn = "Cash"
        labelFr = "En espèce"
    },
    @{
        code    = "leave"
        labelEn = "Leave"
        labelFr = "Congé"
    }
)
Initialize-JsonFileIfEmpty -Path $paymentOptionsFile -Value $defaultPaymentOptions -Depth 3

$reasonCodesFile = Join-Path -Path $sharedFolder -ChildPath "reasonCodes.json"
$defaultReasonCodes = @(
    @{
        code    = ""
        labelEn = "Reason"
        labelFr = "Raison"
    },
    @{
        code    = "A"
        labelEn = "Emergency Situation"
        labelFr = "Situation d'urgence"
    },
    @{
        code    = "B"
        labelEn = "Cost Effectiveness"
        labelFr = "Coût-efficacité"
    },
    @{
        code    = "C"
        labelEn = "Exceptional Circumstances"
        labelFr = "Circonstances exceptionnelles"
    },
    @{
        code    = "D"
        labelEn = "Significant Workload Increases"
        labelFr = "Augmentation significative de charge de travail"
    },
    @{
        code    = "E"
        labelEn = "Unanticipated Absence"
        labelFr = "Absence imprévue"
    },
    @{
        code    = "F"
        labelEn = "Vacant Position"
        labelFr = "Poste vacant"
    },
    @{
        code    = "G"
        labelEn = "Other"
        labelFr = "Autre"
    }
)
Initialize-JsonFileIfEmpty -Path $reasonCodesFile -Value $defaultReasonCodes -Depth 3

# Ensure employeeNames mapping exists.
$mappingFile = Join-Path -Path $sharedFolder -ChildPath "employeeNames.json"
$demoMapping = @{
    "000379070" = "Peter-Nicholas Sarateanu"
    "000123123" = "Jane Smith"
    "000987654" = "Alice Johnson"
    "000456123" = "Kylian Mbappe"
    "000789123" = "Joe Burrow"
}
$defaultMapping = if ($demoSeedEnabled) { $demoMapping } else { @{} }
Initialize-JsonFileIfEmpty -Path $mappingFile -Value $defaultMapping -Depth 3
