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

Assert-LauncherContains -RelativePath "Launch SAPHIR.bat" -ExpectedText 'launch-cached-app.ps1"'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText '& scriptPath, 0, True'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'WinHttp.WinHttpRequest.5.1'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'GetResponseHeader("X-SAPHIR-App")'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'GetResponseHeader("X-SAPHIR-Instance")'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'responseInstanceToken = warmInstanceToken'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'activeFilePath = fso.BuildPath(localRoot, "active.json")'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'serverPathPattern.Pattern = """scriptPath""'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'fso.BuildPath(localRoot, "versions")'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'StrComp(expectedServerPath, metadataServerPath, vbTextCompare) = 0'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'Len(warmInstanceToken) = 32 And warmReleaseMatches'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText 'shell.Run "http://localhost:8081/", 1, False'
Assert-LauncherContains -RelativePath "Launch SAPHIR.command" -ExpectedText 'launch-cached-app.ps1"'
Assert-LauncherOmits -RelativePath "Launch SAPHIR.bat" -UnexpectedText 'launch-cached-app.ps1" -Force'
Assert-LauncherOmits -RelativePath "Launch SAPHIR.vbs" -UnexpectedText 'scriptPath & " -Force"'
Assert-LauncherOmits -RelativePath "Launch SAPHIR.command" -UnexpectedText 'launch-cached-app.ps1" -Force'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '& $developmentLaunchScript -Force:$Force'
Assert-LauncherContains -RelativePath "apps/admin/backend/admin-server.ps1" -ExpectedText '$response.Headers.Add("X-SAPHIR-App", "SAPHIR")'
Assert-LauncherContains -RelativePath "apps/admin/backend/admin-server.ps1" -ExpectedText '$response.Headers.Add("X-SAPHIR-Instance", $script:saphirInstanceToken)'
Assert-LauncherContains -RelativePath "scripts/lib/ServerControl.ps1" -ExpectedText '$response.Headers["X-SAPHIR-App"]'
Assert-LauncherContains -RelativePath "scripts/lib/ServerControl.ps1" -ExpectedText '$response.Headers["X-SAPHIR-Instance"]'
Assert-LauncherContains -RelativePath "scripts/lib/ServerControl.ps1" -ExpectedText 'instanceToken     = $instanceToken'
Assert-LauncherContains -RelativePath "Launch SAPHIR.bat" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "Launch SAPHIR.vbs" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "SAPHIR Launcher.vbs" -ExpectedText '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-LauncherContains -RelativePath "SAPHIR Launcher.vbs" -ExpectedText '-STA'
Assert-LauncherContains -RelativePath "SAPHIR Launcher.vbs" -ExpectedText 'distribution-root.txt'
Assert-LauncherContains -RelativePath "Install SAPHIR Shortcut.vbs" -ExpectedText 'shortcut.IconLocation = localIconPath & ",0"'
Assert-LauncherContains -RelativePath "Install SAPHIR Shortcut.vbs" -ExpectedText 'shortcut.Arguments = Chr(34) & localLauncherEntryPath & Chr(34)'
Assert-LauncherContains -RelativePath "Install SAPHIR Shortcut.vbs" -ExpectedText 'localLauncherRoot = fso.BuildPath(localRoot, "launcher")'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '[switch]$NoBrowser'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '[switch]$NonInteractive'
Assert-LauncherContains -RelativePath "scripts/launch-cached-app.ps1" -ExpectedText '[string]$DistributionRoot'
Assert-LauncherContains -RelativePath "scripts/launch-app.ps1" -ExpectedText '[switch]$NoBrowser'

Write-Host "Smart launcher reuse test passed."
