$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$benchmarkPath = Join-Path -Path $repoRoot -ChildPath "scripts/benchmark-performance.ps1"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$rawReport = & $benchmarkPath `
    -UserCount 20 `
    -HistoryRecordCount 20 `
    -HistoryAppendCount 3 `
    -Iterations 3 `
    -OutputFormat Json
$stopwatch.Stop()

$reportText = (@($rawReport) -join [Environment]::NewLine)
$report = $reportText | ConvertFrom-Json -ErrorAction Stop

Assert-Equal -Expected 4 -Actual @($report.Results).Count -Message "The performance baseline must keep all four comparison scenarios."
Assert-True -Condition ([string]$report.DataPolicy -like "*unique OS temporary directory*") -Message "The benchmark must state that it uses an isolated temporary directory."
Assert-True -Condition ($reportText.IndexOf($repoRoot, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -Message "The benchmark report must not expose or depend on the repository DATA path."

$resultsByKey = @{}
foreach ($result in @($report.Results)) {
    $key = "{0}|{1}" -f [string]$result.Workload, [string]$result.Strategy
    $resultsByKey[$key] = $result
    Assert-True -Condition ([double]$result.MedianMs -ge 0) -Message "Scenario '$key' did not report a valid median duration."
    Assert-True -Condition ([double]$result.P95Ms -ge 0) -Message "Scenario '$key' did not report a valid p95 duration."
    Assert-Equal -Expected 3 -Actual ([int]$result.Samples) -Message "Scenario '$key' did not preserve the requested measurement count."
}

$sequentialProfile = $resultsByKey["User profile mutation|4 sequential transactions"]
$batchedProfile = $resultsByKey["User profile mutation|1 batched transaction"]
$sequentialHistory = $resultsByKey["History append|3 sequential appends"]
$batchedHistory = $resultsByKey["History append|1 batched append"]

Assert-True -Condition ($null -ne $sequentialProfile) -Message "The sequential profile baseline is missing."
Assert-True -Condition ($null -ne $batchedProfile) -Message "The batched profile baseline is missing."
Assert-True -Condition ($null -ne $sequentialHistory) -Message "The sequential history baseline is missing."
Assert-True -Condition ($null -ne $batchedHistory) -Message "The batched history baseline is missing."

Assert-Equal -Expected 4 -Actual ([int]$sequentialProfile.ReadsPerRun) -Message "Sequential profile reads are no longer measured correctly."
Assert-Equal -Expected 4 -Actual ([int]$sequentialProfile.WritesPerRun) -Message "Sequential profile writes are no longer measured correctly."
Assert-Equal -Expected 1 -Actual ([int]$batchedProfile.ReadsPerRun) -Message "Batched profile reads are no longer measured correctly."
Assert-Equal -Expected 1 -Actual ([int]$batchedProfile.WritesPerRun) -Message "Batched profile writes are no longer measured correctly."
Assert-Equal -Expected 3 -Actual ([int]$sequentialHistory.ReadsPerRun) -Message "Sequential history reads are no longer measured correctly."
Assert-Equal -Expected 3 -Actual ([int]$sequentialHistory.WritesPerRun) -Message "Sequential history writes are no longer measured correctly."
Assert-Equal -Expected 1 -Actual ([int]$batchedHistory.ReadsPerRun) -Message "Batched history reads are no longer measured correctly."
Assert-Equal -Expected 1 -Actual ([int]$batchedHistory.WritesPerRun) -Message "Batched history writes are no longer measured correctly."

Write-Host ("Performance baseline contract passed in {0:N0} ms: durations plus read/write counters remain available and isolated." -f $stopwatch.Elapsed.TotalMilliseconds)
