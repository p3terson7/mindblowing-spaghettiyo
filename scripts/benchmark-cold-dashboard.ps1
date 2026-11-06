param(
    [Parameter(Mandatory = $true)][string]$NetworkDataFolder,
    [int[]]$EmployeeCounts = @(32, 100, 300, 500),
    [ValidateRange(3, 20)][int]$Iterations = 5,
    [ValidateSet(1, 2, 4, 8)][int[]]$Concurrency = @(1),
    [int]$CacheCapacity = 0,
    [string]$ApplicationRoot = "",
    [string]$ReportPath = "output/cold-dashboard.json",
    [ValidateSet("disabled", "summary", "detailed")][string]$TraceMode = "summary",
    [string]$TraceDirectory = ""
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
if (-not [IO.Directory]::Exists($NetworkDataFolder)) { throw "Mount the share first; the DATA root is never created by this benchmark." }
foreach ($count in $EmployeeCounts) { if ($count -lt 2 -or $count -gt 1000) { throw "EmployeeCounts must be between 2 and 1000." } }
$run = [Guid]::NewGuid().ToString("N")
$fixtureRoot = Join-Path $NetworkDataFolder "saphir-cold-$run"
$runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) "saphir-cold-runtime-$run"
$runtime = Join-Path $runtimeRoot "runtime"
$source = if ($ApplicationRoot) { [IO.Path]::GetFullPath($ApplicationRoot) } else { Join-Path $repo "app" }
$rows = New-Object Collections.ArrayList
$process = $null
$oldTrace = $env:SAPHIR_PERF_TRACE
$oldPersistentTrace = $env:SAPHIR_PERFORMANCE_TRACE
$oldTraceLevel = $env:SAPHIR_TRACE_LEVEL
$oldTraceDirectory = $env:SAPHIR_TRACE_DIR
$oldConcurrency = $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY
$oldToken = $env:SAPHIR_INSTANCE_TOKEN
$oldSyncMs = $env:SAPHIR_SYNC_STATE_CACHE_MS
$oldCapacity = $env:SAPHIR_READ_MODEL_CACHE_CAPACITY
$controlToken = [Guid]::NewGuid().ToString("N")
$password = "Fixture-$run!"
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-ColdFixture([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 14), $utf8)
}
function Save-ColdReport {
    $report = [PSCustomObject]@{
        schemaVersion = 1; measuredAtUtc = [DateTime]::UtcNow.ToString("o")
        applicationRoot = $source; iterations = $Iterations; cacheCapacity = $CacheCapacity; traceMode = $TraceMode; rows = @($rows.ToArray())
        policy = "Synthetic isolated SMB subfolder; fresh HTTP backend per cold sample. Login/startup excluded from cold request time. All caches start empty except startup/auth naturally populated. Traces include filesystem API attempts, not SMB packets. No OS/SMB cache purge; no competing suite. Memory is endpoint process working set/private/managed, not peak. p95 nearest rank. DTO equality and expected totals checked."
    }
    [IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($ReportPath)) -Parent)) | Out-Null
    Write-ColdFixture ([IO.Path]::GetFullPath($ReportPath)) $report
}
function Invoke-ColdRequest([string]$Method, [string]$Path, [string]$Token = "", $Body = $null) {
    $request = [Net.HttpWebRequest]::Create($baseUri + $Path)
    $request.Proxy = $null; $request.Method = $Method; $request.Timeout = 300000
    if ($Token) { $request.Headers["Authorization"] = "Bearer $Token" }
    if ($null -ne $Body) {
        $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 8 -Compress))
        $request.ContentType = "application/json"; $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { $response = $request.GetResponse() }
    catch [Net.WebException] {
        if ($_.Exception.Response) {
            $errorResponse = $_.Exception.Response
            $errorReader = New-Object IO.StreamReader($errorResponse.GetResponseStream())
            try { $detail = $errorReader.ReadToEnd() } finally { $errorReader.Dispose(); $errorResponse.Dispose() }
            throw "Benchmark HTTP failure in $Method $Path : $detail"
        }
        throw
    }
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $watch.Stop()
        if ([int]$response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode) in $Path" }
        return [PSCustomObject]@{ body = ($raw | ConvertFrom-Json); raw = $raw; clientMs = $watch.Elapsed.TotalMilliseconds; traceId = [string]$response.Headers["X-SAPHIR-Trace"] }
    } finally { $response.Dispose() }
}
function Read-ColdTrace([string]$Id) {
    if (-not $Id) { return $null }
    return @(Get-Content $stdout | Where-Object { $_.StartsWith("SAPHIR_PERF ") } | ForEach-Object { $_.Substring(12) | ConvertFrom-Json } | Where-Object id -eq $Id)[0]
}
function Get-ColdDtoHash($Body) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 16 -Compress)))).Replace("-", "") }
    finally { $sha.Dispose() }
}
try {
    New-Item -ItemType Directory -Path $fixtureRoot, $runtime -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $runtime -Recurse
    $salt = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($password, $salt, 120000)
    try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }
    $env:SAPHIR_PERF_TRACE = if ($TraceMode -eq "disabled") { "0" } else { "1" }
    $env:SAPHIR_PERFORMANCE_TRACE = $env:SAPHIR_PERF_TRACE
    $env:SAPHIR_TRACE_LEVEL = $TraceMode
    $env:SAPHIR_INSTANCE_TOKEN = $controlToken
    $env:SAPHIR_SYNC_STATE_CACHE_MS = "1000"
    if ($CacheCapacity -gt 0) { $env:SAPHIR_READ_MODEL_CACHE_CAPACITY = [string]$CacheCapacity }
    foreach ($count in $EmployeeCounts) {
        $data = Join-Path $fixtureRoot "employees-$count"
        New-Item -ItemType Directory -Path $data | Out-Null
        Copy-Item -Path (Join-Path $repo "tests/fixtures/data-contract/reference-v1/*.json") -Destination $data
        Copy-Item (Join-Path $repo "app/backend/defaults/compensation-grid.v1.json") (Join-Path $data "compensation-grid.json")
        Copy-Item (Join-Path $repo "app/backend/defaults/budget-periods.v2.json") (Join-Path $data "budget-periods.json")
        $users = New-Object Collections.ArrayList
        [void]$users.Add([PSCustomObject]@{ username = "cold-super"; displayName = "Fixture Supervisor"; role = "superAdmin"; disabled = $false; mustChangePassword = $false; passwordSalt = [Convert]::ToBase64String($salt); passwordHash = [Convert]::ToBase64String($hash); passwordIterations = 120000; passwordAlgorithm = "PBKDF2-HMACSHA1" })
        $names = [ordered]@{}
        foreach ($index in 1..$count) {
            $code = "{0:000000000}" -f (710000 + $index)
            $name = "Fixture Employee $index"; $names[$code] = $name
            [void]$users.Add([PSCustomObject]@{ username = $code; employeeCode = $code; displayName = $name; role = "employee"; disabled = $false; timeEntryTypes = @("overtime"); gc179Profile = [PSCustomObject]@{ group = "CR"; subGroup = "04"; level = "01" } })
            Write-ColdFixture (Join-Path $data "$($code)_data.json") @(foreach ($entry in 1..4) {
                [PSCustomObject]@{ entryId = "cold-$index-$entry"; name = $name; date = (Get-Date -Format "yyyy-MM-") + "0$entry"; punchIn = "17:00:00"; punchOut = "18:00:00"; exactPunchIn = "17:00:00"; exactPunchOut = "18:00:00"; overtime = "01:00:00"; status = if ($entry -eq 4) { "pending" } else { "approved" }; entryType = "overtime"; projectCode = "P001"; overtimeCode = "260"; paymentOption = "cash"; reasonCode = ""; workSchedule = "regular" }
            })
        }
        Write-ColdFixture (Join-Path $data "users.json") @($users.ToArray())
        Write-ColdFixture (Join-Path $data "employeeNames.json") ([PSCustomObject]$names)
        Write-ColdFixture (Join-Path $data "history.json") @()
        Write-ColdFixture (Join-Path $data "projects.json") @([PSCustomObject]@{ projectCode = "P001"; projectName = "Fixture Project"; admins = @(); backupAdmins = @(); archived = $false })
        Write-Host "Fixture ready: $count employees"
        foreach ($level in $Concurrency) {
            $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = [string]$level
            $expectedHash = ""
            foreach ($iteration in 1..$Iterations) {
                # Isolated fixture mutations from earlier samples are reset.
                Write-ColdFixture (Join-Path $data "sessions.json") @()
                $firstPath = Join-Path $data "000710001_data.json"
                $first = @([IO.File]::ReadAllText($firstPath) | ConvertFrom-Json)
                $first[0].overtime = "01:00:00"
                Write-ColdFixture $firstPath $first
                $socket = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
                $socket.Start(); $port = ([Net.IPEndPoint]$socket.LocalEndpoint).Port; $socket.Stop()
                $baseUri = "http://localhost:$port"
                [IO.File]::WriteAllText((Join-Path $runtime "app/backend/saphir-config.psd1"), "@{ ListenerPrefix = '$baseUri/'; DataFolderPath = '$($data.Replace("'", "''"))'; EnableDemoSeed = `$false; EnableGc179Import = `$false }", $utf8)
                $stdout = Join-Path $runtimeRoot "stdout-$count-$level-$iteration.log"
                $stderr = Join-Path $runtimeRoot "stderr-$count-$level-$iteration.log"
                $sampleTraceDirectory = if ($TraceDirectory) { Join-Path (Join-Path $TraceDirectory $run) "$TraceMode-$count-$level-$iteration" } else { "" }
                if ($sampleTraceDirectory) { $env:SAPHIR_TRACE_DIR = $sampleTraceDirectory }
                $startupWatch = [Diagnostics.Stopwatch]::StartNew()
                $process = Start-Process (Get-Command pwsh).Source -ArgumentList @("-NoProfile", "-File", (Join-Path $runtime "app/backend/saphir-server.ps1")) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
                $deadline = [DateTime]::UtcNow.AddSeconds(90)
                $ready = $false
                while ([DateTime]::UtcNow -lt $deadline) {
                    if ($process.HasExited) { throw "Backend exited: $([IO.File]::ReadAllText($stderr))" }
                    try { Invoke-WebRequest "$baseUri/" -UseBasicParsing -TimeoutSec 2 | Out-Null; $ready = $true; break } catch { Start-Sleep -Milliseconds 100 }
                }
                if (-not $ready) { throw "Backend did not start." }
                $startupWatch.Stop()
                $login = Invoke-ColdRequest POST /auth/login "" @{ username = "cold-super"; password = $password }
                $token = [string]$login.body.token
                $process.Refresh(); $cpuBeforeColdMs = $process.TotalProcessorTime.TotalMilliseconds
                $cold = Invoke-ColdRequest GET /dashboard/bootstrap $token
                $process.Refresh(); $coldCpuMs = $process.TotalProcessorTime.TotalMilliseconds - $cpuBeforeColdMs
                $coldWorkingSetBytes = $process.WorkingSet64
                $dtoHash = Get-ColdDtoHash $cold.body
                if ($expectedHash -and $dtoHash -ne $expectedHash) { throw "Cold DTO changed across samples for $count/$level." }
                $expectedHash = $dtoHash
                if ($cold.body.trackedEmployees -ne $count -or $cold.body.pendingApprovals -ne $count -or $cold.body.totalOvertime -ne ("{0:00}:00:00" -f ($count * 4))) { throw "Incorrect cold dashboard totals." }
                $warm = Invoke-ColdRequest GET /dashboard/bootstrap $token
                if ((Get-ColdDtoHash $warm.body) -ne $dtoHash) { throw "Warm DTO differs from cold." }
                $warm2 = Invoke-ColdRequest GET /dashboard/bootstrap $token
                # Independent process exercises cache capacity after one change.
                & (Get-Command pwsh).Source -NoProfile -File (Join-Path $repo "tests/lib/CacheCoherenceWorker.ps1") -FixtureFolder $data -Operation modify | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Remote fixture writer failed." }
                Start-Sleep -Milliseconds 1100
                $changed = Invoke-ColdRequest GET /dashboard/bootstrap $token
                if ($changed.body.totalOvertime -ne ("{0:00}:00:00" -f ($count * 4 + 1))) { throw "Remote change was not observed." }
                Invoke-WebRequest "$baseUri/__saphir/control/shutdown" -Method POST -Headers @{ "X-SAPHIR-Control-Token" = $controlToken } -UseBasicParsing | Out-Null
                $gracefulShutdown = $process.WaitForExit(30000)
                if (-not $gracefulShutdown) {
                    Write-Warning "Owned benchmark backend did not exit after shutdown; stopping it after the completed read measurements."
                    Stop-Process -Id $process.Id -Force
                }
                $traceFiles = if ($sampleTraceDirectory -and [IO.Directory]::Exists($sampleTraceDirectory)) { @(Get-ChildItem -LiteralPath $sampleTraceDirectory -Filter "*.jsonl") } else { @() }
                $traceEvents = 0
                foreach ($traceFile in $traceFiles) { foreach ($line in [IO.File]::ReadLines($traceFile.FullName)) { $traceEvents++ } }
                [void]$rows.Add([PSCustomObject]@{ employeeCount = $count; concurrency = $level; iteration = $iteration; dtoHash = $dtoHash; gracefulShutdown = $gracefulShutdown; startupClientMs = $startupWatch.Elapsed.TotalMilliseconds; loginClientMs = $login.clientMs; coldCpuMs = $coldCpuMs; coldWorkingSetBytes = $coldWorkingSetBytes; traceBytes = ($traceFiles | Measure-Object Length -Sum).Sum; traceEventCount = $traceEvents; traceDirectory = $sampleTraceDirectory; coldClientMs = $cold.clientMs; cold = Read-ColdTrace $cold.traceId; warm = Read-ColdTrace $warm.traceId; warm2 = Read-ColdTrace $warm2.traceId; changed = Read-ColdTrace $changed.traceId })
                Save-ColdReport
                Write-Host "Measured cold $count employees / concurrency $level / $iteration of $Iterations : $([Math]::Round($cold.clientMs)) ms"
            }
        }
    }
    Write-Host "Report: $ReportPath"
} catch {
    # The fixture contains no real identities or data. Preserve server errors
    # for diagnosis; do not retain generated credentials/session records.
    $diagnostics = [IO.Path]::GetFullPath($ReportPath + ".diagnostics")
    [IO.Directory]::CreateDirectory($diagnostics) | Out-Null
    foreach ($log in @(Get-ChildItem -LiteralPath $runtimeRoot -Filter "*.log" -ErrorAction SilentlyContinue)) { Copy-Item -LiteralPath $log.FullName -Destination $diagnostics }
    throw
} finally {
    $env:SAPHIR_PERF_TRACE = $oldTrace; $env:SAPHIR_EMPLOYEE_READ_CONCURRENCY = $oldConcurrency; $env:SAPHIR_INSTANCE_TOKEN = $oldToken
    $env:SAPHIR_PERFORMANCE_TRACE = $oldPersistentTrace; $env:SAPHIR_TRACE_LEVEL = $oldTraceLevel; $env:SAPHIR_TRACE_DIR = $oldTraceDirectory
    $env:SAPHIR_SYNC_STATE_CACHE_MS = $oldSyncMs
    $env:SAPHIR_READ_MODEL_CACHE_CAPACITY = $oldCapacity
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    # Only these owned UUID subfolders, never the supplied DATA root.
    if ([IO.Directory]::Exists($fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    if ([IO.Directory]::Exists($runtimeRoot)) { Remove-Item -LiteralPath $runtimeRoot -Recurse -Force }
}
