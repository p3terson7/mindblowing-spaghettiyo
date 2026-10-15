param([string]$FixtureParent = "", [string]$ApplicationRoot = "", [ValidateRange(1, 20)][int]$Iterations = 3, [string]$ReportPath = "output/view-loading.json", [string[]]$Views = @("employees/bootstrap?scope=active", "review/bootstrap", "dashboard/bootstrap", "projects/bootstrap?scope=all&includeDetail=false"))
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
if (-not $FixtureParent) { $FixtureParent = [IO.Path]::GetTempPath() }
if (-not [IO.Directory]::Exists($FixtureParent)) { throw "Mount the fixture parent first." }
$owned = Join-Path $FixtureParent ("saphir-view-benchmark-" + [Guid]::NewGuid().ToString("N"))
$runtime = Join-Path ([IO.Path]::GetTempPath()) ("saphir-view-runtime-" + [Guid]::NewGuid().ToString("N"))
$source = if ($ApplicationRoot) { $ApplicationRoot } else { Join-Path $repo "app" }
$rows = New-Object Collections.ArrayList
$process = $null; $saved = @{}
foreach ($key in @("SAPHIR_PERF_TRACE", "SAPHIR_PERFORMANCE_TRACE", "SAPHIR_TRACE_LEVEL", "SAPHIR_TRACE_DIR")) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
function Invoke-ViewBenchmarkHttp([string]$Path, [string]$Token = "", $Body = $null) {
    $request = [Net.HttpWebRequest]::Create($base + $Path); $request.Proxy = $null; $request.Timeout = 180000
    if ($Token) { $request.Headers["Authorization"] = "Bearer " + $Token }
    if ($null -ne $Body) {
        $request.Method = "POST"; $request.ContentType = "application/json"
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress)); $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream(); try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew(); $response = $request.GetResponse()
    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $watch.Stop()
        return @{ body = ($text | ConvertFrom-Json); bytes = [Text.Encoding]::UTF8.GetByteCount($text); ms = $watch.Elapsed.TotalMilliseconds; id = [string]$response.Headers["X-SAPHIR-Trace"] }
    } finally { $response.Dispose() }
}
function Read-ViewBenchmarkLog {
    if (-not [IO.File]::Exists($stdout)) { return "" }
    $stream = [IO.FileStream]::new($stdout, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Get-ViewBenchmarkTrace([string]$TraceId) {
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $lines = (Read-ViewBenchmarkLog) -split '\r?\n'
        foreach ($line in $lines) {
            if (-not $line.StartsWith("SAPHIR_PERF ")) { continue }
            try { $trace = $line.Substring(12) | ConvertFrom-Json; if ($trace.id -eq $TraceId) { return $trace } } catch { }
        }
        Start-Sleep -Milliseconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Missing matching backend summary; refusing incomplete benchmark."
}
try {
    . (Join-Path $repo "tests/lib/CacheCoherenceFixture.ps1") -FixtureFolder $owned -Create -EmployeeCount 40
    foreach ($file in @(Get-ChildItem $owned -Filter '*_data.json')) {
        $entries = @([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json)
        if ($entries.Count -eq 0) { continue }
        $expanded = @(foreach ($index in 1..4) {
            $entry = $entries[0].PSObject.Copy(); $entry.entryId += "-$index"
            $entry.status = if ($index -eq 4) { "pending" } else { "approved" }; $entry
        })
        Write-CoherenceFixtureJson $file.FullName $expanded
    }
    Write-CoherenceFixtureJson $historyFile @(foreach ($index in 1..167) { [PSCustomObject]@{ timestamp = "2026-10-01 12:00:00"; action = if ($index % 2) { "add" } else { "update" }; employeeCode = "000710001"; author = "Audit Supervisor"; message = "Fixture action $index" } })
    $password = "Fixture-$([Guid]::NewGuid().ToString('N'))!"
    $salt = New-Object byte[] 16; $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.Dispose()
    $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($password, $salt, 120000)
    $hash = $derive.GetBytes(32); $derive.Dispose()
    $users = @(Read-JsonArrayFile $usersFile)
    foreach ($pair in @(@("passwordSalt", [Convert]::ToBase64String($salt)), @("passwordHash", [Convert]::ToBase64String($hash)), @("passwordIterations", 120000), @("passwordAlgorithm", "PBKDF2-HMACSHA1"))) { $users[0] | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force }
    Write-CoherenceFixtureJson $usersFile $users
    [IO.Directory]::CreateDirectory($runtime) | Out-Null
    Copy-Item $source (Join-Path $runtime "app") -Recurse
    $env:SAPHIR_PERF_TRACE = "1"; $env:SAPHIR_PERFORMANCE_TRACE = "1"; $env:SAPHIR_TRACE_LEVEL = "summary"
    foreach ($view in $Views) {
        foreach ($iteration in 1..$Iterations) {
            Write-CoherenceFixtureJson $sessionsFile @()
            $socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $socket.Start(); $port = $socket.LocalEndpoint.Port; $socket.Stop()
            $base = "http://localhost:$port/"
            [IO.File]::WriteAllText((Join-Path $runtime "app/backend/saphir-config.psd1"), "@{ ListenerPrefix = '$base'; DataFolderPath = '$($owned.Replace("'", "''"))'; EnableDemoSeed = `$false; EnableGc179Import = `$false }")
            $stdout = Join-Path $runtime "stdout.log"; $stderr = Join-Path $runtime "stderr.log"
            $env:SAPHIR_TRACE_DIR = Join-Path $runtime "traces"
            $startup = [Diagnostics.Stopwatch]::StartNew()
            $process = Start-Process (Get-Process -Id $PID).Path -ArgumentList @("-NoProfile", "-File", (Join-Path $runtime "app/backend/saphir-server.ps1")) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Read-ViewBenchmarkLog).Contains("SAPHIR Server running")) {
                if ($process.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw "Fixture server startup failed." }; Start-Sleep -Milliseconds 100
            }
            $startup.Stop()
            $login = Invoke-ViewBenchmarkHttp "auth/login" "" @{ username = "audit-super"; password = $password }
            foreach ($phase in @("first", "repeat")) {
                $result = Invoke-ViewBenchmarkHttp $view $login.body.token
                $trace = Get-ViewBenchmarkTrace $result.id
                $sections = @{}
                if ($result.body -is [PSCustomObject]) { foreach ($property in $result.body.PSObject.Properties) { $sections[$property.Name] = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $property.Value -Depth 14 -Compress)) } }
                [void]$rows.Add([PSCustomObject]@{ view = $view; iteration = $iteration; phase = $phase; requests = 1; payloadBytes = $result.bytes; clientMs = [Math]::Round($result.ms, 2); backendMs = $trace.totalMs; startupMs = [Math]::Round($startup.Elapsed.TotalMilliseconds, 2); operations = $trace.operations; sectionBytes = $sections })
            }
            Stop-Process -Id $process.Id -Force; $process.WaitForExit(); $process.Dispose(); $process = $null
        }
    }
    $report = @{ schemaVersion = 1; measuredAtUtc = [DateTime]::UtcNow.ToString("o"); powerShellVersion = [string]$PSVersionTable.PSVersion; employeeCount = 40; entryCount = 160; historyCount = 167; policy = "Fresh backend for each view/sample, login excluded from view time; first/repeat sequential; summary instrumentation; no OS cache purge. Shared operation counts are application FileStore calls, not SMB packets. FixtureParent determines local versus actual SMB latency."; rows = @($rows.ToArray()) }
    $path = [IO.Path]::GetFullPath($ReportPath); [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    $report | ConvertTo-Json -Depth 12 | Set-Content $path -Encoding UTF8
    Write-Host "View benchmark saved: $path"
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    if ([IO.Directory]::Exists($owned)) { Remove-Item -LiteralPath $owned -Recurse -Force }
    if ([IO.Directory]::Exists($runtime)) { Remove-Item -LiteralPath $runtime -Recurse -Force }
}
