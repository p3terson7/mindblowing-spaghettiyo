$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
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

$canonicalAppRoot = Join-Path -Path $repoRoot -ChildPath "app"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $canonicalAppRoot -ChildPath "backend/saphir-server.ps1") -PathType Leaf) -Message "the unified backend must use the canonical app tree"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $canonicalAppRoot -ChildPath "frontend/index.html") -PathType Leaf) -Message "the unified frontend must use the canonical app tree"
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath "apps"))) -Message "the historical apps tree must not return to active source"

foreach ($legacyWrapper in @("start-admin.ps1", "start-employee.ps1", "stop-admin.ps1", "stop-employee.ps1")) {
    $legacyWrapperPath = Join-Path -Path $repoRoot -ChildPath ("scripts/{0}" -f $legacyWrapper)
    Assert-True -Condition (-not (Test-Path -LiteralPath $legacyWrapperPath)) -Message ("the role-specific wrapper must stay removed: {0}" -f $legacyWrapper)
}

$runtimeLayoutPath = Join-Path -Path $repoRoot -ChildPath "scripts/lib/RuntimeLayout.ps1"
$runtimeLayoutSource = Get-Content -LiteralPath $runtimeLayoutPath -Raw
Assert-True -Condition ($runtimeLayoutSource -match 'function\s+Get-LegacyServiceConfigs') -Message "the transition cleanup for legacy services must remain available"
Assert-True -Condition ($runtimeLayoutSource -match 'Name\s*=\s*"employee-legacy"') -Message "the legacy employee listener must remain identifiable during cleanup"
Assert-True -Condition ($runtimeLayoutSource -match 'Port\s*=\s*8080') -Message "the transition cleanup must continue to target the old employee port"
Assert-True -Condition ($runtimeLayoutSource -match 'employee\.pid\.json') -Message "the transition cleanup must continue to remove old employee PID metadata"

$releaseTestPath = Join-Path -Path $PSScriptRoot -ChildPath "test-release-package.ps1"
$releaseTestSource = Get-Content -LiteralPath $releaseTestPath -Raw
Assert-True -Condition ($releaseTestSource -match 'apps/employee') -Message "the release contract must continue to reject a packaged legacy employee application"

$layoutResolverSource = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/lib/ApplicationLayout.ps1") -Raw
Assert-True -Condition ($layoutResolverSource -match 'apps/admin/backend/admin-server\.ps1') -Message "the isolated rollback resolver must retain the legacy cached-server path"

Write-Host "Unified application source contract passed."
