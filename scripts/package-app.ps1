param(
    [string]$OutputRoot = "",
    [string]$DataFolderPath = "",
    [switch]$NoZip
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path -Path $repoRoot -ChildPath "dist"
}

if (-not (Test-Path -Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$packageName = "SAPHIR-Pilot-$timestamp"
$packageRoot = Join-Path -Path $OutputRoot -ChildPath $packageName

if (Test-Path -Path $packageRoot) {
    Remove-Item -Path $packageRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

$itemsToCopy = @(
    "apps",
    "docs",
    "scripts",
    "README.md",
    "Launch GEEM.bat",
    "Launch GEEM.command",
    "Launch GEEM.vbs",
    "Stop GEEM.bat",
    "Stop GEEM.command",
    "Stop GEEM.vbs"
)

foreach ($item in $itemsToCopy) {
    $source = Join-Path -Path $repoRoot -ChildPath $item
    if (Test-Path -Path $source) {
        Copy-Item -Path $source -Destination (Join-Path -Path $packageRoot -ChildPath $item) -Recurse -Force
    }
}

$runtimePath = Join-Path -Path $packageRoot -ChildPath "runtime"
if (Test-Path -Path $runtimePath) {
    Remove-Item -Path $runtimePath -Recurse -Force
}

$dataPath = Join-Path -Path $packageRoot -ChildPath "data"
if (Test-Path -Path $dataPath) {
    Remove-Item -Path $dataPath -Recurse -Force
}

Get-ChildItem -Path (Join-Path -Path $packageRoot -ChildPath "scripts") -Filter "gc179-*.fdf" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

if (-not [string]::IsNullOrWhiteSpace($DataFolderPath)) {
    $configPath = Join-Path -Path $packageRoot -ChildPath "apps/admin/backend/admin-config.psd1"
    $safeDataFolderPath = [string]$DataFolderPath
    $safeDataFolderPath = $safeDataFolderPath.Replace("'", "''")
    $config = @"
@{
    ListenerPrefix = "http://localhost:8081/"
    DataFolderPath = '$safeDataFolderPath'
}
"@
    Set-Content -Path $configPath -Value $config -Encoding UTF8
}

$deploymentNotePath = Join-Path -Path $packageRoot -ChildPath "DEPLOIEMENT_EQUIPE.txt"
$configuredDataText = if ([string]::IsNullOrWhiteSpace($DataFolderPath)) { "A configurer dans apps/admin/backend/admin-config.psd1" } else { $DataFolderPath }
$deploymentNote = @"
SAPHIR - Package pilote
=======================

Utilisation rapide sur Windows
1. Extraire le dossier ZIP.
2. Double-cliquer sur Launch GEEM.bat.
3. Se connecter avec le compte fourni par l'administrateur.
4. Pour fermer le backend, double-cliquer sur Stop GEEM.bat.

Utilisation rapide sur macOS
1. Extraire le dossier ZIP.
2. Double-cliquer sur Launch GEEM.command si autorise.
3. Sinon, ouvrir Terminal dans le dossier et lancer:
   pwsh ./scripts/launch-app.ps1

Dossier de donnees
$configuredDataText

Important
- Le dossier data reel n'est pas inclus dans ce package.
- Les utilisateurs doivent pointer vers le meme dossier data partage.
- Garder une sauvegarde du dossier data avant les essais d'equipe.
- Le backend utilise le port local 8081.
- Si l'app ne demarre pas, lancer Stop GEEM.bat puis relancer Launch GEEM.bat.
"@
Set-Content -Path $deploymentNotePath -Value $deploymentNote -Encoding UTF8

$zipPath = Join-Path -Path $OutputRoot -ChildPath ($packageName + ".zip")
if (-not $NoZip) {
    if (Test-Path -Path $zipPath) {
        Remove-Item -Path $zipPath -Force
    }

    Compress-Archive -Path (Join-Path -Path $packageRoot -ChildPath "*") -DestinationPath $zipPath -Force
}

[PSCustomObject]@{
    PackageFolder = $packageRoot
    ZipPath       = if ($NoZip) { "" } else { $zipPath }
    DataFolder    = $DataFolderPath
}
