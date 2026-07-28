$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path
$launcherEntryPath = Join-Path -Path $repoRoot -ChildPath "SAPHIR Launcher.vbs"
$launcherInterfacePath = Join-Path -Path $repoRoot -ChildPath "scripts/saphir-launcher.ps1"
$launcherControlPath = Join-Path -Path $repoRoot -ChildPath "scripts/lib/LauncherControl.ps1"
$cachedLaunchPath = Join-Path -Path $repoRoot -ChildPath "scripts/launch-cached-app.ps1"
$localCachePath = Join-Path -Path $repoRoot -ChildPath "scripts/lib/LocalAppCache.ps1"
$serverControlPath = Join-Path -Path $repoRoot -ChildPath "scripts/lib/ServerControl.ps1"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

foreach ($requiredPath in @($launcherEntryPath, $launcherInterfacePath, $launcherControlPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message ("launcher file is missing: {0}" -f $requiredPath)
}

function Get-WindowsPowerShell51FileText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasUtf8Bom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    if ($hasUtf8Bom) {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($bytes, 3, $bytes.Length - 3)
    }

    # Windows PowerShell 5.1 treats a BOM-less script as the workstation's
    # legacy ANSI code page. Western Windows uses code page 1252.
    return [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
}

# Any non-ASCII PowerShell source may contain user-facing text or matching
# values whose silent ANSI corruption is just as damaging as a parser error.
# Requiring a BOM makes direct source checkouts deterministic on WinPS 5.1;
# packaged scripts are checked independently by test-release-package.ps1.
$allPowerShellSourceFiles = @(
    Get-ChildItem `
        -LiteralPath (Join-Path -Path $repoRoot -ChildPath "apps"), (Join-Path -Path $repoRoot -ChildPath "scripts") `
        -Recurse `
        -File |
        Where-Object { $_.Extension -in @(".ps1", ".psd1", ".psm1") }
)
foreach ($sourceFile in $allPowerShellSourceFiles) {
    $sourceBytes = [System.IO.File]::ReadAllBytes($sourceFile.FullName)
    $containsNonAscii = @($sourceBytes | Where-Object { $_ -ge 0x80 }).Count -gt 0
    if (-not $containsNonAscii) {
        continue
    }

    $hasUtf8Bom = $sourceBytes.Length -ge 3 -and
        $sourceBytes[0] -eq 0xEF -and
        $sourceBytes[1] -eq 0xBB -and
        $sourceBytes[2] -eq 0xBF
    Assert-True `
        -Condition $hasUtf8Bom `
        -Message ("non-ASCII PowerShell source must include a UTF-8 BOM for direct Windows PowerShell 5.1 execution: {0}" -f $sourceFile.FullName)
}

$localLauncherPowerShellPaths = @(
    $launcherInterfacePath,
    $launcherControlPath,
    $cachedLaunchPath,
    $localCachePath,
    $serverControlPath
)
foreach ($powerShellPath in $localLauncherPowerShellPaths) {
    $tokens = $null
    $parseErrors = $null
    $windowsPowerShellText = Get-WindowsPowerShell51FileText -Path $powerShellPath
    [void][System.Management.Automation.Language.Parser]::ParseInput(
        $windowsPowerShellText,
        [ref]$tokens,
        [ref]$parseErrors
    )
    Assert-True -Condition (@($parseErrors).Count -eq 0) -Message ("Windows PowerShell 5.1 decoding produced parser errors in {0}: {1}" -f $powerShellPath, (@($parseErrors | ForEach-Object { $_.Message }) -join " | "))
}

$entrySource = [System.IO.File]::ReadAllText($launcherEntryPath)
$interfaceSource = [System.IO.File]::ReadAllText($launcherInterfacePath)
$controlSource = [System.IO.File]::ReadAllText($launcherControlPath)
$combinedPowerShellSource = $interfaceSource + [Environment]::NewLine + $controlSource
$interfaceBytes = [System.IO.File]::ReadAllBytes($launcherInterfacePath)
Assert-True `
    -Condition ($interfaceBytes.Length -ge 3 -and $interfaceBytes[0] -eq 0xEF -and $interfaceBytes[1] -eq 0xBB -and $interfaceBytes[2] -eq 0xBF) `
    -Message "the direct-checkout launcher interface must include a UTF-8 BOM for Windows PowerShell 5.1"
$xamlMatch = [regex]::Match(
    $interfaceSource,
    "(?s)\[xml\]\`$xaml\s*=\s*@'\r?\n(?<xaml>.*?)\r?\n'@"
)
Assert-True -Condition $xamlMatch.Success -Message "launcher interface must contain an extractable XAML document"
[xml]$parsedXaml = $xamlMatch.Groups["xaml"].Value
Assert-True -Condition ($null -ne $parsedXaml.DocumentElement) -Message "launcher XAML must be well-formed XML"

Assert-True -Condition ($entrySource.IndexOf('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher entry point must use built-in Windows PowerShell rather than require PowerShell 7"
Assert-True -Condition ($entrySource.IndexOf('-NoProfile', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher entry point must isolate itself from employee PowerShell profiles"
Assert-True -Condition ($entrySource.IndexOf('-ExecutionPolicy Bypass', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher entry point must work with the same policy-safe invocation as the existing SAPHIR launchers"
Assert-True -Condition ($entrySource.IndexOf('-STA', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher entry point must use an STA thread for WPF"
Assert-True -Condition ($entrySource.IndexOf('distribution-root.txt', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "local launcher must read its persisted shared-distribution location"
Assert-True -Condition ($entrySource.IndexOf('fso.FileExists(sharedLauncherPath)', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -Message "local launcher entry must not synchronously probe an unavailable network share before opening WPF"
Assert-True -Condition ($entrySource.IndexOf('launcher-startup.log', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "hidden launcher failures must be persisted to a diagnostic log"
Assert-True -Condition ($entrySource.IndexOf(' 2>&1', [System.StringComparison]::Ordinal) -ge 0) -Message "launcher entry point must capture the hidden PowerShell error stream"
Assert-True -Condition ($entrySource.IndexOf('errorDetails', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher entry point must show useful startup failure details"
Assert-True -Condition ($entrySource.IndexOf('SAPHIR_LAUNCHER_VALIDATE_ONLY', [System.StringComparison]::Ordinal) -ge 0) -Message "the VBS entry point must expose the noninteractive Windows runtime smoke hook"
Assert-True -Condition ($entrySource.IndexOf('pwsh', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -Message "launcher entry point must not require the separately installed PowerShell 7 executable"
Assert-True -Condition ($interfaceSource.IndexOf('PresentationFramework', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher interface must use the WPF framework included with Windows"
Assert-True -Condition ($interfaceSource.IndexOf('LauncherControl.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher interface must keep status and action logic in its testable controller"
Assert-True -Condition ($interfaceSource.IndexOf('[switch]$ValidateOnly', [System.StringComparison]::Ordinal) -ge 0) -Message "the WPF interface must support noninteractive runtime validation"
Assert-True -Condition ($interfaceSource.IndexOf('Start-StatusRefresh -ShowProgress', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "manual status checks must show nonblocking progress"
Assert-True -Condition ($controlSource.IndexOf('PresentationFramework', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -Message "launcher controller must remain independent of WPF so its logic can be regression-tested without opening a window"
Assert-True -Condition ($controlSource.IndexOf('Get-SaphirLauncherAdjacentBootstrapPath', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "launcher controller must be able to start from the locally installed cached bootstrap"
Assert-True -Condition ($controlSource.IndexOf('-DistributionRoot $DistributionRoot', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "local cached bootstrap must retain the shared distribution location for update checks"

$forbiddenCommands = @(
    "Install-Module",
    "Install-Package",
    "Save-Module",
    "Start-ThreadJob",
    "winget",
    "choco",
    "nuget",
    "dotnet"
)
foreach ($commandName in $forbiddenCommands) {
    $commandPattern = "^[ \t]*(&[ \t]*){0,1}" + [regex]::Escape($commandName) + "(\.exe){0,1}\b"
    $commandOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    Assert-True -Condition (-not [regex]::IsMatch($combinedPowerShellSource, $commandPattern, $commandOptions)) -Message ("launcher must not require or download external tooling through {0}" -f $commandName)
}

Assert-True -Condition (-not [regex]::IsMatch($combinedPowerShellSource, "(?im)Add-Type[^\r\n]*-Path\b")) -Message "launcher must load built-in framework assemblies by name rather than require bundled DLLs"
Assert-True -Condition (-not [regex]::IsMatch($combinedPowerShellSource, "(?im)(DownloadFile|DownloadString|Invoke-RestMethod)[ \t]")) -Message "launcher must not download runtime components"

Write-Host "Windows launcher static checks passed."
