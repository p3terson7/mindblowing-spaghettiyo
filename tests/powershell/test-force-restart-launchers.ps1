$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path

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

function Assert-LauncherOmits {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$UnexpectedText
    )

    $path = Join-Path -Path $repoRoot -ChildPath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Assertion failed: launcher is missing: $RelativePath"
    }

    $contents = [System.IO.File]::ReadAllText($path)
    if ($contents.IndexOf($UnexpectedText, [System.StringComparison]::Ordinal) -ge 0) {
        throw "Assertion failed: $RelativePath must not include '$UnexpectedText'."
    }
}

Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.bat" -ExpectedText 'launch-cached-app.ps1"'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText '& scriptPath, 0, True'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'WinHttp.WinHttpRequest.5.1'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'GetResponseHeader("X-SAPHIR-App")'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'GetResponseHeader("X-SAPHIR-Instance")'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'responseInstanceToken = warmInstanceToken'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'activeFilePath = fso.BuildPath(localRoot, "active.json")'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'serverPathPattern.Pattern = """scriptPath""'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'fso.BuildPath(localRoot, "versions")'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'expectedCanonicalServerPath'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'app\backend\saphir-server.ps1'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'expectedLegacyServerPath'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'apps\admin\backend\admin-server.ps1'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'StrComp(expectedCanonicalServerPath, metadataServerPath, vbTextCompare) = 0 Or StrComp(expectedLegacyServerPath, metadataServerPath, vbTextCompare) = 0'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'Len(warmInstanceToken) = 32 And warmReleaseMatches'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText 'shell.Run "http://localhost:8081/", 1, False'
Assert-LauncherContains -RelativePath "scripts/dev/Launch SAPHIR.command" -ExpectedText 'launch-cached-app.ps1"'
Assert-LauncherOmits -RelativePath "deploy/bootstrap/Launch SAPHIR.bat" -UnexpectedText 'launch-cached-app.ps1" -Force'
Assert-LauncherOmits -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -UnexpectedText 'scriptPath & " -Force"'
Assert-LauncherOmits -RelativePath "scripts/dev/Launch SAPHIR.command" -UnexpectedText 'launch-cached-app.ps1" -Force'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '& $developmentLaunchScript -Force:$Force'
Assert-LauncherContains -RelativePath "app/backend/saphir-server.ps1" -ExpectedText '$response.Headers.Add("X-SAPHIR-App", "SAPHIR")'
Assert-LauncherContains -RelativePath "app/backend/saphir-server.ps1" -ExpectedText '$response.Headers.Add("X-SAPHIR-Instance", $script:saphirInstanceToken)'
Assert-LauncherContains -RelativePath "scripts/lib/ServerControl.ps1" -ExpectedText '$response.Headers["X-SAPHIR-App"]'
Assert-LauncherContains -RelativePath "scripts/lib/ServerControl.ps1" -ExpectedText '$response.Headers["X-SAPHIR-Instance"]'
Assert-LauncherContains -RelativePath "scripts/lib/ServerControl.ps1" -ExpectedText 'instanceToken     = $instanceToken'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.bat" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Launch SAPHIR.vbs" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "deploy/bootstrap/SAPHIR Launcher.vbs" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "deploy/bootstrap/SAPHIR Launcher.vbs" -ExpectedText '-STA'
Assert-LauncherContains -RelativePath "deploy/bootstrap/SAPHIR Launcher.vbs" -ExpectedText 'distribution-root.txt'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Install SAPHIR Shortcut.vbs" -ExpectedText 'shortcut.IconLocation = localIconPath & ",0"'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Install SAPHIR Shortcut.vbs" -ExpectedText 'shortcut.Arguments = Chr(34) & localLauncherEntryPath & Chr(34)'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Install SAPHIR Shortcut.vbs" -ExpectedText 'localLauncherRoot = fso.BuildPath(localRoot, "launcher")'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Install SAPHIR Shortcut.vbs" -ExpectedText 'failedReleasePath = fso.BuildPath(localRoot, "failed.json")'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Install SAPHIR Shortcut.vbs" -ExpectedText 'If fso.FileExists(localApplicationLayoutPath) And fso.FileExists(failedReleasePath) Then'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Install SAPHIR Shortcut.vbs" -ExpectedText 'fso.DeleteFile markerPath, True'
Assert-LauncherContains -RelativePath "deploy/bootstrap/Install SAPHIR Shortcut.vbs" -ExpectedText '"Version du lanceur : " & bundleId'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '[switch]$NoBrowser'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '[switch]$NonInteractive'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '[string]$DistributionRoot'
Assert-LauncherContains -RelativePath "scripts/launch-app.ps1" -ExpectedText '[switch]$NoBrowser'

Write-Host "Smart launcher reuse test passed."
