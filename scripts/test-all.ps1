<#
.SYNOPSIS
Runs the SAPHIR test suite in the same order as the Windows CI workflow.

.DESCRIPTION
By default, the runner performs the PowerShell 5.1 compatibility audit first,
then recursively discovers every other test-*.ps1 file under tests/powershell,
and finally every test-*.js file under tests/frontend. Test files are sorted by
name inside each category.

The optional performance benchmark uses only synthetic fixtures in the OS
temporary directory. It is intentionally excluded from the default test run.

.EXAMPLE
./scripts/test-all.ps1

.EXAMPLE
./scripts/test-all.ps1 -Category PowerShell -Filter "*sync*", "*approval*"

.EXAMPLE
./scripts/test-all.ps1 -IncludeBenchmark -ReportPath ./output/test-baseline.json
#>
param(
    [ValidateSet("All", "Compatibility", "PowerShell", "JavaScript")]
    [string[]]$Category = @("All"),

    [Alias("Name", "Include")]
    [string[]]$Filter = @("*"),

    [string[]]$Exclude = @(),

    [switch]$List,

    [switch]$FailFast,

    [switch]$IncludeBenchmark,

    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $scriptDir -ChildPath "..")).Path
$testsRoot = Join-Path -Path $repoRoot -ChildPath "tests"
$powerShellTestsRoot = Join-Path -Path $testsRoot -ChildPath "powershell"
$javaScriptTestsRoot = Join-Path -Path $testsRoot -ChildPath "frontend"
$compatibilityTestName = "test-powershell51-compat.ps1"
$benchmarkName = "benchmark-performance.ps1"
$originalLocation = (Get-Location).Path
$startedAtUtc = (Get-Date).ToUniversalTime()
$suiteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$results = @()
$benchmarkReport = $null

function Test-CategorySelected {
    param([Parameter(Mandatory = $true)][string]$Value)

    return (($Category -contains "All") -or ($Category -contains $Value))
}

function Test-NameSelected {
    param([Parameter(Mandatory = $true)][string]$Value)

    $included = $false
    foreach ($pattern in @($Filter)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and $Value -like $pattern) {
            $included = $true
            break
        }
    }

    if (-not $included) {
        return $false
    }

    foreach ($pattern in @($Exclude)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and $Value -like $pattern) {
            return $false
        }
    }

    return $true
}

function New-TestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CategoryName,
        [Parameter(Mandatory = $true)][string]$Runtime,
        [hashtable]$Parameters = @{}
    )

    return [PSCustomObject]@{
        Name      = $Name
        Path      = $Path
        Category  = $CategoryName
        Runtime   = $Runtime
        Parameters = $Parameters
    }
}

function New-TestResult {
    param(
        [Parameter(Mandatory = $true)]$TestCase,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][double]$DurationMilliseconds,
        [string]$ErrorMessage = ""
    )

    return [PSCustomObject]@{
        Name                 = [string]$TestCase.Name
        Category             = [string]$TestCase.Category
        Runtime              = [string]$TestCase.Runtime
        Status               = $Status
        DurationMilliseconds = [Math]::Round($DurationMilliseconds, 2)
        Error                = $ErrorMessage
    }
}

