$ErrorActionPreference = "Stop"

$runningOnWindows = $PSVersionTable.PSEdition -eq "Desktop" -or
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $runningOnWindows) {
    Write-Host "Windows launcher runtime smoke skipped on this operating system."
    return
}

$repoRoot = (Get-Item -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$launcherEntryPath = Join-Path -Path $repoRoot -ChildPath "SAPHIR Launcher.vbs"
$cscriptPath = Join-Path -Path ([string]$env:SystemRoot) -ChildPath "System32/cscript.exe"
$localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
$launcherLogPath = Join-Path -Path $localAppData -ChildPath "SAPHIR/runtime/logs/launcher-startup.log"

if (-not (Test-Path -LiteralPath $launcherEntryPath -PathType Leaf)) {
    throw "Windows launcher entry point is missing: $launcherEntryPath"
}
if (-not (Test-Path -LiteralPath $cscriptPath -PathType Leaf)) {
    throw "Windows Script Host is unavailable: $cscriptPath"
}

$previousValidationMode = [System.Environment]::GetEnvironmentVariable(
    "SAPHIR_LAUNCHER_VALIDATE_ONLY",
    [System.EnvironmentVariableTarget]::Process
)
try {
    [System.Environment]::SetEnvironmentVariable(
        "SAPHIR_LAUNCHER_VALIDATE_ONLY",
        "1",
        [System.EnvironmentVariableTarget]::Process
    )
    if (Test-Path -LiteralPath $launcherLogPath -PathType Leaf) {
        Remove-Item -LiteralPath $launcherLogPath -Force
    }

    $launcherOutput = @(& $cscriptPath "//nologo" $launcherEntryPath 2>&1)
    $launcherExitCode = [int]$LASTEXITCODE
    if ($launcherExitCode -ne 0) {
        throw "The VBS/Windows PowerShell/WPF startup smoke failed with exit code $launcherExitCode. $($launcherOutput -join ' ')"
    }
    if (-not (Test-Path -LiteralPath $launcherLogPath -PathType Leaf)) {
        throw "The hidden launcher process did not create its startup diagnostic log."
    }

    $launcherLog = Get-Content -LiteralPath $launcherLogPath -Raw
    if ($launcherLog -notmatch "SAPHIR launcher validation passed") {
        throw "The launcher did not complete WPF validation. Log: $launcherLog"
    }
}
finally {
    [System.Environment]::SetEnvironmentVariable(
        "SAPHIR_LAUNCHER_VALIDATE_ONLY",
        $previousValidationMode,
        [System.EnvironmentVariableTarget]::Process
    )
}

Write-Host "Windows launcher VBS, PowerShell 5.1 and WPF runtime smoke passed."
