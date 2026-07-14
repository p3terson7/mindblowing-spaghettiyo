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

Assert-LauncherContains -RelativePath "Launch GEEM.bat" -ExpectedText 'launch-cached-app.ps1" -Force'
Assert-LauncherContains -RelativePath "Launch GEEM.vbs" -ExpectedText 'scriptPath & " -Force"'
Assert-LauncherContains -RelativePath "Launch GEEM.command" -ExpectedText 'launch-cached-app.ps1" -Force'

Write-Host "Force-restart launcher test passed."
