param(
    [ValidateRange(10, 100000)]
    [int]$UserCount = 1000,

    [ValidateRange(1, 100000)]
    [int]$HistoryRecordCount = 1000,

    [ValidateRange(1, 1000)]
    [int]$HistoryAppendCount = 25,

    [ValidateRange(3, 51)]
    [int]$Iterations = 5,

    [ValidateSet("Table", "Json")]
    [string]$OutputFormat = "Table"
)

$ErrorActionPreference = "Stop"

# This benchmark intentionally implements only the JSON read/parse/write shapes
# used by the application. It never imports application configuration or reads
# repository data; every fixture lives under a unique OS temporary directory.
$script:FixtureReadCount = 0
$script:FixtureParseCount = 0
$script:FixtureWriteCount = 0
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Reset-FixtureOperationCounters {
    $script:FixtureReadCount = 0
    $script:FixtureParseCount = 0
    $script:FixtureWriteCount = 0
}

function Write-RawFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Read-JsonFixture {
    param([Parameter(Mandatory = $true)][string]$Path)

    $script:FixtureReadCount++
    $content = [System.IO.File]::ReadAllText($Path)
    $script:FixtureParseCount++
    if ([string]::IsNullOrWhiteSpace($content)) {
        return @()
    }

    return @($content | ConvertFrom-Json)
}

function Write-JsonFixtureAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 8
    )

    $script:FixtureWriteCount++
    $json = ConvertTo-Json -InputObject @($Value) -Depth $Depth -Compress
    $tempPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"

    try {
        [System.IO.File]::WriteAllText($tempPath, $json, $script:Utf8NoBom)
        if (Test-Path -Path $Path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($tempPath, $Path, $null, $true)
            }
            catch {
                Move-Item -Path $tempPath -Destination $Path -Force
            }
        }
        else {
            Move-Item -Path $tempPath -Destination $Path -Force
        }
    }
    finally {
        if (Test-Path -Path $tempPath -PathType Leaf) {
            Remove-Item -Path $tempPath -Force
        }
    }
}

function New-SyntheticUsers {
    param([Parameter(Mandatory = $true)][int]$Count)

    $users = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $Count; $index++) {
        $employeeNumber = $index + 1
        $employeeCode = "{0:D9}" -f $employeeNumber
        $role = if (($employeeNumber % 25) -eq 0) { "manager" } else { "employee" }
        $null = $users.Add([PSCustomObject]@{
            username           = $employeeCode
            employeeCode       = $employeeCode
            displayName        = "Synthetic Employee $employeeNumber"
            role               = $role
            disabled           = $false
            timeEntryTypes     = @("overtime")
            gc179Profile       = [PSCustomObject]@{
                surname   = "EMPLOYEE$employeeNumber"
                givenName = "SYNTHETIC"
                initials  = "SE"
                pri       = "{0:D9}" -f $employeeNumber
                position  = "AS-01"
                level     = "1"
            }
            passwordSalt       = "synthetic-salt-$employeeNumber"
            passwordHash       = "synthetic-hash-$employeeNumber"
            passwordIterations = 120000
            passwordAlgorithm  = "PBKDF2-HMACSHA1"
        })
    }

    return $users.ToArray()
}