function Get-SelectedTests {
    $selected = @()

    foreach ($requiredTestDirectory in @($powerShellTestsRoot, $javaScriptTestsRoot)) {
        if (-not (Test-Path -LiteralPath $requiredTestDirectory -PathType Container)) {
            throw "Required test directory was not found: $requiredTestDirectory"
        }
    }

    if (Test-CategorySelected -Value "Compatibility") {
        $compatibilityPath = Join-Path -Path $powerShellTestsRoot -ChildPath $compatibilityTestName
        if (-not (Test-Path -LiteralPath $compatibilityPath -PathType Leaf)) {
            throw "Required compatibility test was not found: $compatibilityPath"
        }

        if (Test-NameSelected -Value $compatibilityTestName) {
            $selected += New-TestCase `
                -Name $compatibilityTestName `
                -Path $compatibilityPath `
                -CategoryName "Compatibility" `
                -Runtime "PowerShell" `
                -Parameters @{ FailOnIssues = $true }
        }
    }

    if (Test-CategorySelected -Value "PowerShell") {
        $powerShellTests = Get-ChildItem -LiteralPath $powerShellTestsRoot -Filter "test-*.ps1" -File -Recurse |
            Where-Object { $_.Name -ne $compatibilityTestName } |
            Sort-Object FullName

        foreach ($test in @($powerShellTests)) {
            if (Test-NameSelected -Value $test.Name) {
                $selected += New-TestCase `
                    -Name $test.Name `
                    -Path $test.FullName `
                    -CategoryName "PowerShell" `
                    -Runtime "PowerShell"
            }
        }
    }

    if (Test-CategorySelected -Value "JavaScript") {
        $javaScriptTests = Get-ChildItem -LiteralPath $javaScriptTestsRoot -Filter "test-*.js" -File -Recurse |
            Sort-Object FullName
        foreach ($test in @($javaScriptTests)) {
            if (Test-NameSelected -Value $test.Name) {
                $selected += New-TestCase `
                    -Name $test.Name `
                    -Path $test.FullName `
                    -CategoryName "JavaScript" `
                    -Runtime "Node.js"
            }
        }
    }

    if ($IncludeBenchmark) {
        $benchmarkPath = Join-Path -Path $scriptDir -ChildPath $benchmarkName
        if (-not (Test-Path -LiteralPath $benchmarkPath -PathType Leaf)) {
            throw "Requested benchmark was not found: $benchmarkPath"
        }

        $selected += New-TestCase `
            -Name $benchmarkName `
            -Path $benchmarkPath `
            -CategoryName "Benchmark" `
            -Runtime "PowerShell" `
            -Parameters @{ OutputFormat = "Json" }
    }

    $duplicateNames = @($selected | Group-Object Name | Where-Object { $_.Count -gt 1 })
    if ($duplicateNames.Count -gt 0) {
        $duplicateSummary = (($duplicateNames | ForEach-Object { $_.Name }) -join ", ")
        throw "Test names must be unique across the selected suite: $duplicateSummary"
    }

    return @($selected)
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory = $true)]$TestCase,
        $NodeCommand
    )

    Write-Host ("Running [{0}] {1}" -f $TestCase.Category, $TestCase.Name)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Set-Location -LiteralPath $repoRoot
        $testParameters = $TestCase.Parameters

        if ($TestCase.Runtime -eq "Node.js") {
            if ($null -eq $NodeCommand) {
                throw "Node.js is required to run JavaScript tests, but the 'node' command was not found."
            }

            & $NodeCommand.Source $TestCase.Path | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "$($TestCase.Name) failed with exit code $LASTEXITCODE."
            }
        }
        elseif ($TestCase.Category -eq "Benchmark") {
            $benchmarkJson = (& $TestCase.Path @testParameters | Out-String)
            $script:benchmarkReport = $benchmarkJson | ConvertFrom-Json
            Write-Host ("Benchmark captured: {0} workload result(s)." -f @($script:benchmarkReport.Results).Count)
        }
        else {
            & $TestCase.Path @testParameters | Out-Host
        }

        $stopwatch.Stop()
        Write-Host ("Passed {0} ({1:N2} s)" -f $TestCase.Name, $stopwatch.Elapsed.TotalSeconds)
        return New-TestResult -TestCase $TestCase -Status "Passed" -DurationMilliseconds $stopwatch.Elapsed.TotalMilliseconds
    }
    catch {
        $stopwatch.Stop()
        $message = [string]$_.Exception.Message
        Write-Host ("FAILED {0} ({1:N2} s): {2}" -f $TestCase.Name, $stopwatch.Elapsed.TotalSeconds, $message) -ForegroundColor Red
        return New-TestResult -TestCase $TestCase -Status "Failed" -DurationMilliseconds $stopwatch.Elapsed.TotalMilliseconds -ErrorMessage $message
    }
    finally {
        Set-Location -LiteralPath $repoRoot
    }
}

