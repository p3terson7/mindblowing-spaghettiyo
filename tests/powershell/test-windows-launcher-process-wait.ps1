$ErrorActionPreference = "Stop"

$runningOnWindows = $PSVersionTable.PSEdition -eq "Desktop" -or
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $runningOnWindows) {
    Write-Host "Windows launcher direct-process wait test skipped on this operating system."
    return
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "scripts/lib/LauncherControl.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-launcher-wait-{0}" -f [Guid]::NewGuid().ToString("N"))
$bootstrapPath = Join-Path -Path $testRoot -ChildPath "bootstrap.ps1"
$childPidPath = Join-Path -Path $testRoot -ChildPath "child.pid"
$slowBootstrapPath = Join-Path -Path $testRoot -ChildPath "slow-bootstrap.ps1"
$slowBootstrapPidPath = Join-Path -Path $testRoot -ChildPath "slow-bootstrap.pid"
$childProcessId = 0
$slowBootstrapProcessId = 0
$previousPidPath = [string]$env:SAPHIR_LAUNCHER_CHILD_PID
$previousSlowPidPath = [string]$env:SAPHIR_LAUNCHER_SLOW_PID
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $fixtureSource = @'
$powerShellPath = Join-Path -Path ([string]$env:SystemRoot) -ChildPath "System32/WindowsPowerShell/v1.0/powershell.exe"
$child = Start-Process `
    -FilePath $powerShellPath `
    -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 30"' `
    -WindowStyle Hidden `
    -PassThru
[System.IO.File]::WriteAllText($env:SAPHIR_LAUNCHER_CHILD_PID, [string]$child.Id)
'@
    Set-Content -LiteralPath $bootstrapPath -Value $fixtureSource -Encoding ASCII
    $env:SAPHIR_LAUNCHER_CHILD_PID = $childPidPath

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-SaphirLauncherScriptProcess `
        -ScriptPath $bootstrapPath `
        -TimeoutSeconds 15
    $stopwatch.Stop()

    Assert-True `
        -Condition ($stopwatch.Elapsed.TotalSeconds -lt 10) `
        -Message "the launcher must wait only for the bootstrap process, not its long-lived backend descendant"
    Assert-True `
        -Condition (Test-Path -LiteralPath $childPidPath -PathType Leaf) `
        -Message "the bootstrap fixture must create its long-lived child process"

    $childProcessId = [int](Get-Content -LiteralPath $childPidPath -Raw)
    Assert-True `
        -Condition ($null -ne (Get-Process -Id $childProcessId -ErrorAction SilentlyContinue)) `
        -Message "the backend-like child must still be running when the bootstrap wait returns"

    $slowFixtureSource = @'
[System.IO.File]::WriteAllText($env:SAPHIR_LAUNCHER_SLOW_PID, [string]$PID)
Start-Sleep -Seconds 30
'@
    Set-Content -LiteralPath $slowBootstrapPath -Value $slowFixtureSource -Encoding ASCII
    $env:SAPHIR_LAUNCHER_SLOW_PID = $slowBootstrapPidPath
    $timeoutError = ""
    $timeoutStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-SaphirLauncherScriptProcess `
            -ScriptPath $slowBootstrapPath `
            -TimeoutSeconds 5
    }
    catch {
        $timeoutError = [string]$_.Exception.Message
    }
    $timeoutStopwatch.Stop()

    Assert-True `
        -Condition ($timeoutError -match "did not finish within 5 seconds") `
        -Message "a stuck bootstrap must return a bounded, useful timeout error"
    Assert-True `
        -Condition ($timeoutStopwatch.Elapsed.TotalSeconds -lt 10) `
        -Message "a stuck bootstrap must not leave the launcher loading indefinitely"
    Assert-True `
        -Condition (Test-Path -LiteralPath $slowBootstrapPidPath -PathType Leaf) `
        -Message "the slow bootstrap fixture must publish its process ID"
    $slowBootstrapProcessId = [int](Get-Content -LiteralPath $slowBootstrapPidPath -Raw)
    $processExitDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $processExitDeadline -and
        $null -ne (Get-Process -Id $slowBootstrapProcessId -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True `
        -Condition ($null -eq (Get-Process -Id $slowBootstrapProcessId -ErrorAction SilentlyContinue)) `
        -Message "the timed-out bootstrap process must be terminated without touching its backend descendants"
}
finally {
    $env:SAPHIR_LAUNCHER_CHILD_PID = $previousPidPath
    $env:SAPHIR_LAUNCHER_SLOW_PID = $previousSlowPidPath
    if ($childProcessId -gt 0) {
        Stop-Process -Id $childProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($slowBootstrapProcessId -gt 0) {
        Stop-Process -Id $slowBootstrapProcessId -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Windows launcher waits for the bootstrap process only."
