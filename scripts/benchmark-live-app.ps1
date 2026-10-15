<# Benchmarks the real app through read-only endpoints. Never exports response bodies. #>
param(
    [PSCredential]$Credential,
    [ValidateRange(1, 5)][int]$Rounds = 2,
    [ValidateRange(10, 600)][int]$TimeoutSeconds = 180,
    [switch]$SkipLaunch,
    [string]$BaseUrl = "http://localhost:8081/"
)
$ErrorActionPreference = "Stop"
$uri = [Uri]$BaseUrl
if ($uri.Scheme -ne "http" -or $uri.Host -notin @("localhost", "127.0.0.1", "[::1]") -or $uri.AbsolutePath -ne "/" -or $uri.Query -or $uri.UserInfo) {
    throw "Benchmark only supports the local SAPHIR server."
}
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$capture = Join-Path $local ("SAPHIR/diagnostics/benchmark-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmss") + "-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($capture) | Out-Null
$results = New-Object Collections.ArrayList
$token = ""; $restarted = $false
$saved = @{}
foreach ($name in @("SAPHIR_PERFORMANCE_TRACE", "SAPHIR_PERF_TRACE", "SAPHIR_TRACE_LEVEL")) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
function Invoke-BenchmarkRequest {
    param([string]$Path, [string]$Method = "GET", [string]$Body = "", [int]$Round = 0)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $response = $null; $reader = $null; $text = ""; $status = 0; $trace = ""; $category = ""
    try {
        $request = [Net.HttpWebRequest]::Create(([Uri]::new($uri, $Path)))
        $request.Method = $Method; $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $false; $request.Proxy = $null
        if ($token) { $request.Headers["Authorization"] = "Bearer " + $token }
        if ($Body) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentType = "application/json"; $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            if ($null -eq $_.Exception.Response) { $category = [string]$_.Exception.Status }
            else { $response = $_.Exception.Response }
        }
        if ($response) {
            $status = [int]$response.StatusCode
            $trace = [string]$response.Headers["X-SAPHIR-Trace"]
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $text = $reader.ReadToEnd()
        }
    } finally {
        $timer.Stop()
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        if ($trace -notmatch '^[0-9a-f]{32}$') { $trace = "" }
        [void]$results.Add([PSCustomObject]@{ round = $Round; method = $Method; endpoint = $Path; status = $status; durationMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1); responseBytes = [Text.Encoding]::UTF8.GetByteCount($text); backendTraceId = $trace; errorCategory = $category })
        Write-Host ("{0} {1}: {2} ms (HTTP {3})" -f $Method, $Path, [Math]::Round($timer.Elapsed.TotalMilliseconds), $status)
    }
    return [PSCustomObject]@{ status = $status; text = $text }
}
try {
    if (-not $Credential) {
        $username = Read-Host "SAPHIR username"
        $password = Read-Host "SAPHIR password" -AsSecureString
        $Credential = New-Object PSCredential($username, $password)
    }
    if (-not $SkipLaunch) {
        # Lightweight aggregates remain useful even if the optional JSONL writer fails.
        & (Join-Path $PSScriptRoot "start-performance-capture.ps1") -Level summary -NoBrowser
        if (-not $?) { throw "Unable to start SAPHIR for the benchmark." }
        $restarted = $true
    }
    $body = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json -Compress
    try { $login = Invoke-BenchmarkRequest -Path "auth/login" -Method POST -Body $body }
    finally { $body = $null }
    if ($login.status -ne 200) { throw "Sign-in failed. See the HTTP status above; no automatic password retries were attempted." }
    $session = $login.text | ConvertFrom-Json
    $token = [string]$session.token
    $login = $null; $session = $null
    if (-not $token) { throw "Sign-in did not return a session token." }
    foreach ($round in 1..$Rounds) {
        Write-Host ("Round {0}/{1}" -f $round, $Rounds)
        foreach ($path in @("auth/me", "self/bootstrap", "employees/bootstrap?scope=all", "dashboard/bootstrap", "review/bootstrap", "projects/bootstrap?scope=all&includeDetail=false", "sync/status")) {
            # Sequential requests avoid creating artificial request-queue contention.
            $reply = Invoke-BenchmarkRequest -Path $path -Round $round
            $reply = $null
        }
    }
} finally {
    if ($token) {
        # Only the benchmark's own login session is revoked.
        try { $null = Invoke-BenchmarkRequest -Path "auth/logout" -Method POST } catch { Write-Warning "Benchmark session logout could not complete." }
        $token = ""
    }
    $rows = @($results.ToArray())
    $rows | Export-Csv -LiteralPath (Join-Path $capture "requests.csv") -NoTypeInformation -Encoding UTF8
    $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $capture "requests.json") -Encoding UTF8
    $runtime = [string]$env:SAPHIR_RUNTIME_ROOT
    if (-not $runtime) { $runtime = [Environment]::GetEnvironmentVariable(("OVER" + "TIME_RUNTIME_ROOT")) }
    if (-not $runtime) {
        $runtime = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { Join-Path $local "SAPHIR/runtime" } else { Join-Path (Split-Path $PSScriptRoot -Parent) "runtime" }
    }
    $stdout = Join-Path $runtime "logs/app.stdout.log"
    $ids = @{}; foreach ($row in $rows) { if ($row.backendTraceId) { $ids[$row.backendTraceId] = $true } }
    $summaries = New-Object Collections.ArrayList
    if ([IO.File]::Exists($stdout)) {
        foreach ($line in [IO.File]::ReadLines($stdout)) {
            if (-not $line.StartsWith("SAPHIR_PERF ")) { continue }
            try {
                $summary = $line.Substring(12) | ConvertFrom-Json
                if ($ids.ContainsKey([string]$summary.id)) { [void]$summaries.Add($line.Substring(12)) }
            } catch { }
        }
    }
    # Export only sanitized aggregates for these requests, never raw stdout or payloads.
    [IO.File]::WriteAllLines((Join-Path $capture "backend-summary.jsonl"), [string[]]$summaries.ToArray())
    $report = New-Object Collections.Generic.List[string]
    $report.Add("# SAPHIR live benchmark")
    $report.Add("")
    $report.Add("Real data, sequential GET requests. Round 1 is first observed in this sequence, not an isolated cold test. Later endpoints may benefit from earlier requests. Summary tracing has overhead. Timings include response-body transfer, not browser rendering. No business response bodies or credentials are exported.")
    $report.Add("")
    $report.Add("| Round | Request | HTTP | Seconds |")
    $report.Add("|---|---|---:|---:|")
    foreach ($row in $rows) { $report.Add(("| {0} | {1} /{2} | {3} | {4:N2} |" -f $row.round, $row.method, $row.endpoint, $row.status, ($row.durationMs / 1000))) }
    $report.Add("")
    $report.Add(("Matching backend summaries: {0}. HTTP 403 means this account cannot access that section; HTTP 0 means a connection/timeout failure. Non-2xx responses are not successful loads." -f $summaries.Count))
    $report.Add("")
    $report.Add("## Backend work (matching requests only)")
    $report.Add("Function durations below are inclusive and can overlap. They are not CPU measurements; do not add them together.")
    foreach ($line in $summaries) {
        $summary = $line | ConvertFrom-Json
        $report.Add("")
        $report.Add(("### {0} ({1:N2} seconds backend)" -f $summary.name, ($summary.totalMs / 1000)))
        $report.Add(("Cache hits: {0}; misses: {1}; invalidated models: {2}; shared reads: {3}; shared metadata calls: {4}." -f [int]$summary.operations.'cache.readmodel.hit', [int]$summary.operations.'cache.readmodel.miss', [int]$summary.operations.'cache.model.invalidated', [int]$summary.operations.'fs.shared.read', [int]$summary.operations.'fs.shared.metadata'))
        foreach ($function in @($summary.functions.PSObject.Properties | Sort-Object { $_.Value.ms } -Descending | Select-Object -First 5)) {
            $report.Add(("- {0}: {1:N2} seconds, {2} calls" -f $function.Name, ($function.Value.ms / 1000), $function.Value.count))
        }
    }
    [IO.File]::WriteAllLines((Join-Path $capture "report.md"), $report)
    if ($restarted) {
        # Leave the workstation in normal, untraced mode after capturing.
        $env:SAPHIR_PERFORMANCE_TRACE = "0"; $env:SAPHIR_PERF_TRACE = "0"
        $restart = Join-Path $PSScriptRoot "launch-cached-app.ps1"
        if (-not (Test-Path -LiteralPath $restart -PathType Leaf)) { $restart = Join-Path $PSScriptRoot "launch-app.ps1" }
        try { & $restart -Force -NoBrowser } catch { Write-Warning "Normal restart failed. Restart SAPHIR normally to disable tracing." }
    }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    $archive = $capture + ".zip"
    Compress-Archive -Path (Join-Path $capture "*") -DestinationPath $archive
    Write-Host "Finished. Send this file: $archive"
}