function Write-JsonReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $absolutePath = $Path
    if (-not [System.IO.Path]::IsPathRooted($absolutePath)) {
        $absolutePath = Join-Path -Path $originalLocation -ChildPath $absolutePath
    }
    $absolutePath = [System.IO.Path]::GetFullPath($absolutePath)

    $parentDirectory = [System.IO.Path]::GetDirectoryName($absolutePath)
    if (-not [string]::IsNullOrWhiteSpace($parentDirectory) -and -not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 9
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($absolutePath, $json, $utf8NoBom)
    Write-Host "JSON report written to $absolutePath"
}

$selectedTests = @(Get-SelectedTests)

if ($List) {
    Write-Host ("Selected {0} item(s):" -f $selectedTests.Count)
    foreach ($test in $selectedTests) {
        Write-Host ("- [{0}] {1}" -f $test.Category, $test.Name)
    }

    $suiteStopwatch.Stop()
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $listReport = [PSCustomObject]@{
            SchemaVersion = 1
            Mode          = "List"
            GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            Repository    = $repoRoot
            SelectedCount = $selectedTests.Count
            Selected      = @($selectedTests | ForEach-Object {
                [PSCustomObject]@{
                    Name     = $_.Name
                    Category = $_.Category
                    Runtime  = $_.Runtime
                }
            })
        }
        Write-JsonReport -Path $ReportPath -Value $listReport
    }

    return
}

if ($selectedTests.Count -eq 0) {
    throw "No tests matched the requested categories and name filters. Use -List to inspect the selection."
}

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
$stoppedEarly = $false

try {
    Set-Location -LiteralPath $repoRoot

    foreach ($test in $selectedTests) {
        $result = Invoke-TestCase -TestCase $test -NodeCommand $nodeCommand
        $results += $result

        if ($result.Status -eq "Failed" -and $FailFast) {
            $stoppedEarly = $true
            break
        }
    }
}
finally {
    Set-Location -LiteralPath $originalLocation
    $suiteStopwatch.Stop()
}

$passedCount = @($results | Where-Object { $_.Status -eq "Passed" }).Count
$failedResults = @($results | Where-Object { $_.Status -eq "Failed" })
$failedCount = $failedResults.Count
$notRunCount = $selectedTests.Count - $results.Count

Write-Host ""
Write-Host "Test suite summary"
Write-Host ("Selected : {0}" -f $selectedTests.Count)
Write-Host ("Passed   : {0}" -f $passedCount)
Write-Host ("Failed   : {0}" -f $failedCount)
Write-Host ("Not run  : {0}" -f $notRunCount)
Write-Host ("Duration : {0:N2} s" -f $suiteStopwatch.Elapsed.TotalSeconds)

if ($failedCount -gt 0) {
    Write-Host "Failed tests:" -ForegroundColor Red
    foreach ($failure in $failedResults) {
        Write-Host ("- {0}: {1}" -f $failure.Name, $failure.Error) -ForegroundColor Red
    }
}

$completedAtUtc = (Get-Date).ToUniversalTime()
$runReport = [PSCustomObject]@{
    SchemaVersion      = 1
    Mode               = "Run"
    StartedAtUtc       = $startedAtUtc.ToString("o")
    CompletedAtUtc     = $completedAtUtc.ToString("o")
    DurationMilliseconds = [Math]::Round($suiteStopwatch.Elapsed.TotalMilliseconds, 2)
    Repository         = $repoRoot
    PowerShell         = $PSVersionTable.PSVersion.ToString()
    Edition            = [string]$PSVersionTable.PSEdition
    OperatingSystem    = [Environment]::OSVersion.VersionString
    Selection          = [PSCustomObject]@{
        Categories       = @($Category)
        Filter           = @($Filter)
        Exclude          = @($Exclude)
        IncludeBenchmark = [bool]$IncludeBenchmark
        FailFast         = [bool]$FailFast
    }
    Summary            = [PSCustomObject]@{
        Selected     = $selectedTests.Count
        Passed       = $passedCount
        Failed       = $failedCount
        NotRun       = $notRunCount
        StoppedEarly = $stoppedEarly
    }
    Results            = @($results)
    Benchmark          = $benchmarkReport
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    Write-JsonReport -Path $ReportPath -Value $runReport
}

if ($failedCount -gt 0) {
    throw "$failedCount test(s) failed."
}

if ($notRunCount -gt 0) {
    throw "$notRunCount selected test(s) were not run."
}
