$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$bootstrapFileNames = @(
    "Install SAPHIR Shortcut.vbs",
    "Launch SAPHIR.bat",
    "Launch SAPHIR.vbs",
    "SAPHIR Launcher.vbs",
    "SAPHIR.ico",
    "Stop SAPHIR.bat",
    "Stop SAPHIR.vbs"
)
foreach ($fileName in $bootstrapFileNames) {
    $sourcePath = Join-Path -Path $repoRoot -ChildPath ("deploy/bootstrap/{0}" -f $fileName)
    Assert-True -Condition (Test-Path -LiteralPath $sourcePath -PathType Leaf) -Message ("bootstrap source is missing: {0}" -f $fileName)
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $fileName))) -Message ("bootstrap source must not return to the repository root: {0}" -f $fileName)
}

foreach ($developmentLauncher in @("Launch SAPHIR.command", "Stop SAPHIR.command")) {
    $developmentPath = Join-Path -Path $repoRoot -ChildPath ("scripts/dev/{0}" -f $developmentLauncher)
    Assert-True -Condition (Test-Path -LiteralPath $developmentPath -PathType Leaf) -Message ("development launcher is missing: {0}" -f $developmentLauncher)
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $developmentLauncher))) -Message ("development launcher must not return to the repository root: {0}" -f $developmentLauncher)
}

foreach ($organizedPath in @(
    "docs/prototypes/design-tester.html",
    "assets/branding/icon_cropped_final.png",
    "tests/fixtures/gc179/generated-example.ps1"
)) {
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $organizedPath) -PathType Leaf) -Message ("organized source file is missing: {0}" -f $organizedPath)
}

foreach ($obsoleteRootFile in @("design-tester.html", "icon_cropped_final.png", "tmp-gc179-generated.ps1")) {
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $obsoleteRootFile))) -Message ("obsolete root file must stay removed: {0}" -f $obsoleteRootFile)
}

$scriptsRoot = Join-Path -Path $repoRoot -ChildPath "scripts"
$misplacedTests = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File | Where-Object {
    ($_.Name -like "test-*.ps1" -or $_.Name -like "test-*.js") -and
    $_.FullName -ne (Join-Path -Path $scriptsRoot -ChildPath "test-all.ps1")
})
Assert-True -Condition ($misplacedTests.Count -eq 0) -Message (
    "tests must live under tests/powershell or tests/frontend; misplaced file(s): {0}" -f
    (($misplacedTests | ForEach-Object { $_.FullName }) -join ", ")
)

Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath "tests/powershell/test-application-layout.ps1") -PathType Leaf) -Message "the application-layout compatibility contract must remain in the PowerShell suite"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath "tests/frontend") -PathType Container) -Message "frontend tests must remain grouped under tests/frontend"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath "tests/lib/TestPowerShellRuntime.ps1") -PathType Leaf) -Message "test-only helpers must remain under tests/lib"

Write-Host "Root source layout test passed."