function New-SyntheticHistory {
    param(
        [Parameter(Mandatory = $true)][int]$Count,
        [int]$StartingIndex = 0
    )

    $records = New-Object System.Collections.ArrayList
    $baseTimestamp = [DateTime]::ParseExact("2026-01-01 08:00:00", "yyyy-MM-dd HH:mm:ss", $null)
    for ($offset = 0; $offset -lt $Count; $offset++) {
        $recordNumber = $StartingIndex + $offset + 1
        $employeeNumber = ($recordNumber % 100) + 1
        $employeeName = "Synthetic Employee $employeeNumber"
        $null = $records.Add([PSCustomObject]@{
            action         = "Approved"
            message        = "Approved synthetic overtime entry $recordNumber."
            employee       = $employeeName
            targetEmployee = $employeeName
            author         = "Synthetic Manager"
            authorUsername = "benchmark-manager"
            authorRole     = "manager"
            timestamp      = $baseTimestamp.AddSeconds($recordNumber).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }

    return $records.ToArray()
}

function Get-SyntheticUser {
    param(
        [Parameter(Mandatory = $true)]$Users,
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    foreach ($user in @($Users)) {
        if ([string]$user.username -eq $EmployeeCode) {
            return $user
        }
    }

    throw "Synthetic user '$EmployeeCode' was not found."
}

function Invoke-SequentialProfileMutation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    foreach ($field in @("displayName", "role", "timeEntryTypes", "gc179Profile")) {
        $users = @(Read-JsonFixture -Path $Path)
        $target = Get-SyntheticUser -Users $users -EmployeeCode $EmployeeCode

        switch ($field) {
            "displayName" {
                $target.displayName = "Updated Benchmark Employee"
            }
            "role" {
                $target.role = "admin"
            }
            "timeEntryTypes" {
                $target.timeEntryTypes = @("overtime", "standby")
            }
            "gc179Profile" {
                $target.gc179Profile = [PSCustomObject]@{
                    surname   = "BENCHMARK"
                    givenName = "UPDATED"
                    initials  = "BU"
                    pri       = "123456789"
                    position  = "AS-03"
                    level     = "3"
                }
            }
        }

        Write-JsonFixtureAtomic -Path $Path -Value $users -Depth 8
    }
}

function Invoke-BatchedProfileMutation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EmployeeCode
    )

    $users = @(Read-JsonFixture -Path $Path)
    $target = Get-SyntheticUser -Users $users -EmployeeCode $EmployeeCode
    $target.displayName = "Updated Benchmark Employee"
    $target.role = "admin"
    $target.timeEntryTypes = @("overtime", "standby")
    $target.gc179Profile = [PSCustomObject]@{
        surname   = "BENCHMARK"
        givenName = "UPDATED"
        initials  = "BU"
        pri       = "123456789"
        position  = "AS-03"
        level     = "3"
    }

    Write-JsonFixtureAtomic -Path $Path -Value $users -Depth 8
}

function Invoke-SequentialHistoryAppend {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$NewEntries
    )

    foreach ($entry in @($NewEntries)) {
        $history = @(Read-JsonFixture -Path $Path)
        $history = @($history) + $entry
        Write-JsonFixtureAtomic -Path $Path -Value $history -Depth 8
    }
}

function Invoke-BatchedHistoryAppend {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$NewEntries
    )

    $history = @(Read-JsonFixture -Path $Path)
    $history = @($history) + @($NewEntries)
    Write-JsonFixtureAtomic -Path $Path -Value $history -Depth 8
}

function Invoke-BenchmarkMeasurements {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SeedJson,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][int]$MeasurementCount
    )

    # Warm the PowerShell/JIT and filesystem paths once without recording it.
    Write-RawFixture -Path $Path -Content $SeedJson
    Reset-FixtureOperationCounters
    & $Action -Path $Path | Out-Null

    $measurements = New-Object System.Collections.ArrayList
    for ($iteration = 1; $iteration -le $MeasurementCount; $iteration++) {
        Write-RawFixture -Path $Path -Content $SeedJson
        Reset-FixtureOperationCounters

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        & $Action -Path $Path | Out-Null
        $stopwatch.Stop()

        $null = $measurements.Add([PSCustomObject]@{
            Milliseconds = $stopwatch.Elapsed.TotalMilliseconds
            Reads        = $script:FixtureReadCount
            Parses       = $script:FixtureParseCount
            Writes       = $script:FixtureWriteCount
        })
    }

    return $measurements.ToArray()
}

function Get-Median {
    param([Parameter(Mandatory = $true)]$Values)

    $sorted = @($Values | ForEach-Object { [double]$_ } | Sort-Object)
    if ($sorted.Count -eq 0) {
        throw "Cannot calculate a median without samples."
    }

    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [double]$sorted[$middle]
    }

    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-Percentile95 {
    param([Parameter(Mandatory = $true)]$Values)

    $sorted = @($Values | ForEach-Object { [double]$_ } | Sort-Object)
    if ($sorted.Count -eq 0) {
        throw "Cannot calculate a percentile without samples."
    }

    $index = [int][Math]::Ceiling($sorted.Count * 0.95) - 1
    if ($index -lt 0) {
        $index = 0
    }
    return [double]$sorted[$index]
}

