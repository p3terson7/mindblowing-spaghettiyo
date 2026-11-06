param([switch]$Isolated)
$ErrorActionPreference = 'Stop'
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw 'Windows JSON backfill regression failed.' }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$owned = Join-Path ([IO.Path]::GetTempPath()) ('backfill-windows-json-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $owned 'DATA'
function Assert-WindowsBackfill($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-FixtureHash {
    return (@(Get-ChildItem -LiteralPath $fixture -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|')
}
function ConvertFrom-BackfillLegacyJson {
    [CmdletBinding()]
    param([string]$InputObject)
    # Windows PowerShell returns a JSON array as one pipeline object. Emulate
    # that behavior on PS7 too, without changing unrelated application parsers.
    $parsed = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -ErrorAction Stop
    if ($null -eq $parsed) { return ,@() }
    return ,$parsed
}
try {
    . (Join-Path $repo 'tests/lib/CacheCoherenceFixture.ps1') -FixtureFolder $fixture -Create -EmployeeCount 40
    $source = [IO.File]::ReadAllText((Join-Path $repo 'scripts/backfill-compensation.ps1'))
    $injected = $source.Replace('ConvertFrom-Json -InputObject $usersText -ErrorAction Stop', 'ConvertFrom-BackfillLegacyJson -InputObject $usersText -ErrorAction Stop')
    Assert-WindowsBackfill ($source -cne $injected) 'Legacy parser injection no longer matches the migration.'
    $migration = Join-Path $owned 'backfill.ps1'
    [IO.File]::WriteAllText($migration, $injected)
    $firstPath = Join-Path $fixture '000710001_data.json'
    $entries = @(Read-JsonArrayFile $firstPath)
    $entries[0].status = 'approved'
    Set-ApprovedEntryCompensationSnapshots -EmployeeCode '000710001' -Entries $entries | Out-Null
    $retry = $entries[0].PSObject.Copy()
    $retry.entryId = 'recover-false-missing-user'; $retry.date = '2026-10-02'
    $retry.compensationSnapshot = [PSCustomObject]@{ snapshotStatus = 'unavailable'; unavailableReason = 'employee-user-missing' }
    Write-CoherenceFixtureJson $firstPath @($entries[0], $retry)
    $beforeDocument = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($firstPath))
    $finalJson = ConvertTo-Json -InputObject $beforeDocument[0].compensationSnapshot -Depth 30 -Compress
    foreach ($code in @('000710002', '000710003')) {
        $entryPath = Join-Path $fixture ($code + '_data.json')
        $items = @(Read-JsonArrayFile $entryPath); $items[0].status = 'approved'
        Write-CoherenceFixtureJson $entryPath $items
    }
    $users = @(Read-JsonArrayFile $usersFile | Where-Object employeeCode -ne '000710003')
    ($users | Where-Object employeeCode -eq '000710002').gc179Profile.level = ''
    Write-CoherenceFixtureJson $usersFile $users
    $before = Get-FixtureHash
    $preview = & $migration -DataFolder $fixture -ApplicationRoot (Join-Path $repo 'app')
    Assert-WindowsBackfill ($preview.amounts -eq 1 -and $preview.unavailable -eq 2 -and $preview.issues.Count -eq 2) 'Legacy array parsing failed to match existing employee accounts.'
    Assert-WindowsBackfill (@($preview.issues | Where-Object reason -eq 'employee-user-missing').Count -eq 1) 'Existing employees were falsely reported missing.'
    Assert-WindowsBackfill ((Get-FixtureHash) -ceq $before) 'Preview changed DATA.'
    $applied = & $migration -DataFolder $fixture -ApplicationRoot (Join-Path $repo 'app') -Apply -AppStopped
    Assert-WindowsBackfill ($applied.amounts -eq 1) 'Previously persisted false N/A did not recover.'
    $savedDocument = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($firstPath))
    $saved = @($savedDocument)
    Assert-WindowsBackfill ($saved[1].compensationSnapshot.snapshotStatus -eq 'final' -and $saved[1].compensationSnapshot.totalAmountCents -gt 0) 'Recovered amount was not saved.'
    Assert-WindowsBackfill ((ConvertTo-Json -InputObject $saved[0].compensationSnapshot -Depth 30 -Compress) -ceq $finalJson) 'A finalized amount was changed.'
    $again = & $migration -DataFolder $fixture -ApplicationRoot (Join-Path $repo 'app')
    Assert-WindowsBackfill ($again.changedFiles -eq 0) 'Migration rerun was not idempotent.'

    # Exercise the actual account-index block with zero, one, and many users.
    $start = $injected.IndexOf('$usersText =')
    $end = $injected.IndexOf('# Validate the grid', $start)
    $indexBlock = $injected.Substring($start, $end - $start)
    foreach ($json in @('[]', '[{"username":"000321928"}]', '[{"employeeCode":"000321928"},{"employeeCode":"000340566"}]')) {
        $inputs = @{ 'users.json' = @{ bytes = [Text.Encoding]::UTF8.GetBytes($json) } }
        . ([scriptblock]::Create($indexBlock))
        $expected = @(Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $json | ForEach-Object { $_ }).Count
        Assert-WindowsBackfill ($userByCode.Count -eq $expected) 'Empty/single/multiple legacy user arrays were not normalized.'
    }
    foreach ($json in @('[42]', '[{"employeeCode":"000321928"},{"employeeCode":"000321928"}]')) {
        $inputs = @{ 'users.json' = @{ bytes = [Text.Encoding]::UTF8.GetBytes($json) } }
        $rejected = $false
        try { . ([scriptblock]::Create($indexBlock)) } catch { $rejected = $true }
        Assert-WindowsBackfill $rejected "Malformed or duplicate accounts must fail preflight: $json"
    }
    Write-Host 'Windows JSON backfill passed: 40-employee account matching, numeric usernames, true missing users, classification warnings, safe preview, N/A recovery, final-value preservation and reruns.'
} finally {
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
