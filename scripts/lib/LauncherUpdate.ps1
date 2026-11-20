# Shared by the published app's post-start hook and the launcher update worker.
# A running backend is never stopped/restarted by a launcher-only installation.
function Get-SaphirLauncherUpdatePlan {
    param([Parameter(Mandatory = $true)][string]$DistributionRoot,
        [Parameter(Mandatory = $true)][string]$LauncherRoot)
    $marker = Join-Path $DistributionRoot 'deployment/launcher/launcher-version.txt'
    if (-not [IO.File]::Exists($marker)) { $marker = Join-Path $DistributionRoot 'launcher-version.txt' }
    $published = [IO.File]::ReadAllText($marker).Trim()
    if ($published -notmatch '^[a-fA-F0-9]{64}$') { throw 'The published launcher fingerprint is invalid.' }
    $localMarker = Join-Path $LauncherRoot 'launcher-version.txt'
    $installed = if ([IO.File]::Exists($localMarker)) { [IO.File]::ReadAllText($localMarker).Trim() } else { '' }
    if ($installed -eq $published) { return $null }
    $installer = Join-Path $DistributionRoot 'deployment/launcher/Install SAPHIR Shortcut.vbs'
    if (-not [IO.File]::Exists($installer)) { $installer = Join-Path $DistributionRoot 'Install SAPHIR Shortcut.vbs' }
    if (-not [IO.File]::Exists($installer)) { throw 'The published launcher installer is missing.' }
    return [PSCustomObject]@{ version = $published; installer = $installer; marker = $localMarker }
}

function Invoke-SaphirLauncherInstaller {
    param([Parameter(Mandatory = $true)][string]$InstallerPath)
    $hostPath = Join-Path $env:SystemRoot 'System32/cscript.exe'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $hostPath
    $info.Arguments = '//nologo "' + $InstallerPath + '" /silent /automatic'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill() } catch { }
            throw 'The automatic launcher installation timed out. The existing launcher remains available.'
        }
        if ($process.ExitCode -ne 0) { throw ('Launcher installer failed: ' + $output.Result + ' ' + $errors.Result) }
    } finally { $process.Dispose() }
}

function Update-SaphirLauncherFromDistribution {
    param([Parameter(Mandatory = $true)][string]$DistributionRoot,
        [Parameter(Mandatory = $true)][string]$LauncherRoot)
    [IO.Directory]::CreateDirectory($LauncherRoot) | Out-Null
    $lockPath = Join-Path $LauncherRoot '.update-check.lock'
    if ([IO.File]::Exists($lockPath) -and [IO.File]::GetLastWriteTimeUtc($lockPath) -lt [DateTime]::UtcNow.AddMinutes(-15)) {
        try { [IO.File]::Delete($lockPath) } catch { }
    }
    $lock = $null
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch [IO.IOException] { return 'busy' }
    try {
        $plan = Get-SaphirLauncherUpdatePlan -DistributionRoot $DistributionRoot -LauncherRoot $LauncherRoot
        if ($null -eq $plan) { return 'current' }
        Invoke-SaphirLauncherInstaller -InstallerPath $plan.installer
        if (-not [IO.File]::Exists($plan.marker) -or [IO.File]::ReadAllText($plan.marker).Trim() -ne $plan.version) {
            throw 'The automatic installer did not activate the expected launcher version.'
        }
        return 'updated'
    } finally {
        if ($null -ne $lock) { $lock.Dispose(); [IO.File]::Delete($lockPath) }
    }
}

function Start-SaphirLauncherUpdateCheck {
    param([Parameter(Mandatory = $true)][string]$ApplicationRoot)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $originPath = Join-Path $ApplicationRoot 'scripts/launcher-origin.json'
    $workerPath = Join-Path $ApplicationRoot 'scripts/update-launcher.ps1'
    if (-not [IO.File]::Exists($originPath) -or -not [IO.File]::Exists($workerPath)) { return }
    $origin = [IO.File]::ReadAllText($originPath) | ConvertFrom-Json -ErrorAction Stop
    $localLauncher = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SAPHIR/launcher/launcher-version.txt'
    # Full releases carry the launcher fingerprint they were published with.
    # When that version is already installed, avoid even spawning a worker or
    # touching SMB. The stable host still detects later BootstrapOnly updates.
    if ([string]$origin.launcherFingerprint -match '^[a-fA-F0-9]{64}$' -and [IO.File]::Exists($localLauncher) -and [IO.File]::ReadAllText($localLauncher).Trim() -eq [string]$origin.launcherFingerprint) { return }
    # The origin is publisher-owned release metadata. Even an older cached
    # bootstrap/launcher invokes the new release's launch-app.ps1 and gets this
    # hook, so users do not have to run the source installer again.
    $hostPath = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    Start-Process -FilePath $hostPath -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $workerPath + '"')) -WindowStyle Hidden | Out-Null
}