function New-BenchmarkResult {
    param(
        [Parameter(Mandatory = $true)][string]$Workload,
        [Parameter(Mandatory = $true)][string]$Strategy,
        [Parameter(Mandatory = $true)][int]$FixtureRecords,
        [Parameter(Mandatory = $true)][int]$Mutations,
        [Parameter(Mandatory = $true)]$Measurements
    )

    $milliseconds = @($Measurements | ForEach-Object { $_.Milliseconds })
    return [PSCustomObject]@{
        Workload        = $Workload
        Strategy        = $Strategy
        FixtureRecords  = $FixtureRecords
        Mutations       = $Mutations
        Samples         = $milliseconds.Count
        MedianMs        = [Math]::Round((Get-Median -Values $milliseconds), 2)
        P95Ms           = [Math]::Round((Get-Percentile95 -Values $milliseconds), 2)
        MinMs           = [Math]::Round((($milliseconds | Measure-Object -Minimum).Minimum), 2)
        MaxMs           = [Math]::Round((($milliseconds | Measure-Object -Maximum).Maximum), 2)
        ReadsPerRun     = [int](Get-Median -Values @($Measurements | ForEach-Object { $_.Reads }))
        ParsesPerRun    = [int](Get-Median -Values @($Measurements | ForEach-Object { $_.Parses }))
        WritesPerRun    = [int](Get-Median -Values @($Measurements | ForEach-Object { $_.Writes }))
        RelativeSpeedup = 1.0
    }
}

function Assert-ProfileFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][int]$ExpectedCount
    )

    $users = @([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    if ($users.Count -ne $ExpectedCount) {
        throw "Profile benchmark changed the user count: expected $ExpectedCount, found $($users.Count)."
    }

    $target = Get-SyntheticUser -Users $users -EmployeeCode $EmployeeCode
    if ([string]$target.displayName -ne "Updated Benchmark Employee" -or
        [string]$target.role -ne "admin" -or
        @($target.timeEntryTypes).Count -ne 2 -or
        [string]$target.gc179Profile.surname -ne "BENCHMARK") {
        throw "Profile benchmark validation failed for '$EmployeeCode'."
    }
}

function Assert-HistoryFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ExpectedCount
    )

    $history = @([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    if ($history.Count -ne $ExpectedCount) {
        throw "History benchmark changed the record count: expected $ExpectedCount, found $($history.Count)."
    }
}

$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-performance-{0}" -f ([Guid]::NewGuid().ToString("N")))
$report = $null

try {
    New-Item -ItemType Directory -Path $tempFolder | Out-Null

    $users = @(New-SyntheticUsers -Count $UserCount)
    $history = @(New-SyntheticHistory -Count $HistoryRecordCount)
    $newHistoryEntries = @(New-SyntheticHistory -Count $HistoryAppendCount -StartingIndex $HistoryRecordCount)
    $usersSeedJson = ConvertTo-Json -InputObject $users -Depth 8 -Compress
    $historySeedJson = ConvertTo-Json -InputObject $history -Depth 8 -Compress
    $targetEmployeeCode = "{0:D9}" -f ([int][Math]::Ceiling($UserCount / 2.0))

    $sequentialProfilePath = Join-Path -Path $tempFolder -ChildPath "users-sequential.json"
    $batchedProfilePath = Join-Path -Path $tempFolder -ChildPath "users-batched.json"
    $sequentialHistoryPath = Join-Path -Path $tempFolder -ChildPath "history-sequential.json"
    $batchedHistoryPath = Join-Path -Path $tempFolder -ChildPath "history-batched.json"

    $sequentialProfileAction = {
        param([string]$Path)
        Invoke-SequentialProfileMutation -Path $Path -EmployeeCode $targetEmployeeCode
    }
    $batchedProfileAction = {
        param([string]$Path)
        Invoke-BatchedProfileMutation -Path $Path -EmployeeCode $targetEmployeeCode
    }
    $sequentialHistoryAction = {
        param([string]$Path)
        Invoke-SequentialHistoryAppend -Path $Path -NewEntries $newHistoryEntries
    }
    $batchedHistoryAction = {
        param([string]$Path)
        Invoke-BatchedHistoryAppend -Path $Path -NewEntries $newHistoryEntries
    }

    $sequentialProfileMeasurements = @(Invoke-BenchmarkMeasurements -Path $sequentialProfilePath -SeedJson $usersSeedJson -Action $sequentialProfileAction -MeasurementCount $Iterations)
    Assert-ProfileFixture -Path $sequentialProfilePath -EmployeeCode $targetEmployeeCode -ExpectedCount $UserCount

    $batchedProfileMeasurements = @(Invoke-BenchmarkMeasurements -Path $batchedProfilePath -SeedJson $usersSeedJson -Action $batchedProfileAction -MeasurementCount $Iterations)
    Assert-ProfileFixture -Path $batchedProfilePath -EmployeeCode $targetEmployeeCode -ExpectedCount $UserCount

    $sequentialHistoryMeasurements = @(Invoke-BenchmarkMeasurements -Path $sequentialHistoryPath -SeedJson $historySeedJson -Action $sequentialHistoryAction -MeasurementCount $Iterations)
    Assert-HistoryFixture -Path $sequentialHistoryPath -ExpectedCount ($HistoryRecordCount + $HistoryAppendCount)

    $batchedHistoryMeasurements = @(Invoke-BenchmarkMeasurements -Path $batchedHistoryPath -SeedJson $historySeedJson -Action $batchedHistoryAction -MeasurementCount $Iterations)
    Assert-HistoryFixture -Path $batchedHistoryPath -ExpectedCount ($HistoryRecordCount + $HistoryAppendCount)

    $sequentialProfileResult = New-BenchmarkResult -Workload "User profile mutation" -Strategy "4 sequential transactions" -FixtureRecords $UserCount -Mutations 4 -Measurements $sequentialProfileMeasurements
    $batchedProfileResult = New-BenchmarkResult -Workload "User profile mutation" -Strategy "1 batched transaction" -FixtureRecords $UserCount -Mutations 4 -Measurements $batchedProfileMeasurements
    $sequentialHistoryResult = New-BenchmarkResult -Workload "History append" -Strategy "$HistoryAppendCount sequential appends" -FixtureRecords $HistoryRecordCount -Mutations $HistoryAppendCount -Measurements $sequentialHistoryMeasurements
    $batchedHistoryResult = New-BenchmarkResult -Workload "History append" -Strategy "1 batched append" -FixtureRecords $HistoryRecordCount -Mutations $HistoryAppendCount -Measurements $batchedHistoryMeasurements

    if ($batchedProfileResult.MedianMs -gt 0) {
        $batchedProfileResult.RelativeSpeedup = [Math]::Round(($sequentialProfileResult.MedianMs / $batchedProfileResult.MedianMs), 2)
    }
    if ($batchedHistoryResult.MedianMs -gt 0) {
        $batchedHistoryResult.RelativeSpeedup = [Math]::Round(($sequentialHistoryResult.MedianMs / $batchedHistoryResult.MedianMs), 2)
    }

    $results = @(
        $sequentialProfileResult,
        $batchedProfileResult,
        $sequentialHistoryResult,
        $batchedHistoryResult
    )

    $report = [PSCustomObject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        PowerShell      = $PSVersionTable.PSVersion.ToString()
        Runtime         = [Environment]::Version.ToString()
        OperatingSystem = [Environment]::OSVersion.VersionString
        DataPolicy      = "Synthetic fixtures in a unique OS temporary directory; deleted after the run."
        Parameters      = [PSCustomObject]@{
            UserCount          = $UserCount
            HistoryRecordCount = $HistoryRecordCount
            HistoryAppendCount = $HistoryAppendCount
            Iterations         = $Iterations
            WarmupIterations   = 1
        }
        Results         = $results
    }
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force
    }
}

