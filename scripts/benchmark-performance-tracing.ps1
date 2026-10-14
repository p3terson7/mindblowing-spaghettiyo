param(
    [Parameter(Mandatory = $true)][string]$NetworkDataFolder,
    [ValidateRange(3, 20)][int]$Iterations = 3,
    [ValidateRange(2, 1000)][int]$EmployeeCount = 40,
    [string]$OutputBase = "output/performance-tracing-overhead"
)
$ErrorActionPreference = "Stop"
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$traces = Join-Path $local ("SAPHIR/diagnostics/overhead-" + [Guid]::NewGuid().ToString("N"))
$modes = @{}
foreach ($mode in @("disabled", "summary", "detailed")) {
    $path = [IO.Path]::GetFullPath($OutputBase + "-" + $mode + ".json")
    & (Join-Path $PSScriptRoot "benchmark-cold-dashboard.ps1") -NetworkDataFolder $NetworkDataFolder -EmployeeCounts @($EmployeeCount) -Iterations $Iterations -Concurrency @(8) -TraceMode $mode -TraceDirectory $traces -ReportPath $path
    $modes[$mode] = [IO.File]::ReadAllText($path) | ConvertFrom-Json
}
function Get-OverheadMedian { param([object[]]$Values) $sorted = @($Values | Sort-Object); return [double]$sorted[[int][Math]::Floor($sorted.Count / 2)] }
$baseline = Get-OverheadMedian @($modes.disabled.rows | ForEach-Object coldClientMs)
$hashes = @($modes.Values | ForEach-Object { $_.rows | ForEach-Object dtoHash } | Sort-Object -Unique)
if ($hashes.Count -ne 1) { throw "Tracing modes changed dashboard DTOs." }
$rows = @(foreach ($mode in @("disabled", "summary", "detailed")) {
    $samples = @($modes[$mode].rows)
    $cold = Get-OverheadMedian @($samples | ForEach-Object coldClientMs)
    [PSCustomObject]@{
        mode = $mode; samples = $samples.Count; coldMedianMs = $cold; relativeColdPercent = (($cold / $baseline) - 1) * 100
        startupMedianMs = Get-OverheadMedian @($samples | ForEach-Object startupClientMs)
        loginMedianMs = Get-OverheadMedian @($samples | ForEach-Object loginClientMs)
        coldCpuMedianMs = Get-OverheadMedian @($samples | ForEach-Object coldCpuMs)
        coldWorkingSetMedianMiB = (Get-OverheadMedian @($samples | ForEach-Object coldWorkingSetBytes)) / 1048576
        traceFileMedianBytes = Get-OverheadMedian @($samples | ForEach-Object traceBytes)
        traceMedianEvents = Get-OverheadMedian @($samples | ForEach-Object traceEventCount)
    }
})
$report = @{ employeeCount = $EmployeeCount; workerLimit = 8; dtoParity = $true; rows = $rows; traces = $traces; caveats = @("Backend HTTP benchmark, not a browser/launcher timing.", "Same synthetic workload; three modes run sequentially, without OS/SMB cache purges.", "Cold CPU is endpoint process CPU delta including diagnostic writer activity; memory is an endpoint working-set sample, not retained heap or peak memory.", "Trace bytes/events cover complete process startup/login/cold/warm/remote-change/shutdown, not only the cold request.", "Detailed tracing can materially perturb timings; compare it with disabled and summary captures on the corporate workstation.") }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputBase + ".json"), (ConvertTo-Json -InputObject $report -Depth 8), (New-Object Text.UTF8Encoding($false)))
$markdown = @("# SAPHIR tracing overhead", "", "40-employee default synthetic workload; actual employee count: $EmployeeCount. All DTOs matched. No application optimization is implied.", "", "| Mode | Cold median ms | Change | CPU median ms | Working set MiB | Trace bytes | Events |", "|---|---:|---:|---:|---:|---:|---:|")
foreach ($row in $rows) { $markdown += "| $($row.mode) | $([Math]::Round($row.coldMedianMs, 1)) | $([Math]::Round($row.relativeColdPercent, 1))% | $([Math]::Round($row.coldCpuMedianMs, 1)) | $([Math]::Round($row.coldWorkingSetMedianMiB, 1)) | $($row.traceFileMedianBytes) | $($row.traceMedianEvents) |" }
$markdown += @("", $report.caveats)
[IO.File]::WriteAllLines([IO.Path]::GetFullPath($OutputBase + ".md"), [string[]]$markdown, (New-Object Text.UTF8Encoding($false)))
Write-Host "Overhead report: $OutputBase.md"
