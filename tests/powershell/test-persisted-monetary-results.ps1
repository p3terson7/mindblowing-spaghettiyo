param([switch]$Isolated)
$ErrorActionPreference = 'Stop'
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw 'Persisted monetary result subprocess failed.' }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('stored-money-' + [Guid]::NewGuid().ToString('N'))
function Assert-Stored($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    . (Join-Path $repo 'tests/lib/CacheCoherenceFixture.ps1') -FixtureFolder $fixture -Create -EmployeeCount 4
    $users = @(Read-JsonArrayFile $usersFile)
    ($users | Where-Object employeeCode -eq '000710001').gc179Profile.level = ''
    ($users | Where-Object employeeCode -eq '000710003').gc179Profile.subGroup = '99'
    Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 16
    Clear-AuthRuntimeCaches
    foreach ($code in @('000710001', '000710002', '000710003', '000710004')) {
        $path = Join-Path $fixture ($code + '_data.json')
        $entries = @(Read-JsonArrayFile $path); $entries[0].status = 'approved'
        if ($code -eq '000710002') { $entries[0].workSchedule = 'unconfirmed' }
        Write-JsonArrayAtomic -Path $path -Items $entries -Depth 16
        if ($code -ne '000710004') { Update-EmployeeApprovedCompensationSnapshots -EmployeeCode $code | Out-Null }
    }
    $missingPath = Join-Path $fixture '000710001_data.json'
    $missing = @(Read-JsonArrayFile $missingPath)[0]
    Assert-Stored ($missing.compensationSnapshot.snapshotStatus -eq 'unavailable' -and $missing.compensationSnapshot.unavailableReason -eq 'employee-classification-missing') 'Missing echelon was not persisted as unavailable.'
    Assert-Stored ($null -eq $missing.compensationSnapshot.totalAmountCents) 'Missing echelon became zero dollars.'
    $before = [IO.File]::ReadAllText($missingPath)
    $again = Update-EmployeeApprovedCompensationSnapshots -EmployeeCode '000710001'
    Assert-Stored (-not $again.changed -and [IO.File]::ReadAllText($missingPath) -ceq $before) 'Stable N/A was rewritten.'

    # A cold read, a warm read and a cache reset must all remain pure reads,
    # including entries that were never migrated. Any salary lookup fails.
    $getGrid = ${function:Get-CompensationGrid}
    function Get-CompensationGrid { throw 'Salary calculation was attempted during a read.' }
    $beforeFiles = @{}
    foreach ($file in Get-ChildItem $fixture -Filter '*_data.json') { $beforeFiles[$file.FullName] = [IO.File]::ReadAllText($file.FullName) }
    foreach ($pass in 1..3) {
        if ($pass -eq 3) { Clear-AllEmployeeEntryCaches }
        foreach ($path in $beforeFiles.Keys) {
            $rows = @(Get-CachedEmployeeEntriesForFile -DataFile $path -IncludeMonetary)
            if ($rows.Count -eq 0) { continue }
            $money = New-EntryMonetaryReadModel $rows[0]
            Assert-Stored ($money.status -eq 'unavailable' -and $null -eq $money.totalAmountCents) 'A read calculated an unavailable/unmigrated amount.'
            Assert-Stored ([IO.File]::ReadAllText($path) -ceq $beforeFiles[$path]) 'A monetary read wrote DATA.'
        }
    }
    Set-Item Function:Get-CompensationGrid $getGrid
    Assert-Stored ($null -eq (Get-Command Get-EmployeeCompensationReadEstimates -ErrorAction SilentlyContinue)) 'Legacy calculation fallback still exists.'

    # Completing echelon persists the result once; subsequent reads need no
    # classification/grid dependency and must not reprice existing history.
    ($users | Where-Object employeeCode -eq '000710001').gc179Profile.level = '01'
    Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 16; Clear-AuthRuntimeCaches
    $fixed = Update-EmployeeApprovedCompensationSnapshots -EmployeeCode '000710001'
    $captured = @(Read-JsonArrayFile $missingPath)[0].compensationSnapshot
    Assert-Stored ($fixed.changed -and $captured.snapshotStatus -eq 'final' -and $captured.totalAmountCents -gt 0) 'Completing classification did not resolve N/A.'
    $capturedText = ConvertTo-Json -InputObject $captured -Depth 30 -Compress
    ($users | Where-Object employeeCode -eq '000710001').gc179Profile.level = '02'
    Write-JsonArrayAtomic -Path $usersFile -Items $users -Depth 16; Clear-AuthRuntimeCaches
    $promotion = Update-EmployeeApprovedCompensationSnapshots -EmployeeCode '000710001'
    Assert-Stored (-not $promotion.changed) 'A promotion repriced a final amount.'

    # Entry schedule correction uses the same write-time calculation path.
    $schedulePath = Join-Path $fixture '000710002_data.json'
    $scheduleRows = @(Read-JsonArrayFile $schedulePath)
    Assert-Stored ($scheduleRows[0].compensationSnapshot.unavailableReason -eq 'work-schedule-unconfirmed') 'Schedule N/A reason was lost.'
    $scheduleRows[0].workSchedule = 'compressed'
    Set-ApprovedEntryCompensationSnapshots -EmployeeCode '000710002' -Entries $scheduleRows | Out-Null
    Write-JsonArrayAtomic -Path $schedulePath -Items $scheduleRows -Depth 16
    Assert-Stored (@(Read-JsonArrayFile $schedulePath)[0].compensationSnapshot.totalAmountCents -gt 0) 'Schedule correction did not resolve N/A.'

    # Adding a missing salary band resolves N/A on the grid-save workflow.
    $grid = Get-CompensationGrid
    $band = [PSCustomObject]@{ id = 'cr-99-01'; group = 'CR'; subGroup = '99'; level = '01'; annualSalaryCents = 6000000; effectiveFrom = '2026-01-01'; effectiveTo = '' }
    Set-CompensationGrid -Bands @(@($grid.bands) + $band) | Out-Null
    $refresh = Update-UnavailableCompensationSnapshotsForGrid
    Assert-Stored ($refresh.warnings.Count -eq 0 -and $refresh.changedEmployeeCodes -contains '000710003') 'Salary-grid correction did not resolve missing-band N/A.'
    Assert-Stored ((ConvertTo-Json -InputObject (@(Read-JsonArrayFile $missingPath)[0].compensationSnapshot) -Depth 30 -Compress) -ceq $capturedText) 'Grid refresh changed a captured final amount.'
    $source = [IO.File]::ReadAllText((Join-Path $repo 'app/backend/routes/employee/work-schedule.routes.ps1'))
    Assert-Stored ($source.IndexOf('Set-ApprovedEntryCompensationSnapshots') -lt $source.IndexOf('Write-JsonArrayAtomic')) 'Bulk schedule save does not refresh amounts before commit.'
    $source = [IO.File]::ReadAllText((Join-Path $repo 'app/backend/routes/employee/delete.routes.ps1'))
    Assert-Stored ($source.IndexOf('Set-ApprovedEntryCompensationSnapshots') -lt $source.IndexOf('Write-JsonArrayAtomic')) 'Deletion does not refresh remaining daily/adjacent-day amounts.'
    Write-Host 'Persisted monetary results passed: N/A, no cold/warm/read fallback, classification/schedule/grid recovery, final-history preservation and mutation hooks.'
} finally { if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
