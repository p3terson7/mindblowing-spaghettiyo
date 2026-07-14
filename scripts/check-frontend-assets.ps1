[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$frontendRoot = Join-Path -Path $repoRoot -ChildPath "apps/admin/frontend"
$indexPath = Join-Path -Path $frontendRoot -ChildPath "index.html"

if (-not (Test-Path -Path $indexPath -PathType Leaf)) {
    throw "Frontend index.html was not found: $indexPath"
}

$indexContent = Get-Content -Path $indexPath -Raw
$matches = [regex]::Matches($indexContent, '(href|src)="([^"]+)"')
$assetPaths = New-Object System.Collections.ArrayList

foreach ($match in $matches) {
    $rawPath = [string]$match.Groups[2].Value
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        continue
    }

    if ($rawPath -match "^http[:]" -or $rawPath -match "^https[:]" -or $rawPath -match "^mailto:" -or $rawPath -match "^tel:" -or $rawPath -match "^#") {
        continue
    }

    $pathWithoutQuery = ($rawPath -split "\?")[0]
    if ([string]::IsNullOrWhiteSpace($pathWithoutQuery)) {
        continue
    }

    [void]$assetPaths.Add($pathWithoutQuery)
}

$missing = New-Object System.Collections.ArrayList
$present = 0

foreach ($assetPath in ($assetPaths | Sort-Object -Unique)) {
    $candidate = Join-Path -Path $frontendRoot -ChildPath ($assetPath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path -Path $candidate -PathType Leaf) {
        $present++
        continue
    }

    [void]$missing.Add([PSCustomObject]@{
        Asset = $assetPath
        ExpectedPath = $candidate
    })
}

Write-Host "Frontend root: $frontendRoot"
Write-Host "Referenced assets found: $present"

if ($missing.Count -eq 0) {
    Write-Host "All referenced frontend assets are present."
    exit 0
}

Write-Host ""
Write-Host "Missing referenced frontend assets:"
foreach ($item in $missing) {
    Write-Host ("- {0}" -f $item.Asset)
    Write-Host ("  Expected: {0}" -f $item.ExpectedPath)
}

exit 1
