$ErrorActionPreference = "Stop"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("saphir-money-cache-{0}" -f [Guid]::NewGuid().ToString("N"))
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $script:sharedFolder = $fixtureRoot
    . (Join-Path $repoRoot "app/backend/lib/CommonHelpers.ps1")
    . (Join-Path $repoRoot "app/backend/lib/FileStore.ps1")
    . (Join-Path $repoRoot "app/backend/services/EntryService.ps1")
    . (Join-Path $repoRoot "app/backend/services/ReadModelService.ps1")
    $script:EstimateCalls = 0
    function Get-EmployeeCompensationReadEstimates {
        param([string]$EmployeeCode, $Entries)
        $script:EstimateCalls++
        return $Entries
    }
    $script:FixtureState = [PSCustomObject]@{
        version = 1; changeId = [Guid]::NewGuid().ToString(); category = "history"; resource = "test"
        employeeDataEpoch = [Guid]::NewGuid().ToString(); employeeDataRevisions = @{}
    }
    function Get-SyncState { return $script:FixtureState }
    $script:FixtureGridKey = "grid-v1"
    function Get-CompensationGridCacheKey { throw 'Entry reads must not inspect salary grid dependencies.' }
    $script:FixtureUsers = @{}
    function Get-EmployeeUserByCode { param([string]$EmployeeCode) return $script:FixtureUsers[$EmployeeCode] }
    function Get-EmployeeClassificationFromUserRecord { param($UserRecord) return $UserRecord.gc179Profile }
    function Advance-FixtureRevision([string]$Category, [string]$Resource = "test", [switch]$EmployeeChanged, [int]$Step = 1, [switch]$RotateEpoch) {
        $previous = $script:FixtureState
        $script:FixtureState = [PSCustomObject]@{
            version = $previous.version + $Step; changeId = [Guid]::NewGuid().ToString(); category = $Category; resource = $Resource
            employeeDataEpoch = if ($RotateEpoch) { [Guid]::NewGuid().ToString() } else { $previous.employeeDataEpoch }
            employeeDataRevisions = $previous.employeeDataRevisions.Clone()
        }
        if ($EmployeeChanged) { $script:FixtureState.employeeDataRevisions[$Resource] = $script:FixtureState.changeId }
    }
    $files = @()
    foreach ($code in @("000000001", "000000002")) {
        $script:FixtureUsers[$code] = [PSCustomObject]@{ gc179Profile = [PSCustomObject]@{ group = "CR"; subGroup = "04"; level = "01" } }
        $file = Join-Path $fixtureRoot "$($code)_data.json"
        $files += $file
        [System.IO.File]::WriteAllText($file, '[{"entryId":"one","entryType":"overtime","date":"2026-09-01","punchIn":"17:00:00","punchOut":"18:00:00","overtime":"01:00:00","status":"approved","overtimeCode":"260","workSchedule":"regular"}]')
        $script:FixtureState.employeeDataRevisions[$code] = [Guid]::NewGuid().ToString()
    }
    $beforeFiles = @($files | ForEach-Object { [System.IO.File]::ReadAllText($_) })
    Get-CachedEmployeeEntriesForFile -DataFile $files[0] | Out-Null
    Assert-Equal 0 $script:EstimateCalls "Plain/self/GC179 reads must not load the monetary engine."
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "Cold monetary reads must never calculate amounts."
    foreach ($category in @("history", "project", "auth", "budget-periods", "bug-reports")) {
        Advance-FixtureRevision -Category $category
        foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
        Assert-Equal 0 $script:EstimateCalls "$category refreshes must never calculate amounts."
    }
    Advance-FixtureRevision -Category "employee" -Resource "000000001" -EmployeeChanged
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "An employee refresh must read persisted amounts."
    Advance-FixtureRevision -Category "employee-directory" -Resource "000000002" -EmployeeChanged
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "Profile changes must not trigger read-time calculations."
    Advance-FixtureRevision -Category "compensation"
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "Grid changes must not trigger read-time calculations."
    Advance-FixtureRevision -Category "history" -Step 2
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "Coalesced revisions must not calculate amounts."
    $script:FixtureGridKey = "grid-v2"
    Advance-FixtureRevision -Category "history" -Step 2
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "Hidden salary changes must not trigger read-time calculations."
    $script:FixtureUsers["000000001"].gc179Profile.level = "02"
    Advance-FixtureRevision -Category "auth"
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "Classification changes must not trigger read-time calculations."
    Advance-FixtureRevision -Category "history" -RotateEpoch
    foreach ($file in $files) { Get-CachedEmployeeEntriesForFile -DataFile $file -IncludeMonetary | Out-Null }
    Assert-Equal 0 $script:EstimateCalls "Epoch changes must still only read persisted amounts."
    for ($index = 0; $index -lt $files.Count; $index++) {
        Assert-Equal $beforeFiles[$index] ([System.IO.File]::ReadAllText($files[$index])) "Read-cache invalidation wrote an employee file."
    }
    Write-Host "Monetary loading tests passed: zero salary calculations on cold/warm reads or source invalidation, and no shared writes."
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
