param([switch]$Isolated)
$ErrorActionPreference = 'Stop'
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw 'Launcher auto-update regression failed.' }; return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'scripts/lib/LauncherUpdate.ps1')
$owned = Join-Path ([IO.Path]::GetTempPath()) ('launcher-auto-' + [guid]::NewGuid().ToString('N'))
$distribution = Join-Path $owned 'distribution'
$launcher = Join-Path $owned 'launcher'
function Assert-LauncherUpdate($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    [IO.Directory]::CreateDirectory((Join-Path $distribution 'deployment/launcher')) | Out-Null
    [IO.Directory]::CreateDirectory($launcher) | Out-Null
    $versionPath = Join-Path $distribution 'deployment/launcher/launcher-version.txt'
    $localVersion = Join-Path $launcher 'launcher-version.txt'
    $installer = Join-Path $distribution 'deployment/launcher/Install SAPHIR Shortcut.vbs'
    [IO.File]::WriteAllText($installer, 'fixture installer')
    [IO.File]::WriteAllText($versionPath, ('a' * 64))
    [IO.File]::WriteAllText($localVersion, ('a' * 64))
    $script:installed = 0; $script:fail = $false
    function Invoke-SaphirLauncherInstaller {
        param([string]$InstallerPath)
        Assert-LauncherUpdate ($InstallerPath -eq $installer) 'Update did not use the published distribution installer.'
        $script:installed++
        if ($script:fail) { throw 'simulated install failure' }
        [IO.File]::WriteAllText($localVersion, [IO.File]::ReadAllText($versionPath))
    }
    Assert-LauncherUpdate ((Update-SaphirLauncherFromDistribution $distribution $launcher) -eq 'current' -and $script:installed -eq 0) 'An unchanged launcher was unnecessarily reinstalled.'
    [IO.File]::WriteAllText($versionPath, ('b' * 64))
    Assert-LauncherUpdate ((Update-SaphirLauncherFromDistribution $distribution $launcher) -eq 'updated' -and $script:installed -eq 1) 'A changed launcher was not installed automatically.'
    $lockPath = Join-Path $launcher '.update-check.lock'
    [IO.File]::WriteAllText($lockPath, 'host update active')
    Assert-LauncherUpdate ((Update-SaphirLauncherFromDistribution $distribution $launcher) -eq 'busy' -and $script:installed -eq 1) 'Parallel update checks did not share the stable host lock.'
    [IO.File]::Delete($lockPath)
    [IO.File]::WriteAllText($versionPath, ('c' * 64)); $script:fail = $true; $caught = $false
    try { Update-SaphirLauncherFromDistribution $distribution $launcher | Out-Null } catch { $caught = $_.Exception.Message -eq 'simulated install failure' }
    Assert-LauncherUpdate ($caught -and [IO.File]::ReadAllText($localVersion) -eq ('b' * 64) -and -not [IO.File]::Exists($lockPath)) 'Installer failure changed the old version or retained the lock.'
    $script:fail = $false
    Assert-LauncherUpdate ((Update-SaphirLauncherFromDistribution $distribution $launcher) -eq 'updated') 'An update could not retry after failure.'
    [IO.File]::WriteAllText($versionPath, 'invalid'); $caught = $false
    try { Update-SaphirLauncherFromDistribution $distribution $launcher | Out-Null } catch { $caught = $true }
    Assert-LauncherUpdate $caught 'Invalid launcher fingerprints must not run an installer.'
    $launchSource = [IO.File]::ReadAllText((Join-Path $repo 'scripts/launch-app.ps1'))
    Assert-LauncherUpdate ($launchSource.IndexOf('Start-SaphirLauncherUpdateCheck -ApplicationRoot') -gt $launchSource.IndexOf('Write-Host "SAPHIR is ready at')) 'Launcher check must run after app readiness.'
    $vbs = [IO.File]::ReadAllText((Join-Path $repo 'deploy/bootstrap/Install SAPHIR Shortcut.vbs'))
    Assert-LauncherUpdate ($vbs.Contains('If Not automaticInstall And fso.FileExists(localApplicationLayoutPath)') -and $vbs.Contains('WScript.Echo message')) 'Automatic installs must not reset failed releases or show blocking prompts.'
    Write-Host 'Launcher auto-update passed: same/changed fingerprints, shared lock, failure preservation, retry, validation, post-readiness integration and noninteractive installation.'
} finally {
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
