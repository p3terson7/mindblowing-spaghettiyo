$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path

function Assert-LauncherContains {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )

    $path = Join-Path -Path $repoRoot -ChildPath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Assertion failed: launcher is missing: $RelativePath"
    }

    $contents = [System.IO.File]::ReadAllText($path)
    if ($contents.IndexOf($ExpectedText, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Assertion failed: $RelativePath must include '$ExpectedText'."
    }
}

Assert-LauncherContains -RelativePath "Launch SAPHIR.bat" -ExpectedText 'launch-cached-app.ps1" -Force'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'scriptPath & " -Force"'
Assert-LauncherContains -RelativePath "Launch SAPHIR.command" -ExpectedText 'launch-cached-app.ps1" -Force'
Assert-LauncherContains -RelativePath "Launch SAPHIR.bat" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "Install SAPHIR Shortcut.vbs" -ExpectedText 'shortcut.IconLocation = localIconPath & ",0"'
Assert-LauncherContains -RelativePath "Install SAPHIR Shortcut.vbs" -ExpectedText 'shortcut.Arguments = Chr(34) & launchScriptPath & Chr(34)'

Write-Host "Force-restart launcher test passed."
