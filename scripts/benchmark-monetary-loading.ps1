param([ValidateRange(10, 10000)][int]$EntriesPerEmployee = 200, [ValidateRange(1, 40)][int]$EmployeeCount = 5)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
# In-memory synthetic fixtures only. No application configuration or shared DATA.
. (Join-Path $repoRoot "app/backend/lib/CommonHelpers.ps1")
. (Join-Path $repoRoot "app/backend/services/EntryService.ps1")
. (Join-Path $repoRoot "app/backend/services/ReadModelService.ps1")
. (Join-Path $repoRoot "app/backend/services/CompensationGridService.ps1")
. (Join-Path $repoRoot "app/backend/services/OvertimeCostSnapshotService.ps1")
$script:gridReads = 0
$script:FixtureGridRaw = Get-Content (Join-Path $repoRoot "app/backend/defaults/compensation-grid.v1.json") -Raw
$script:compensationGridFile = "memory://salary-grid.json"
$script:FixtureGetGrid = ${function:Get-CompensationGrid}
function Read-TextFileCached { param([string]$Path) return $script:FixtureGridRaw }
$script:FixtureUser = [PSCustomObject]@{ gc179Profile = [PSCustomObject]@{ group = "CR"; subGroup = "04"; level = "01" } }
function Get-EmployeeUserByCode { param([string]$EmployeeCode) return $script:FixtureUser }
function Get-EmployeeClassificationFromUserRecord { param($UserRecord) return $UserRecord.gc179Profile }
function Get-CompensationGrid {
    $script:gridReads++
    return (& $script:FixtureGetGrid)
}
$script:ReadModelFactoryDepth = 1
$fixtures = @{}
for ($employeeIndex = 1; $employeeIndex -le $EmployeeCount; $employeeIndex++) {
    $code = "{0:000000000}" -f $employeeIndex
    $fixtures[$code] = @(for ($index = 0; $index -lt $EntriesPerEmployee; $index++) {
        [PSCustomObject]@{ entryId = "entry-$index"; entryType = "overtime"; projectCode = "TEST"; date = ([DateTime]"2026-01-01").AddDays($index % 250).ToString("yyyy-MM-dd"); punchIn = "17:00:00"; punchOut = "18:00:00"; overtime = "01:00:00"; status = "approved"; overtimeCode = "260"; paymentOption = "cash"; workSchedule = "regular" }
    })
}
$metadata = [PSCustomObject]@{ LastWriteTicks = 100; Length = 200 }
function Measure-FixtureLoad {
    $beforeReads = $script:gridReads
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($code in $fixtures.Keys) {
        Get-CachedEmployeeMonetaryEntries -DataFile "$($code)_data.json" -Metadata $metadata -Entries $fixtures[$code] | Out-Null
    }
    $watch.Stop()
    return [PSCustomObject]@{ milliseconds = [math]::Round($watch.Elapsed.TotalMilliseconds, 1); salaryGridLoads = $script:gridReads - $beforeReads }
}
$cold = Measure-FixtureLoad
$warm = Measure-FixtureLoad
# Every shared revision clears the general view cache; the monetary cache
# should survive this when none of its source data has changed.
$script:ReadModelCache = @{}
$afterUnrelatedChange = Measure-FixtureLoad
[PSCustomObject]@{ employees = $EmployeeCount; entries = $EmployeeCount * $EntriesPerEmployee; cold = $cold; warm = $warm; afterUnrelatedChange = $afterUnrelatedChange } | ConvertTo-Json -Depth 5
