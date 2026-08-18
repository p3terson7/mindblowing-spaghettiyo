$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}
function New-TestCredential {
    param([Parameter(Mandatory = $true)][string]$Password)
    $salt = New-Object byte[] 16
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($salt) } finally { $random.Dispose() }
    $iterations = 120000
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $iterations)
    try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }
    return [PSCustomObject]@{
        passwordSalt = [Convert]::ToBase64String($salt)
        passwordHash = [Convert]::ToBase64String($hash)
        passwordIterations = $iterations
        passwordAlgorithm = "PBKDF2-HMACSHA1"
    }
}
function Write-TestJson {
    param([string]$Path, $Value, [int]$Depth = 10)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth $Depth), (New-Object Text.UTF8Encoding($false)))
}
function Invoke-TestRequest {
    param([string]$Method, [string]$Uri, [string]$Token = "", $Body = $null, [hashtable]$Headers = @{})
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Proxy = $null
    $request.Timeout = 6000
    $request.ReadWriteTimeout = 6000
    if ($Token) { $request.Headers["Authorization"] = "Bearer $Token" }
    foreach ($name in $Headers.Keys) { $request.Headers[[string]$name] = [string]$Headers[$name] }
    if ($null -ne $Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress))
        $request.ContentType = "application/json; charset=utf-8"
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $null
    try { $response = [Net.HttpWebResponse]$request.GetResponse() }
    catch [Net.WebException] {
        if ($null -eq $_.Exception.Response) { throw }
        $response = [Net.HttpWebResponse]$_.Exception.Response
    }
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $json = $null
        if ($text) { try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { } }
        return [PSCustomObject]@{ StatusCode = [int]$response.StatusCode; Body = $text; Json = $json; Headers = $response.Headers }
    }
    finally { $response.Dispose() }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("saphir-analytics-http-{0}" -f [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path $tempRoot "runtime"
$dataRoot = Join-Path $tempRoot "data"
$serverProcess = $null
$baseUri = ""
$previousToken = [string]$env:SAPHIR_INSTANCE_TOKEN
$instanceToken = [Guid]::NewGuid().ToString("N")

try {
    New-Item -ItemType Directory -Path $runtimeRoot, $dataRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "app") -Destination $runtimeRoot -Recurse -Force
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop()
    $baseUri = "http://localhost:$port"
    $safeDataRoot = $dataRoot.Replace("'", "''")
    $config = "@{`n ListenerPrefix = `"http://localhost:$port/`"`n DataFolderPath = '$safeDataRoot'`n EnableDemoSeed = `$false`n EnableGc179Import = `$false`n}`n"
    [IO.File]::WriteAllText((Join-Path $runtimeRoot "app/backend/saphir-config.psd1"), $config, (New-Object Text.UTF8Encoding($false)))

    $adminPassword = "Analytics-Admin-Password-123!"
    $employeePassword = "Analytics-Employee-Password-123!"
    $adminCredential = New-TestCredential $adminPassword
    $employeeCredential = New-TestCredential $employeePassword
    Write-TestJson (Join-Path $dataRoot "projects.json") @([PSCustomObject]@{ projectCode = "P1"; projectName = "Projet Érable"; sector = "Opérations"; admins = @(); backupAdmins = @(); archived = $false })
    Write-TestJson (Join-Path $dataRoot "users.json") @(
        [PSCustomObject]@{ username = "analytics-admin"; displayName = "Analytics Admin"; role = "superAdmin"; employeeCode = $null; disabled = $false; mustChangePassword = $false; passwordSalt = $adminCredential.passwordSalt; passwordHash = $adminCredential.passwordHash; passwordIterations = $adminCredential.passwordIterations; passwordAlgorithm = $adminCredential.passwordAlgorithm },
        [PSCustomObject]@{ username = "000000001"; displayName = "Élodie Test"; role = "employee"; employeeCode = "000000001"; disabled = $false; mustChangePassword = $false; passwordSalt = $employeeCredential.passwordSalt; passwordHash = $employeeCredential.passwordHash; passwordIterations = $employeeCredential.passwordIterations; passwordAlgorithm = $employeeCredential.passwordAlgorithm }
    )
    Write-TestJson (Join-Path $dataRoot "sessions.json") ([object[]]@())
    Write-TestJson (Join-Path $dataRoot "history.json") ([object[]]@())
    Write-TestJson (Join-Path $dataRoot "000000001_data.json") @([PSCustomObject]@{ entryId = "report-entry-1"; entryType = "overtime"; date = "2026-07-15"; punchIn = "17:00:00"; punchOut = "19:00:00"; overtime = "02:00:00"; status = "approved"; projectCode = "P1"; overtimeCode = "260"; paymentOption = "cash"; reasonCode = "D"; workComment = "must not leave SAPHIR"; message = "must not leave SAPHIR" })

    $stdout = Join-Path $tempRoot "stdout.log"
    $stderr = Join-Path $tempRoot "stderr.log"
    $env:SAPHIR_INSTANCE_TOKEN = $instanceToken
    $serverProcess = Start-Process -FilePath (Get-Command pwsh -ErrorAction Stop).Source -ArgumentList @("-NoProfile", "-File", (Join-Path $runtimeRoot "app/backend/saphir-server.ps1")) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $ready = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ($serverProcess.HasExited) { break }
        try {
            $probe = Invoke-TestRequest "GET" "$baseUri/"
            if ($probe.StatusCode -eq 200 -and [string]$probe.Headers["X-SAPHIR-Instance"] -eq $instanceToken) { $ready = $true; break }
        }
        catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        $errorText = if (Test-Path $stderr) { [IO.File]::ReadAllText($stderr) } else { "" }
        throw "Analytics integration server did not start. $errorText"
    }

    $anonymous = Invoke-TestRequest "GET" "$baseUri/stats/analytics-export?locale=fr"
    Assert-Equal 401 $anonymous.StatusCode "Anonymous analytics export access must be rejected."
    $employeeLogin = Invoke-TestRequest "POST" "$baseUri/auth/login" "" @{ username = "000000001"; password = $employeePassword }
    Assert-Equal 200 $employeeLogin.StatusCode "Employee test login failed."
    $employeeAttempt = Invoke-TestRequest "GET" "$baseUri/stats/analytics-export?locale=fr" ([string]$employeeLogin.Json.token)
    Assert-Equal 403 $employeeAttempt.StatusCode "Employees must not export the manager analytics report."

    $adminLogin = Invoke-TestRequest "POST" "$baseUri/auth/login" "" @{ username = "analytics-admin"; password = $adminPassword }
    Assert-Equal 200 $adminLogin.StatusCode "Admin test login failed."
    $adminToken = [string]$adminLogin.Json.token
    $download = Invoke-TestRequest "GET" "$baseUri/stats/analytics-export?startDate=2026-07-01&endDate=2026-07-31&locale=fr" $adminToken
    Assert-Equal 200 $download.StatusCode "Authenticated analytics export failed."
    Assert-True ([string]$download.Headers["Content-Type"] -like "text/html*") "Analytics download has the wrong content type."
    Assert-True ([string]$download.Headers["Content-Disposition"] -like "*saphir-analytics-2026-07-01_2026-07-31-fr.html*") "Analytics download filename is incorrect."
    Assert-True $download.Body.StartsWith("<!doctype html>") "Analytics download is not a standalone HTML document."
    Assert-True (-not $download.Body.Contains("must not leave SAPHIR")) "Comments or supervisor notes leaked into the report."
    $payloadMatch = [regex]::Match($download.Body, '<script id="reportData" type="application/octet-stream">([^<]+)</script>')
    Assert-True $payloadMatch.Success "The downloaded report payload is missing."
    $payload = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadMatch.Groups[1].Value))) | ConvertFrom-Json
    Assert-Equal 7200 $payload.summary.approvedSeconds "The HTTP report calculated the wrong approved duration."
    Assert-Equal "Élodie Test" $payload.employees[0].displayName "UTF-8 employee names did not survive the HTTP download."
    Assert-True (-not ($payload.facts[0].PSObject.Properties.Name -contains "employeeCode")) "HRMIS/SIGRH leaked into the report facts."
    Assert-Equal "" $payload.meta.defaultProject "The department-wide HTTP report must not acquire a default project."

    $projectDownload = Invoke-TestRequest "GET" "$baseUri/stats/analytics-export?startDate=2026-07-01&endDate=2026-07-31&locale=fr&projectCode=P1" $adminToken
    Assert-Equal 200 $projectDownload.StatusCode "Authenticated project analytics export failed."
    Assert-True ([string]$projectDownload.Headers["Content-Disposition"] -like "*saphir-analytics-P1-2026-07-01_2026-07-31-fr.html*") "Project analytics download filename is incorrect."
    $projectPayloadMatch = [regex]::Match($projectDownload.Body, '<script id="reportData" type="application/octet-stream">([^<]+)</script>')
    Assert-True $projectPayloadMatch.Success "The project analytics payload is missing."
    $projectPayload = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($projectPayloadMatch.Groups[1].Value))) | ConvertFrom-Json
    Assert-Equal "P1" $projectPayload.meta.defaultProject "The HTTP project report did not initialize its project filter."

    $invalid = Invoke-TestRequest "GET" "$baseUri/stats/analytics-export?startDate=bad&locale=fr" $adminToken
    Assert-Equal 400 $invalid.StatusCode "Invalid analytics dates must return HTTP 400."
    $invalidProject = Invoke-TestRequest "GET" "$baseUri/stats/analytics-export?projectCode=..%2FP1&locale=fr" $adminToken
    Assert-Equal 400 $invalidProject.StatusCode "Invalid analytics project codes must return HTTP 400."
    $missingProject = Invoke-TestRequest "GET" "$baseUri/stats/analytics-export?projectCode=UNKNOWN&locale=fr" $adminToken
    Assert-Equal 404 $missingProject.StatusCode "Unknown analytics projects must return HTTP 404 to a super administrator."
    Write-Host "Analytics HTML export HTTP integration passed."
}
finally {
    $env:SAPHIR_INSTANCE_TOKEN = $previousToken
    if ($serverProcess -and -not $serverProcess.HasExited -and $baseUri) {
        try { Invoke-TestRequest "POST" "$baseUri/__saphir/control/shutdown" "" $null @{ "X-SAPHIR-Control-Token" = $instanceToken } | Out-Null } catch { }
        try { $serverProcess.WaitForExit(3000) | Out-Null } catch { }
    }
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
