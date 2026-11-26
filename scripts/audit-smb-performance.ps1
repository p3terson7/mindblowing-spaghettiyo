param(
    [Parameter(Mandatory = $true)][string]$NetworkDataFolder,
    [ValidateRange(2, 100)][int]$EmployeeCount = 32,
    [string]$ReportPath = "",
    [string]$ApplicationRoot = "",
    [ValidateRange(0, 100)][int]$CoherenceIterations = 0
)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not [IO.Directory]::Exists($NetworkDataFolder)) { throw "Mount/connect the test share first. No DATA folder will be created automatically." }
$runId = [Guid]::NewGuid().ToString("N")
$fixtureRoot = Join-Path $NetworkDataFolder ("saphir-audit-{0}" -f $runId)
$localRoot = Join-Path ([IO.Path]::GetTempPath()) ("saphir-audit-runtime-{0}" -f $runId)
$runtime = Join-Path $localRoot "runtime"
$stdout = Join-Path $localRoot "stdout.log"
$stderr = Join-Path $localRoot "stderr.log"
if (-not $ReportPath) { $ReportPath = Join-Path $repoRoot "output/smb-audit.json" }
$records = New-Object System.Collections.ArrayList
$process = $null
$writerProcess = $null
$oldTrace = $env:SAPHIR_PERF_TRACE
$oldToken = $env:SAPHIR_INSTANCE_TOKEN
$oldSyncMs = $env:SAPHIR_SYNC_STATE_CACHE_MS
$instanceToken = [Guid]::NewGuid().ToString("N")
function Write-Fixture([string]$Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $fixtureRoot $Name), (ConvertTo-Json -InputObject $Value -Depth 14), (New-Object Text.UTF8Encoding($false)))
}
function Invoke-AuditRequest([string]$Scenario, [string]$Method, [string]$Path, [string]$Token = "", $Body = $null, [string]$ServerUri = "") {
    if (-not $ServerUri) { $ServerUri = $baseUri }
    $request = [Net.HttpWebRequest]::Create($ServerUri + $Path)
    $request.Proxy = $null; $request.Method = $Method; $request.Timeout = 60000
    if ($Token) { $request.Headers["Authorization"] = "Bearer $Token" }
    if ($null -ne $Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 8 -Compress))
        $request.ContentType = "application/json"; $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    try { $response = $request.GetResponse() } catch [Net.WebException] { if (-not $_.Exception.Response) { throw }; $response = $_.Exception.Response }
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $bodyText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $watch.Stop()
        [void]$records.Add([PSCustomObject]@{ scenario = $Scenario; method = $Method; path = $Path; status = [int]$response.StatusCode; clientMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3); traceId = [string]$response.Headers["X-SAPHIR-Trace"] })
        if ([int]$response.StatusCode -ne 200) { throw "Audit scenario '$Scenario' failed with HTTP $([int]$response.StatusCode): $bodyText" }
        return ($bodyText | ConvertFrom-Json)
    } finally { $response.Dispose() }
}
try {
    New-Item -ItemType Directory -Path $fixtureRoot, $runtime -Force | Out-Null
    $sourceApp = if ($ApplicationRoot) { $ApplicationRoot } else { Join-Path $repoRoot "app" }
    Copy-Item -LiteralPath $sourceApp -Destination $runtime -Recurse
    Copy-Item -Path (Join-Path $repoRoot "tests/fixtures/data-contract/reference-v1/*.json") -Destination $fixtureRoot
    Copy-Item -LiteralPath (Join-Path $repoRoot "app/backend/defaults/compensation-grid.v1.json") -Destination (Join-Path $fixtureRoot "compensation-grid.json")
    Copy-Item -LiteralPath (Join-Path $repoRoot "app/backend/defaults/budget-periods.v2.json") -Destination (Join-Path $fixtureRoot "budget-periods.json")
    $credentialPassword = "Audit-$runId!"
    $salt = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($credentialPassword, $salt, 120000)
    try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }
    $users = @([PSCustomObject]@{ username = "audit-super"; displayName = "Audit Supervisor"; role = "superAdmin"; disabled = $false; mustChangePassword = $false; passwordSalt = [Convert]::ToBase64String($salt); passwordHash = [Convert]::ToBase64String($hash); passwordIterations = 120000; passwordAlgorithm = "PBKDF2-HMACSHA1" })
    $names = [ordered]@{}
    for ($index = 1; $index -le $EmployeeCount; $index++) {
        $code = "{0:000000000}" -f (710000 + $index)
        $name = "Audit Employee $index"
        $names[$code] = $name
        $users += [PSCustomObject]@{ username = $code; employeeCode = $code; displayName = $name; role = "employee"; disabled = $false; mustChangePassword = $false; passwordSalt = [Convert]::ToBase64String($salt); passwordHash = [Convert]::ToBase64String($hash); passwordIterations = 120000; passwordAlgorithm = "PBKDF2-HMACSHA1"; timeEntryTypes = @("overtime"); gc179Profile = [PSCustomObject]@{ group = "CR"; subGroup = "04"; level = "01"; compressedWorkWeek = $false } }
        Write-Fixture "$($code)_data.json" @(for ($entryIndex = 1; $entryIndex -le 4; $entryIndex++) {
            [PSCustomObject]@{ entryId = "audit-$index-$entryIndex"; name = $name; date = "2026-10-0$entryIndex"; punchIn = "17:00:00"; punchOut = "18:00:00"; exactPunchIn = "17:00:00"; exactPunchOut = "18:00:00"; overtime = "01:00:00"; status = if ($entryIndex -eq 4) { "pending" } else { "approved" }; entryType = "overtime"; projectCode = "P001"; overtimeCode = "260"; paymentOption = "cash"; reasonCode = ""; workSchedule = "regular" }
        })
    }
    Write-Fixture "users.json" $users
    Write-Fixture "employeeNames.json" ([PSCustomObject]$names)
    Write-Fixture "sessions.json" @()
    Write-Fixture "history.json" @()
    Write-Fixture "projects.json" @([PSCustomObject]@{ projectCode = "P001"; projectName = "Audit Project"; admins = @(); backupAdmins = @(); archived = $false })
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop()
    $baseUri = "http://localhost:$port"
    $configText = "@{ ListenerPrefix = '$baseUri/'; DataFolderPath = '$($fixtureRoot.Replace("'", "''"))'; EnableDemoSeed = `$false; EnableGc179Import = `$false }"
    [IO.File]::WriteAllText((Join-Path $runtime "app/backend/saphir-config.psd1"), $configText)
    $env:SAPHIR_PERF_TRACE = "1"; $env:SAPHIR_INSTANCE_TOKEN = $instanceToken
    if ($CoherenceIterations -gt 0) { $env:SAPHIR_SYNC_STATE_CACHE_MS = "1000" }
    $process = Start-Process (Get-Command pwsh).Source -ArgumentList @("-NoProfile", "-File", (Join-Path $runtime "app/backend/saphir-server.ps1")) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Audit server stopped: $([IO.File]::ReadAllText($stderr))" }
        try { Invoke-WebRequest "$baseUri/" -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 100 }
    }
    $adminLogin = Invoke-AuditRequest "1.admin-login" "POST" "/auth/login" "" @{ username = "audit-super"; password = $credentialPassword }
    $adminToken = [string]$adminLogin.token
    if ($CoherenceIterations -gt 0) {
        $writerRuntime = Join-Path $localRoot "writer"
        New-Item -ItemType Directory $writerRuntime | Out-Null
        Copy-Item -LiteralPath (Join-Path $runtime "app") -Destination $writerRuntime -Recurse
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $listener.Start(); $writerPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop()
        $writerUri = "http://localhost:$writerPort"
        [IO.File]::WriteAllText((Join-Path $writerRuntime "app/backend/saphir-config.psd1"), $configText.Replace($baseUri, $writerUri))
        $writerProcess = Start-Process (Get-Command pwsh).Source -ArgumentList @("-NoProfile", "-File", (Join-Path $writerRuntime "app/backend/saphir-server.ps1")) -RedirectStandardOutput (Join-Path $localRoot "writer-stdout.log") -RedirectStandardError (Join-Path $localRoot "writer-stderr.log") -PassThru
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline) {
            if ($writerProcess.HasExited) { throw "Writer server exited." }
            try { Invoke-WebRequest "$writerUri/" -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 100 }
        }
        $writerLogin = Invoke-AuditRequest "writer.login" "POST" "/auth/login" "" @{ username = "audit-super"; password = $credentialPassword } $writerUri
        $writerToken = [string]$writerLogin.token
        Start-Sleep -Milliseconds 1100
        Invoke-AuditRequest "coherence.prime" "GET" "/dashboard/bootstrap" $adminToken | Out-Null
        Invoke-AuditRequest "coherence.warmup" "GET" "/dashboard/bootstrap" $adminToken | Out-Null
        foreach ($scenario in @("A.warm", "B.one-employee", "C.three-employees", "D.bug-report", "E.permission")) {
            for ($iteration = 1; $iteration -le $CoherenceIterations; $iteration++) {
                switch ($scenario) {
                    "B.one-employee" {
                        Invoke-AuditRequest "writer.employee" "PUT" "/employee/message/000710001" $writerToken @{ entryId = "audit-1-1"; message = "Audit $iteration" } $writerUri | Out-Null
                    }
                    "C.three-employees" {
                        foreach ($index in 1..3) {
                            $code = "{0:000000000}" -f (710000 + $index)
                            Invoke-AuditRequest "writer.employee" "PUT" "/employee/message/$code" $writerToken @{ entryId = "audit-$index-1"; message = "Batch $iteration" } $writerUri | Out-Null
                        }
                    }
                    "D.bug-report" {
                        Invoke-AuditRequest "writer.bug" "POST" "/bug-reports" $writerToken @{ title = "Audit issue $iteration"; description = "Synthetic performance benchmark"; category = "other" } $writerUri | Out-Null
                    }
                    "E.permission" {
                        Invoke-AuditRequest "writer.permission" "PUT" "/employees/000710001" $writerToken @{ name = "Audit Employee 1"; role = if ($iteration % 2 -eq 1) { "admin" } else { "employee" } } $writerUri | Out-Null
                    }
                }
                if ($scenario -ne "A.warm") { Start-Sleep -Milliseconds 1100 }
                Invoke-AuditRequest "$scenario.$iteration" "GET" "/dashboard/bootstrap" $adminToken | Out-Null
                Write-Host "Measured $scenario $iteration/$CoherenceIterations"
            }
        }
        Invoke-WebRequest "$writerUri/__saphir/control/shutdown" -Method POST -Headers @{ "X-SAPHIR-Control-Token" = $instanceToken } -UseBasicParsing | Out-Null
        if (-not $writerProcess.WaitForExit(10000)) { throw "Writer did not stop gracefully." }
    }
    else {
    Invoke-AuditRequest "2.dashboard-cold" "GET" "/dashboard/bootstrap" $adminToken | Out-Null
    Invoke-AuditRequest "2.dashboard-warm" "GET" "/dashboard/bootstrap" $adminToken | Out-Null
    $employeeLogin = Invoke-AuditRequest "1.employee-login" "POST" "/auth/login" "" @{ username = "000710001"; password = $credentialPassword }
    $employeeToken = [string]$employeeLogin.token
    Invoke-AuditRequest "3.self-cold" "GET" "/self/bootstrap" $employeeToken | Out-Null
    Invoke-AuditRequest "3.self-warm" "GET" "/self/bootstrap" $employeeToken | Out-Null
    Invoke-AuditRequest "poll.sync-warm" "GET" "/sync/status" $employeeToken | Out-Null
    Invoke-AuditRequest "4.employee-punch-in" "POST" "/self/punch" $employeeToken @{ type = "in"; projectCode = "P001"; overtimeCode = "260"; paymentOption = "cash"; reasonCode = "" } | Out-Null
    Invoke-AuditRequest "2.dashboard-after-one-change" "GET" "/dashboard/bootstrap" $adminToken | Out-Null
    Invoke-AuditRequest "5.approve" "POST" "/employee/approval/000710001" $adminToken @{ entryId = "audit-1-4"; status = "approved"; message = "Audit approval" } | Out-Null
    Invoke-AuditRequest "5.reject" "POST" "/employee/approval/000710002" $adminToken @{ entryId = "audit-2-4"; status = "rejected"; message = "Audit rejection" } | Out-Null
    Invoke-AuditRequest "personnel.cold" "GET" "/employees/bootstrap" $adminToken | Out-Null
    Invoke-AuditRequest "projects.cold" "GET" "/projects/bootstrap?startDate=2026-10-01&endDate=2026-10-31" $adminToken | Out-Null
    Start-Sleep -Seconds 11
    Invoke-AuditRequest "poll.sync-expired" "GET" "/sync/status" $employeeToken | Out-Null
    Start-Sleep -Seconds 20
    Invoke-AuditRequest "2.dashboard-metadata-expired" "GET" "/dashboard/bootstrap" $adminToken | Out-Null
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue("Bearer", $adminToken)
    $pairWatch = [Diagnostics.Stopwatch]::StartNew()
    $slowTask = $client.GetAsync("$baseUri/employees/bootstrap")
    Start-Sleep -Milliseconds 5
    $fastWatch = [Diagnostics.Stopwatch]::StartNew()
    $fastTask = $client.GetAsync("$baseUri/sync/status")
    $slowResponse = $slowTask.GetAwaiter().GetResult(); $slowMs = $pairWatch.Elapsed.TotalMilliseconds
    $fastResponse = $fastTask.GetAwaiter().GetResult(); $fastMs = $fastWatch.Elapsed.TotalMilliseconds
    foreach ($pair in @(@("queue.personnel", $slowResponse, $slowMs), @("queue.sync", $fastResponse, $fastMs))) {
        [void]$records.Add([PSCustomObject]@{ scenario = $pair[0]; method = "GET"; path = if ($pair[0] -eq "queue.sync") { "/sync/status" } else { "/employees/bootstrap" }; status = [int]$pair[1].StatusCode; clientMs = [Math]::Round($pair[2], 3); traceId = @($pair[1].Headers.GetValues("X-SAPHIR-Trace"))[0] })
        $pair[1].Dispose()
    }
    $client.Dispose()
    }
    Invoke-WebRequest "$baseUri/__saphir/control/shutdown" -Method POST -Headers @{ "X-SAPHIR-Control-Token" = $instanceToken } -UseBasicParsing | Out-Null
    if (-not $process.WaitForExit(10000)) { throw "Audit server did not stop gracefully." }
    $traces = @(Get-Content $stdout | Where-Object { $_.StartsWith("SAPHIR_PERF ") } | ForEach-Object { $_.Substring(12) | ConvertFrom-Json })
    if ($writerProcess) {
        $traces += @(Get-Content (Join-Path $localRoot "writer-stdout.log") | Where-Object { $_.StartsWith("SAPHIR_PERF ") } | ForEach-Object { $_.Substring(12) | ConvertFrom-Json })
    }
    $rows = @($records | ForEach-Object {
        $record = $_; $trace = @($traces | Where-Object id -eq $record.traceId)[0]
        [PSCustomObject]@{ scenario = $record.scenario; method = $record.method; path = $record.path; status = $record.status; clientMs = $record.clientMs; trace = $trace }
    })
    $summary = @(foreach ($group in @($rows | Where-Object scenario -match '^[A-E]\.' | Group-Object { $_.scenario -replace '\.\d+$', '' })) {
        $times = @($group.Group.trace.totalMs | Sort-Object)
        $median = if ($times.Count % 2 -eq 1) { $times[[int][Math]::Floor($times.Count / 2)] } else { ($times[$times.Count / 2 - 1] + $times[$times.Count / 2]) / 2 }
        $p95 = $times[[Math]::Ceiling($times.Count * 0.95) - 1]
        [PSCustomObject]@{
            scenario = $group.Name; samples = $times.Count; medianMs = $median; p95Ms = $p95
            metadata = @($group.Group.trace.operations.'fs.shared.metadata'); reads = @($group.Group.trace.operations.'fs.shared.read')
            hits = @($group.Group.trace.operations.'cache.readmodel.hit'); misses = @($group.Group.trace.operations.'cache.readmodel.miss')
            invalidatedModels = @($group.Group.trace.operations.'cache.model.invalidated')
            contributions = @($group.Group | ForEach-Object { if ($null -ne $_.trace.operations.'cache.employee-contribution.recomputed') { [int]$_.trace.operations.'cache.employee-contribution.recomputed' } else { [int]$_.trace.functions.'Get-CachedEmployeeEntriesForFile'.count } })
            fullReconstructions = @($group.Group | ForEach-Object { $count = if ($null -ne $_.trace.operations.'cache.employee-contribution.recomputed') { [int]$_.trace.operations.'cache.employee-contribution.recomputed' } else { [int]$_.trace.functions.'Get-CachedEmployeeEntriesForFile'.count }; [int]($count -ge $EmployeeCount) })
        }
    })
    $report = [PSCustomObject]@{ measuredAtUtc = (Get-Date).ToUniversalTime().ToString("o"); employeeCount = $EmployeeCount; entryCount = $EmployeeCount * 4; coherenceIterations = $CoherenceIterations; policy = "Synthetic isolated subfolder; existing DATA never edited. Filesystem API attempts, not SMB packets. Tracing overhead included. Coherence mode: two actual HTTP backends, 1s sync TTL, wait 1.1s before reads; timed read includes detection. Baseline contribution count uses Get-CachedEmployeeEntriesForFile calls. Full reconstruction means all employee contributions recomputed, not concatenation/sorting of cached contributions."; startup = @($traces | Where-Object name -eq "startup")[0]; requests = $rows; summary = $summary }
    [IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($ReportPath)) -Parent)) | Out-Null
    [IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $report -Depth 15))
    $rows | Select-Object scenario, clientMs, @{ n = "serverMs"; e = { $_.trace.totalMs } }, @{ n = "metadata"; e = { $_.trace.operations.'fs.shared.metadata' } }, @{ n = "reads"; e = { $_.trace.operations.'fs.shared.read' } } | Format-Table -AutoSize
    Write-Host "Audit report: $ReportPath"
} finally {
    $env:SAPHIR_PERF_TRACE = $oldTrace; $env:SAPHIR_INSTANCE_TOKEN = $oldToken; $env:SAPHIR_SYNC_STATE_CACHE_MS = $oldSyncMs
    if ($writerProcess -and -not $writerProcess.HasExited) { Stop-Process -Id $writerProcess.Id -Force -ErrorAction SilentlyContinue }
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    # These exact UUID directories were created by this run, never the supplied
    # data root or any employee's existing records.
    if ([IO.Directory]::Exists($fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    if ([IO.Directory]::Exists($localRoot)) { Remove-Item -LiteralPath $localRoot -Recurse -Force }
}