if ($OutputFormat -eq "Json") {
    $report | ConvertTo-Json -Depth 7
}
else {
    Write-Host "Synthetic JSON performance baseline"
    Write-Host ("Fixtures: {0} users; {1} history records; {2} appended records; {3} measured runs" -f $UserCount, $HistoryRecordCount, $HistoryAppendCount, $Iterations)
    Write-Host "Fixture setup, validation, and one warm-up run per strategy are excluded from timings."
    Write-Host ""
    $tableRows = foreach ($result in @($report.Results)) {
        $shortWorkload = if ($result.Workload -eq "User profile mutation") { "Profile mutation" } else { "History append" }
        $shortStrategy = if ($result.Strategy -like "4 sequential*") {
            "Sequential (4 tx)"
        }
        elseif ($result.Strategy -like "*sequential appends") {
            "Sequential ($HistoryAppendCount tx)"
        }
        else {
            "Batched (1 tx)"
        }

        [PSCustomObject]@{
            Workload = $shortWorkload
            Strategy = $shortStrategy
            MedianMs = $result.MedianMs
            Reads    = $result.ReadsPerRun
            Writes   = $result.WritesPerRun
            Speedup  = ("{0:N2}x" -f $result.RelativeSpeedup)
        }
    }
    $table = $tableRows |
        Format-Table -AutoSize |
        Out-String
    Write-Host $table
    Write-Host "Speedup compares each batched strategy with its sequential baseline; full p95 and parse counts are available with -OutputFormat Json."
}
