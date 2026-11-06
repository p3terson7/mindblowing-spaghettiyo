$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "scripts/lib/ApplicationLayout.ps1")
. (Join-Path -Path $repoRoot -ChildPath "scripts/lib/LocalAppCache.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $caughtMessage = ""
    try {
        & $Action
    }
    catch {
        $caughtMessage = [string]$_.Exception.Message
    }

    if ([string]::IsNullOrWhiteSpace($caughtMessage) -or $caughtMessage -notmatch $MessagePattern) {
        throw "Assertion failed: $Message. Actual error: '$caughtMessage'."
    }
}

function New-LayoutFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet("Canonical", "Legacy")][string]$Kind,
        [switch]$Incomplete
    )

    if ($Kind -eq "Canonical") {
        $files = @(
            "app/backend/saphir-server.ps1",
            "app/backend/saphir-config.psd1",
            "app/frontend/index.html",
            "app/backend/services/RouteDispatchService.ps1"
        )
    }
    else {
        $files = @(
            "apps/admin/backend/admin-server.ps1",
            "apps/admin/backend/admin-config.psd1",
            "apps/admin/frontend/index.html",
            "apps/admin/backend/services/RouteDispatchService.ps1"
        )
    }

    if ($Incomplete) {
        $files = @($files | Where-Object { $_ -notmatch "RouteDispatchService" })
    }

    foreach ($relativePath in $files) {
        $path = Join-Path -Path $Root -ChildPath $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value "# fixture" -Encoding ASCII
    }
}

function Add-ReleaseFixtureFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet("Canonical", "Legacy")][string]$Kind
    )

    New-LayoutFixture -Root $Root -Kind $Kind
    foreach ($relativePath in @(
        "docs/GC179.pdf",
        "scripts/launch-app.ps1",
        "scripts/lib/RuntimeLayout.ps1",
        "scripts/lib/ServerControl.ps1"
    )) {
        $path = Join-Path -Path $Root -ChildPath $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value "fixture" -Encoding ASCII
    }

    if ($Kind -eq "Canonical") {
        Set-Content -LiteralPath (Join-Path -Path $Root -ChildPath "scripts/lib/ApplicationLayout.ps1") -Value "# fixture" -Encoding ASCII
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-layout-{0}" -f [Guid]::NewGuid().ToString("N"))

try {
    $canonicalRoot = Join-Path -Path $testRoot -ChildPath "canonical"
    New-LayoutFixture -Root $canonicalRoot -Kind Canonical
    $canonical = Resolve-SaphirApplicationLayout -ApplicationRoot $canonicalRoot -Required
    Assert-Equal -Expected "Canonical" -Actual $canonical.Kind -Message "the canonical application tree must resolve"
    Assert-Equal -Expected (Join-Path -Path $canonicalRoot -ChildPath "app/backend/saphir-server.ps1") -Actual $canonical.ServerScript -Message "canonical server path must be exact"
    Assert-Equal -Expected (Join-Path -Path $canonicalRoot -ChildPath "app/backend/saphir-config.psd1") -Actual $canonical.ConfigPath -Message "canonical config path must be exact"

    $legacyRoot = Join-Path -Path $testRoot -ChildPath "legacy"
    New-LayoutFixture -Root $legacyRoot -Kind Legacy
    $legacy = Resolve-SaphirApplicationLayout -ApplicationRoot $legacyRoot -Required
    Assert-Equal -Expected "Legacy" -Actual $legacy.Kind -Message "an existing legacy release must continue to resolve"
    Assert-Equal -Expected (Join-Path -Path $legacyRoot -ChildPath "apps/admin/backend/admin-server.ps1") -Actual $legacy.ServerScript -Message "legacy server path must remain exact"

    $transitionRoot = Join-Path -Path $testRoot -ChildPath "transition"
    New-LayoutFixture -Root $transitionRoot -Kind Legacy
    New-LayoutFixture -Root $transitionRoot -Kind Canonical
    $transition = Resolve-SaphirApplicationLayout -ApplicationRoot $transitionRoot -Required
    Assert-Equal -Expected "Canonical" -Actual $transition.Kind -Message "canonical layout must win when both trees are present"

    $fallbackRoot = Join-Path -Path $testRoot -ChildPath "fallback"
    New-LayoutFixture -Root $fallbackRoot -Kind Canonical -Incomplete
    New-LayoutFixture -Root $fallbackRoot -Kind Legacy
    $fallback = Resolve-SaphirApplicationLayout -ApplicationRoot $fallbackRoot -Required
    Assert-Equal -Expected "Legacy" -Actual $fallback.Kind -Message "an incomplete canonical tree must not mask a complete legacy release"

    $incompleteRoot = Join-Path -Path $testRoot -ChildPath "incomplete"
    New-LayoutFixture -Root $incompleteRoot -Kind Canonical -Incomplete
    Assert-True -Condition ($null -eq (Resolve-SaphirApplicationLayout -ApplicationRoot $incompleteRoot)) -Message "an incomplete layout must not resolve"
    Assert-Throws -Action {
        Resolve-SaphirApplicationLayout -ApplicationRoot $incompleteRoot -Required | Out-Null
    } -MessagePattern "No complete SAPHIR application layout" -Message "required resolution must explain an incomplete package"

    $legacyReleaseRoot = Join-Path -Path $testRoot -ChildPath "legacy-release"
    Add-ReleaseFixtureFiles -Root $legacyReleaseRoot -Kind Legacy
    Assert-True -Condition (Test-SaphirReleaseFiles -ReleasePath $legacyReleaseRoot) -Message "new bootstrap code must accept old cached release topology without changing its files"

    $canonicalReleaseRoot = Join-Path -Path $testRoot -ChildPath "canonical-release"
    Add-ReleaseFixtureFiles -Root $canonicalReleaseRoot -Kind Canonical
    Assert-True -Condition (Test-SaphirReleaseFiles -ReleasePath $canonicalReleaseRoot) -Message "a complete canonical release must validate"
    Remove-Item -LiteralPath (Join-Path -Path $canonicalReleaseRoot -ChildPath "scripts/lib/ApplicationLayout.ps1") -Force
    Assert-True -Condition (-not (Test-SaphirReleaseFiles -ReleasePath $canonicalReleaseRoot)) -Message "a canonical release must include its runtime layout resolver"

    Write-Host "Application layout compatibility tests passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
