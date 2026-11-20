param([switch]$Isolated)
$ErrorActionPreference = 'Stop'
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw 'Compensation backfill subprocess failed.' }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$owned = Join-Path ([IO.Path]::GetTempPath()) ('backfill-test-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $owned 'data'
$scriptPath = Join-Path $repo 'scripts/backfill-compensation.ps1'
$appRoot = Join-Path $repo 'app'
function Assert-Backfill($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-BackfillTestFingerprint([string]$Root) {
    return (@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Root.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|')
}
function Assert-BackfillFailure([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Backfill ($message -match $Pattern) "Expected failure '$Pattern', got '$message'."
}
try {
    . (Join-Path $repo 'tests/lib/CacheCoherenceFixture.ps1') -FixtureFolder $fixture -Create -EmployeeCount 40
    . (Join-Path $repo 'app/backend/services/OvertimeCostSnapshotService.ps1')
    $firstPath = Join-Path $fixture '000710001_data.json'
    $first = @([IO.File]::ReadAllText($firstPath) | ConvertFrom-Json)[0]
    $first.status = 'approved'; $first.overtime = '07:00:00'
    $captured = $first.PSObject.Copy(); $captured.entryId = 'captured'; $captured.date = '2026-10-01'
    Set-ApprovedEntryCompensationSnapshots -EmployeeCode '000710001' -Entries @($captured) | Out-Null
    Assert-Backfill ($captured.compensationSnapshot.snapshotStatus -eq 'final') 'Fixture salary calculation failed.'
    $first.date = '2026-10-02'
    $second = $first.PSObject.Copy(); $second.entryId = 'threshold-crossing'; $second.punchIn = '23:00:00'; $second.overtime = '01:00:00'; $second.paymentOption = 'leave'
    $second | Add-Member -NotePropertyName compensationSnapshot -NotePropertyValue ([PSCustomObject]@{ snapshotStatus = 'unavailable'; unavailableReason = 'old' })
    $pending = $first.PSObject.Copy(); $pending.entryId = 'pending'; $pending.status = 'pending'
    $pending | Add-Member -NotePropertyName compensationSnapshot -NotePropertyValue ([PSCustomObject]@{ preserve = 'pending metadata' })
    $diverse = $first.PSObject.Copy(); $diverse.entryId = 'diverse'; $diverse.entryType = 'diverse'
    $json = ConvertTo-Json -InputObject @($captured, $first, $second, $pending, $diverse) -Depth 30
    # These bytes must survive unchanged, without DateTime/number reserialization.
    $customJson = ',"custom":{"timestamp":"2026-10-15T12:34:56.1234567Z","large":9007199254740993,"escaped":"braces } [ and quote \" and slash \\","nested":[1,{"x":true}]}'
    $lastBrace = $json.LastIndexOf('}')
    $json = $json.Insert($lastBrace, $customJson)
    $originalCapturedJson = ConvertTo-Json -InputObject (@($json | ConvertFrom-Json)[0].compensationSnapshot) -Depth 30 -Compress
    [IO.File]::WriteAllText($firstPath, $json, [Text.UTF8Encoding]::new($true))
    # A second file will be committed, allowing an interruption between files.
    $otherPath = Join-Path $fixture '000710002_data.json'
    $other = @([IO.File]::ReadAllText($otherPath) | ConvertFrom-Json)[0]; $other.status = 'approved'
    Write-CoherenceFixtureJson $otherPath @($other)
    # Unknown schedule must be stored as N/A, never silently priced as zero.
    $unknownPath = Join-Path $fixture '000710003_data.json'
    $unknown = @([IO.File]::ReadAllText($unknownPath) | ConvertFrom-Json)[0]
    $unknown.status = 'approved'; $unknown.workSchedule = 'unconfirmed'
    Write-CoherenceFixtureJson $unknownPath @($unknown)
    $classificationPath = Join-Path $fixture '000710004_data.json'
    $classificationEntry = @([IO.File]::ReadAllText($classificationPath) | ConvertFrom-Json)[0]
    $classificationEntry.status = 'approved'
    Write-CoherenceFixtureJson $classificationPath @($classificationEntry)
    $users = @([IO.File]::ReadAllText($usersFile) | ConvertFrom-Json)
    ($users | Where-Object employeeCode -eq '000710004').gc179Profile.level = ''
    Write-CoherenceFixtureJson $usersFile $users
    $original = @{}
    foreach ($file in Get-ChildItem -LiteralPath $fixture -File) { $original[$file.Name] = [IO.File]::ReadAllBytes($file.FullName) }
    $before = Get-BackfillTestFingerprint $fixture
    $preview = & $scriptPath -DataFolder $fixture
    Assert-Backfill ($preview.mode -eq 'preview' -and $preview.employeeFiles -eq 41 -and $preview.amounts -eq 3 -and $preview.unavailable -eq 2 -and $preview.changedFiles -eq 4 -and $preview.issues.Count -eq 2) 'Preview counts or unavailable-entry report differ.'
    Assert-Backfill ((Get-BackfillTestFingerprint $fixture) -ceq $before) 'Preview wrote DATA or created backups/locks.'
    & (Get-Process -Id $PID).Path -NoProfile -File $scriptPath -DataFolder $fixture | Out-Null
    Assert-Backfill ($LASTEXITCODE -eq 0 -and (Get-BackfillTestFingerprint $fixture) -ceq $before) 'Fresh-process preview initialized or changed storage.'
    Assert-BackfillFailure { & $scriptPath -DataFolder $fixture -Apply } 'ALL computers'
    Assert-Backfill ((Get-BackfillTestFingerprint $fixture) -ceq $before) 'Missing offline acknowledgement changed DATA.'

    # Bad JSON anywhere blocks the entire migration before any employee write.
    $badPath = Join-Path $fixture '999999999_data.json'
    foreach ($bad in @('{broken', 'null', '{}', '[null]', '[{"status":"approved","STATUS":"pending"}]')) {
        [IO.File]::WriteAllText($badPath, $bad)
        $badBefore = Get-BackfillTestFingerprint $fixture
        Assert-BackfillFailure { & $scriptPath -DataFolder $fixture -Apply -AppStopped } 'Preflight failed'
        Assert-Backfill ((Get-BackfillTestFingerprint $fixture) -ceq $badBefore) 'Invalid input caused writes.'
    }
    [IO.File]::Delete($badPath)

    # Fail atomic replacement in an owned copy; no overwrite fallback is allowed.
    $source = [IO.File]::ReadAllText($scriptPath)
    $failureScript = Join-Path $owned 'fail-replace.ps1'
    $injected = $source.Replace('[IO.File]::Replace($stage, $plan.path, [NullString]::Value)', "throw 'injected atomic replace failure'")
    Assert-Backfill ($injected -cne $source) 'Replace injection did not match.'
    [IO.File]::WriteAllText($failureScript, $injected)
    Assert-BackfillFailure { & $failureScript -DataFolder $fixture -ApplicationRoot $appRoot -Apply -AppStopped } 'injected atomic replace failure'
    foreach ($name in $original.Keys) {
        Assert-Backfill ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture $name))) -ceq [Convert]::ToBase64String($original[$name])) 'Failed commit changed an original file.'
    }

    # No commit is allowed unless every backup and its manifest are verified.
    $backupFailureScript = Join-Path $owned 'fail-backup.ps1'
    $backupMarker = 'Write-BackfillNewFile (Join-Path $backupFolder $plan.name) $plan.original'
    $injected = $source.Replace($backupMarker, "throw 'injected backup failure'")
    Assert-Backfill ($injected -cne $source) 'Backup injection did not match.'
    [IO.File]::WriteAllText($backupFailureScript, $injected)
    Assert-BackfillFailure { & $backupFailureScript -DataFolder $fixture -ApplicationRoot $appRoot -Apply -AppStopped } 'injected backup failure'
    foreach ($name in $original.Keys) {
        Assert-Backfill ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture $name))) -ceq [Convert]::ToBase64String($original[$name])) 'Backup failure changed an original file.'
    }

    # Detect a non-cooperating external change even during staging. Never
    # overwrite it or silently restore an older backup over that newer data.
    foreach ($targetName in @('000710001_data.json', 'compensation-grid.json')) {
        $concurrentScript = Join-Path $owned 'concurrent.ps1'
        $stageMarker = 'Write-BackfillNewFile $stage $plan.updated'
        $mutation = '[IO.File]::AppendAllText((Join-Path $dataRoot ''' + $targetName + '''), '' ''); '
        $injected = $source.Replace($stageMarker, $stageMarker + '; ' + $mutation)
        Assert-Backfill ($injected -cne $source) 'Concurrent-write injection did not match.'
        [IO.File]::WriteAllText($concurrentScript, $injected)
        Assert-BackfillFailure { & $concurrentScript -DataFolder $fixture -ApplicationRoot $appRoot -Apply -AppStopped } 'changed after preflight'
        $targetPath = Join-Path $fixture $targetName
        $expected = [byte[]]@($original[$targetName] + [byte]32)
        Assert-Backfill ([Convert]::ToBase64String([IO.File]::ReadAllBytes($targetPath)) -ceq [Convert]::ToBase64String($expected)) 'External change was overwritten.'
        [IO.File]::WriteAllBytes($targetPath, $original[$targetName])
    }

    # Simulate a crash after the first atomic commit, then resume normally.
    $interruptedScript = Join-Path $owned 'interrupt.ps1'
    $marker = 'Write-BackfillNewFile (Join-Path $backupFolder ($plan.name + ''.completed.json''))'
    $injected = $source.Replace($marker, "throw 'injected interruption'; " + $marker)
    Assert-Backfill ($injected -cne $source) 'Interruption injection did not match.'
    [IO.File]::WriteAllText($interruptedScript, $injected)
    Assert-BackfillFailure { & $interruptedScript -DataFolder $fixture -ApplicationRoot $appRoot -Apply -AppStopped } 'injected interruption'
    $partiallySaved = @([IO.File]::ReadAllText($firstPath) | ConvertFrom-Json)
    Assert-Backfill ($partiallySaved.Count -eq 5 -and $partiallySaved[1].compensationSnapshot.snapshotStatus -eq 'final') 'Interrupted file is not a complete valid document.'
    $firstAfterInterruption = [IO.File]::ReadAllBytes($firstPath)
    $result = & $scriptPath -DataFolder $fixture -Apply -AppStopped
    Assert-Backfill ($result.amounts -eq 1 -and $result.unavailable -eq 2 -and $result.changedFiles -eq 3) 'Resume did not skip already saved amounts or persist N/A.'
    Assert-Backfill ([Convert]::ToBase64String([IO.File]::ReadAllBytes($firstPath)) -ceq [Convert]::ToBase64String($firstAfterInterruption)) 'Resume rewrote a completed file.'
    $savedText = [IO.File]::ReadAllText($firstPath)
    Assert-Backfill ($savedText.Contains($customJson)) 'Unknown fields, date strings, large numbers or escaped text changed.'
    $saved = @($savedText | ConvertFrom-Json)
    Assert-Backfill ((ConvertTo-Json $saved[0].compensationSnapshot -Depth 30 -Compress) -ceq $originalCapturedJson) 'Existing final snapshot changed.'
    Assert-Backfill ($saved[2].compensationSnapshot.previouslyCreditedMinutes -eq 420 -and $saved[2].compensationSnapshot.segments.Count -eq 2) 'Daily thresholds were calculated per entry instead of per employee.'
    Assert-Backfill ($saved[2].compensationSnapshot.cashAmountCents -eq 0 -and $saved[2].compensationSnapshot.compensatoryLeaveValueCents -gt 0) 'Compensatory leave value changed.'
    Assert-Backfill ($saved[3].compensationSnapshot.preserve -eq 'pending metadata') 'Pending-entry metadata was removed.'
    Assert-Backfill ($saved[4].PSObject.Properties.Name -notcontains 'compensationSnapshot') 'Diverse entry received an amount.'
    $savedUnknown = @([IO.File]::ReadAllText($unknownPath) | ConvertFrom-Json)[0]
    Assert-Backfill ($savedUnknown.compensationSnapshot.snapshotStatus -eq 'unavailable' -and $null -eq $savedUnknown.compensationSnapshot.totalAmountCents) 'Unavailable amount was not persisted as N/A.'
    $savedClassification = @([IO.File]::ReadAllText($classificationPath) | ConvertFrom-Json)[0]
    Assert-Backfill ($savedClassification.compensationSnapshot.unavailableReason -eq 'employee-classification-missing' -and $null -eq $savedClassification.compensationSnapshot.totalAmountCents) 'Missing echelon prevented transition instead of persisting N/A.'
    foreach ($name in @('users.json', 'compensation-grid.json', 'sync-state.json')) {
        Assert-Backfill ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture $name))) -ceq [Convert]::ToBase64String($original[$name])) "Unrelated/unavailable file changed: $name"
    }
    $allBackups = @(Get-ChildItem -LiteralPath (Join-Path $fixture '.saphir-backups') -Directory)
    Assert-Backfill ($allBackups.Count -eq 6) 'Expected retained backups for failures, external changes, interruption and resume.'
    $firstBackup = $allBackups | Sort-Object Name | Select-Object -First 1
    foreach ($name in @('users.json', 'compensation-grid.json', '000710001_data.json', '000710002_data.json')) {
        Assert-Backfill ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $firstBackup.FullName $name))) -ceq [Convert]::ToBase64String($original[$name])) 'Backup is not byte-for-byte identical.'
    }
    $againBefore = Get-BackfillTestFingerprint $fixture
    $again = & $scriptPath -DataFolder $fixture -Apply -AppStopped
    Assert-Backfill ($again.amounts -eq 0 -and $again.changedFiles -eq 0 -and $null -eq $again.backupFolder) 'Rerun is not a no-op.'
    Assert-Backfill ((Get-BackfillTestFingerprint $fixture) -ceq $againBefore) 'Rerun changed DATA, backups or manifests.'
    Write-Host 'Compensation backfill passed: read-only preview, validation, backups, atomic failure, interruption/resume, exact field preservation, captured amounts, daily thresholds, leave, unavailable rows and idempotency.'
} finally {
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
