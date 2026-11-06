param([switch]$Isolated)
$ErrorActionPreference = 'Stop'
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw 'Deployed backfill subprocess failed.' }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$owned = Join-Path ([IO.Path]::GetTempPath()) ('deployed-backfill-test-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $owned 'DATA'
$previousCache = $env:SAPHIR_APP_CACHE_ROOT
function Assert-DeployedBackfill($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-DataFingerprint {
    return (@(Get-ChildItem -LiteralPath $fixture -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($fixture.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|')
}
try {
    . (Join-Path $repo 'tests/lib/CacheCoherenceFixture.ps1') -FixtureFolder $fixture -Create -EmployeeCount 1
    $entryPath = Join-Path $fixture '000710001_data.json'
    $entries = @(Read-JsonArrayFile $entryPath); $entries[0].status = 'approved'
    Write-CoherenceFixtureJson $entryPath $entries
    $users = @(Read-JsonArrayFile $usersFile)
    ($users | Where-Object employeeCode -eq '000710001').gc179Profile.level = ''
    Write-CoherenceFixtureJson $usersFile $users
    $result = & (Join-Path $repo 'scripts/package-app.ps1') -OutputRoot (Join-Path $owned 'published') -DataFolderPath $fixture -ReleaseId 'deployed-backfill-a' -NoZip -AllowLocalDataPath
    $wrapper = Join-Path $result.DistributionFolder 'scripts/backfill-compensation.ps1'
    Assert-DeployedBackfill ([IO.File]::Exists($wrapper)) 'Shared deployment does not expose the migration command.'
    $cache = Join-Path $owned 'local-cache'
    $env:SAPHIR_APP_CACHE_ROOT = $cache
    $before = Get-DataFingerprint
    $failed = $false
    try { & $wrapper -Apply | Out-Null } catch { $failed = $_.Exception.Message -match 'ALL computers' }
    Assert-DeployedBackfill ($failed -and -not [IO.Directory]::Exists($cache)) 'Apply acknowledgement was not checked before installing anything.'
    $preview = & $wrapper
    Assert-DeployedBackfill ($preview.mode -eq 'preview' -and $preview.unavailable -eq 1) 'Shared wrapper did not run the real current-release migration.'
    Assert-DeployedBackfill ((Get-DataFingerprint) -ceq $before) 'Preview changed shared DATA.'
    Assert-DeployedBackfill ([IO.File]::Exists((Join-Path $cache 'versions/deployed-backfill-a/scripts/backfill-compensation.ps1'))) 'Published release was not resolved into a verified local cache.'
    Assert-DeployedBackfill (-not [IO.Directory]::Exists((Join-Path $cache 'runtime'))) 'Migration started/prepared a backend runtime.'
    $applied = & $wrapper -Apply -AppStopped
    Assert-DeployedBackfill ($applied.unavailable -eq 1 -and $applied.mode -eq 'applied') 'Shared migration did not persist the N/A result.'
    $saved = @([IO.File]::ReadAllText($entryPath) | ConvertFrom-Json)[0]
    Assert-DeployedBackfill ($saved.compensationSnapshot.unavailableReason -eq 'employee-classification-missing') 'Current-release salary rules were not used.'
    Assert-DeployedBackfill (-not [IO.Directory]::Exists((Join-Path $cache 'runtime'))) 'Apply started a backend.'
    $again = & $wrapper
    Assert-DeployedBackfill ($again.changedFiles -eq 0) 'Shared wrapper is not repeatable.'
    Write-Host 'Deployed backfill passed: manifest DATA defaults, verified current package, preview safety, offline acknowledgement, N/A migration, idempotency and no backend start.'
} finally {
    $env:SAPHIR_APP_CACHE_ROOT = $previousCache
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
