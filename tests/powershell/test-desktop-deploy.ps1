param([switch]$Isolated)
$ErrorActionPreference = 'Stop'
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw 'Desktop deployment subprocess failed.' }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$owned = Join-Path ([IO.Path]::GetTempPath()) ('desktop-deploy-test-' + [Guid]::NewGuid().ToString('N'))
$downloads = Join-Path $owned 'Downloads with spaces'
$desktop = Join-Path $owned 'Desktop with spaces'
$dataRoot = Join-Path $owned 'shared DATA'
$outputRoot = Join-Path $owned 'shared deployment'
$stageRoot = Join-Path $owned 'staging'
function Assert-Deploy($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-DeployFailure([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Deploy ($message -match $Pattern) "Expected '$Pattern', got '$message'."
}
function Write-DeployTestZip([string]$Path, $Entries) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($pair in $Entries.GetEnumerator()) {
            $writer = [IO.StreamWriter]::new($zip.CreateEntry($pair.Key).Open())
            try { $writer.Write([string]$pair.Value) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}
try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($directory in @($downloads, $desktop, $dataRoot, $stageRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $dataRoot 'users.json'), '[{"employeeCode":"000000001","gc179Profile":{"level":""}}]')
    [IO.File]::WriteAllText((Join-Path $dataRoot '000000001_data.json'), '[{"entryId":"keep-me","comment":"never migrate during deployment"}]')
    $dataBefore = @(Get-ChildItem $dataRoot -File | ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|'
    $source = [IO.File]::ReadAllText((Join-Path $repo 'scripts/deploy-downloaded-zip.ps1'))
    Assert-Deploy ($source -notmatch 'Unblock-File|ExecutionPolicy\s+Bypass|EncodedCommand') 'Deployer must not bypass security policy.'
    $configured = $source.Replace("OutputRoot = ''       #", "OutputRoot = '$($outputRoot.Replace("'", "''"))'       #")
    $configured = $configured.Replace("DataFolderPath = ''   #", "DataFolderPath = '$($dataRoot.Replace("'", "''"))'   #")
    $configured = $configured.Replace("(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')", "'$($downloads.Replace("'", "''"))'")
    # Keep retained failure staging inside this test's exact owned directory.
    $configured = $configured.Replace('[IO.Path]::GetTempPath()', "'$($stageRoot.Replace("'", "''"))'")
    $deployer = Join-Path $desktop 'deploy-downloaded-zip.ps1'
    [IO.File]::WriteAllText($deployer, $configured, [Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath (Join-Path $repo 'scripts/Deploy SAPHIR.bat') -Destination $desktop
    $unconfigured = Join-Path $desktop 'unconfigured.ps1'
    [IO.File]::WriteAllText($unconfigured, $source, [Text.UTF8Encoding]::new($true))
    Assert-DeployFailure { & $unconfigured } 'First edit'
    Assert-DeployFailure { & $deployer -AllowLocalDataPath } 'No completed ZIP'

    # Real GitHub-shaped archive; only build inputs, never working DATA.
    $zipPath = Join-Path $downloads 'mindblowing-spaghettiyo-codex-windows-launcher (1).zip'
    $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($root in @('app', 'scripts', 'docs', 'deploy')) {
            foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo $root) -Recurse -File -Force) {
                $relative = $file.FullName.Substring($repo.Length + 1).Replace('\', '/')
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, ('github-repository/' + $relative), [IO.Compression.CompressionLevel]::Fastest) | Out-Null
            }
        }
        foreach ($junk in @('.github/workflows/ignored.yml', '.gitignore', '.gitattributes', 'data/must-not-publish.json')) {
            $writer = [IO.StreamWriter]::new($archive.CreateEntry('github-repository/' + $junk).Open())
            try { $writer.Write('do not publish') } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
    $downloadHash = (Get-FileHash -LiteralPath $zipPath).Hash
    $olderZip = Join-Path $downloads 'mindblowing-spaghettiyo-codex-windows-launcher.zip'
    [IO.File]::WriteAllText($olderZip, 'old invalid download must not be selected')
    [IO.File]::SetLastWriteTimeUtc($olderZip, [DateTime]::UtcNow.AddDays(-1))
    $preview = & $deployer -WhatIf -AllowLocalDataPath
    Assert-Deploy (-not $preview.Published -and $preview.SourceZip -eq $zipPath -and -not [IO.Directory]::Exists($outputRoot)) 'Preview published or chose the older ZIP.'
    $result = & $deployer -AllowLocalDataPath -ReleaseId 'desktop-test-a'
    Assert-Deploy ($result.Published -and $result.ReleaseId -eq 'desktop-test-a') 'Standalone deploy failed.'
    $distribution = Join-Path $outputRoot 'SAPHIR-Distribution'
    Assert-Deploy ($result.DistributionFolder -eq $distribution) 'Distribution path changed.'
    $manifestPath = Join-Path $distribution 'deployment/current.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    Assert-Deploy ($manifest.releaseId -eq 'desktop-test-a' -and $manifest.sha256 -eq (Get-FileHash -LiteralPath $result.ReleasePackage).Hash.ToLowerInvariant()) 'Manifest/package mismatch.'
    Assert-Deploy ([IO.File]::Exists((Join-Path $distribution 'Launch SAPHIR.vbs'))) 'Launchers were not published.'
    Assert-Deploy (@(Get-ChildItem -LiteralPath $outputRoot -Directory).Count -eq 1) 'Source folders were copied onto the share.'
    Assert-Deploy (@(Get-ChildItem -LiteralPath $stageRoot -Directory).Count -eq 0) 'Successful staging was not cleaned.'
    Assert-Deploy ((Get-FileHash -LiteralPath $zipPath).Hash -ceq $downloadHash) 'Downloaded ZIP changed.'
    $runtime = [IO.Compression.ZipFile]::OpenRead($result.ReleasePackage)
    try {
        Assert-Deploy ($null -ne $runtime.GetEntry('app/backend/saphir-server.ps1')) 'Canonical app layout missing.'
        Assert-Deploy ($null -ne $runtime.GetEntry('scripts/backfill-compensation.ps1')) 'Downloaded packager was not used.'
        Assert-Deploy (@($runtime.Entries | Where-Object { $_.FullName -match '^([.]git|[.]github|data/)' }).Count -eq 0) 'GitHub metadata/DATA reached the release.'
    } finally { $runtime.Dispose() }

    $manifestBefore = [IO.File]::ReadAllText($manifestPath)
    $baseEntries = [ordered]@{
        'repo/scripts/package-app.ps1' = "throw 'injected build failure'"
        'repo/app/backend/saphir-server.ps1' = '# fixture'
        'repo/app/frontend/index.html' = '<html></html>'
        'repo/deploy/bootstrap/Launch SAPHIR.vbs' = "' fixture"
    }
    $failedZip = Join-Path $downloads 'build-failure.zip'; Write-DeployTestZip $failedZip $baseEntries
    Assert-DeployFailure { & $deployer -ZipPath $failedZip -AllowLocalDataPath } 'injected build failure'
    Assert-Deploy ([IO.File]::ReadAllText($manifestPath) -ceq $manifestBefore -and [IO.File]::Exists($result.ReleasePackage)) 'Failed build replaced a working release.'
    Assert-Deploy (@(Get-ChildItem -LiteralPath $stageRoot -Directory).Count -eq 1) 'Failed staging was not retained.'
    $caseIndex = 0
    foreach ($badName in @('repo/../escape.ps1', '/absolute.ps1', 'repo/C:/evil.ps1', 'repo/unsafe.ps1:stream', 'repo/NUL.txt', 'repo/bad. /evil.ps1', 'repo/..\escape.ps1')) {
        $caseIndex++; $badZip = Join-Path $downloads ("bad-$caseIndex.zip")
        $entries = [ordered]@{}; foreach ($key in $baseEntries.Keys) { $entries[$key] = $baseEntries[$key] }; $entries[$badName] = 'unsafe'
        Write-DeployTestZip $badZip $entries
        Assert-DeployFailure { & $deployer -ZipPath $badZip -AllowLocalDataPath } 'Unsafe ZIP path'
    }
    $ambiguous = [ordered]@{}; foreach ($key in $baseEntries.Keys) { $ambiguous[$key] = $baseEntries[$key] }; $ambiguous['other/scripts/package-app.ps1'] = '# not SAPHIR'
    $ambiguousZip = Join-Path $downloads 'ambiguous.zip'; Write-DeployTestZip $ambiguousZip $ambiguous
    Assert-DeployFailure { & $deployer -ZipPath $ambiguousZip -AllowLocalDataPath } 'exactly one SAPHIR'
    foreach ($extra in @('duplicate', 'link')) {
        $extraZip = Join-Path $downloads ($extra + '.zip'); Write-DeployTestZip $extraZip $baseEntries
        $zip = [IO.Compression.ZipFile]::Open($extraZip, [IO.Compression.ZipArchiveMode]::Update)
        try {
            if ($extra -eq 'duplicate') { $entry = $zip.CreateEntry('repo/APP/frontend/index.html') }
            else { $entry = $zip.CreateEntry('repo/link'); $entry.ExternalAttributes = -1610612736 }
        } finally { $zip.Dispose() }
        Assert-DeployFailure { & $deployer -ZipPath $extraZip -AllowLocalDataPath } 'Duplicate/case-ambiguous|links are not allowed'
    }
    # Native bad-ZIP exception wording varies with the workstation language.
    Assert-DeployFailure { & $deployer -ZipPath $olderZip -AllowLocalDataPath } '.+'
    Assert-DeployFailure { & $deployer -ZipPath $zipPath -OutputRoot $dataRoot -DataFolderPath $dataRoot -AllowLocalDataPath } 'must be separate'
    Assert-DeployFailure { & $deployer -ZipPath $zipPath -OutputRoot $distribution -AllowLocalDataPath } 'parent folder'
    Assert-Deploy ([IO.File]::ReadAllText($manifestPath) -ceq $manifestBefore) 'Rejected ZIPs changed current.json.'
    $dataAfter = @(Get-ChildItem $dataRoot -File | ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|'
    Assert-Deploy ($dataAfter -ceq $dataBefore) 'Deployment touched DATA or ran a migration.'
    Write-Host 'Desktop deployment passed: standalone settings, newest ZIP, WhatIf, full release, untouched DATA/download, failure safety, safe paths and stable destination.'
} finally { if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force } }
