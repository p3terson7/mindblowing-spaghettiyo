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
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function New-TestPasswordCredential {
    param([Parameter(Mandatory = $true)][string]$Password)

    $salt = New-Object byte[] 16
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($salt)
    }
    finally {
        $random.Dispose()
    }

    $iterations = 120000
    $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $iterations)
    try {
        $hash = $deriveBytes.GetBytes(32)
    }
    finally {
        $deriveBytes.Dispose()
    }

    return [PSCustomObject]@{
        passwordSalt       = [Convert]::ToBase64String($salt)
        passwordHash       = [Convert]::ToBase64String($hash)
        passwordIterations = $iterations
        passwordAlgorithm  = "PBKDF2-HMACSHA1"
    }
}

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 10
    )

    $json = ConvertTo-Json -InputObject $Value -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-TestHttpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Token = "",
        $Body = $null,
        [hashtable]$Headers = @{},
        [int]$TimeoutMs = 5000
    )

    $webRequest = [System.Net.HttpWebRequest]::Create($Uri)
    $webRequest.Method = $Method
    $webRequest.Proxy = $null
    $webRequest.Timeout = $TimeoutMs
    $webRequest.ReadWriteTimeout = $TimeoutMs
    $webRequest.Accept = "application/json"
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $webRequest.Headers["Authorization"] = "Bearer $Token"
    }
    foreach ($headerName in $Headers.Keys) {
        $webRequest.Headers[[string]$headerName] = [string]$Headers[$headerName]
    }

    if ($null -ne $Body) {
        $bodyJson = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($bodyJson)
        $webRequest.ContentType = "application/json; charset=utf-8"
        $webRequest.ContentLength = $bodyBytes.Length
        $requestStream = $webRequest.GetRequestStream()
        try {
            $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
        }
        finally {
            $requestStream.Dispose()
        }
    }

    $webResponse = $null
    try {
        $webResponse = [System.Net.HttpWebResponse]$webRequest.GetResponse()
    }
    catch [System.Net.WebException] {
        if ($null -eq $_.Exception.Response) {
            throw
        }
        $webResponse = [System.Net.HttpWebResponse]$_.Exception.Response
    }

    try {
        $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
        try {
            $responseBody = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $parsedBody = $null
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            try {
                $parsedBody = $responseBody | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                # Some frontend readiness responses are not JSON.
            }
        }

        return [PSCustomObject]@{
            StatusCode = [int]$webResponse.StatusCode
            Body       = $responseBody
            Json       = $parsedBody
            Headers    = $webResponse.Headers
        }
    }
    finally {
        $webResponse.Dispose()
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $scriptRoot -ChildPath "../lib/TestPowerShellRuntime.ps1")
$tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("saphir-http-integration-{0}" -f ([Guid]::NewGuid().ToString("N")))
$runtimeRoot = Join-Path -Path $tempRoot -ChildPath "runtime"
$dataRoot = Join-Path -Path $tempRoot -ChildPath "data"
$serverProcess = $null
$previousInstanceToken = [string]$env:SAPHIR_INSTANCE_TOKEN
$instanceToken = [Guid]::NewGuid().ToString("N")

try {
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app") -Destination $runtimeRoot -Recurse -Force
    $repositoryDataFixture = Join-Path -Path $repoRoot -ChildPath "tests/fixtures/data-contract/reference-v1"
    Assert-True -Condition (Test-Path -LiteralPath $repositoryDataFixture -PathType Container) -Message "The tracked DATA contract fixture is missing."
    Copy-Item -Path (Join-Path -Path $repositoryDataFixture -ChildPath "*") -Destination $dataRoot -Recurse -Force

    $portListener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $portListener.Start()
    $port = ([Net.IPEndPoint]$portListener.LocalEndpoint).Port
    $portListener.Stop()
    $baseUri = "http://localhost:$port"

    $safeDataRoot = $dataRoot.Replace("'", "''")
    $configText = @"
@{
    ListenerPrefix = "http://localhost:$port/"
    DataFolderPath = '$safeDataRoot'
    EnableDemoSeed = `$false
    EnableGc179Import = `$false
}
"@
    $configPath = Join-Path -Path $runtimeRoot -ChildPath "app/backend/saphir-config.psd1"
    [System.IO.File]::WriteAllText($configPath, $configText, (New-Object System.Text.UTF8Encoding($false)))

    $adminPassword = "Integration-Test-Password-123!"
    $adminCredential = New-TestPasswordCredential -Password $adminPassword
    $employeeCode = "000321928"
    $employeeCredential = New-TestPasswordCredential -Password "Fixture-Employee-Password-123!"
    $dataFile = Join-Path -Path $dataRoot -ChildPath ("{0}_data.json" -f $employeeCode)
    $legacyEntryText = [IO.File]::ReadAllText($dataFile)
    Assert-True -Condition $legacyEntryText.TrimStart().StartsWith("{") -Message "The DATA contract fixture no longer reproduces singleton-object storage."
    $legacyEntry = $legacyEntryText | ConvertFrom-Json -ErrorAction Stop
    $entryId = [string]$legacyEntry.entryId
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($entryId)) -Message "The fixture singleton entry does not have a stable ID."
    $legacyEntry | Add-Member -NotePropertyName "futureField" -NotePropertyValue "must-survive" -Force
    Write-TestJson -Path $dataFile -Value $legacyEntry

    $usersPath = Join-Path -Path $dataRoot -ChildPath "users.json"
    $users = @([IO.File]::ReadAllText($usersPath) | ConvertFrom-Json)
    $users += @(
        [PSCustomObject]@{
            username           = "integration-admin"
            displayName        = "Integration Admin"
            role               = "superAdmin"
            employeeCode       = $null
            disabled           = $false
            mustChangePassword = $false
            createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
            passwordSalt       = $adminCredential.passwordSalt
            passwordHash       = $adminCredential.passwordHash
            passwordIterations = $adminCredential.passwordIterations
            passwordAlgorithm  = $adminCredential.passwordAlgorithm
        },
        [PSCustomObject]@{
            username           = $employeeCode
            displayName        = "Legacy Fixture Employee"
            role               = "employee"
            employeeCode       = $employeeCode
            disabled           = $false
            mustChangePassword = $true
            createdAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
            passwordSalt       = $employeeCredential.passwordSalt
            passwordHash       = $employeeCredential.passwordHash
            passwordIterations = $employeeCredential.passwordIterations
            passwordAlgorithm  = $employeeCredential.passwordAlgorithm
        }
    )
    Write-TestJson -Path $usersPath -Value $users
    Write-TestJson -Path (Join-Path -Path $dataRoot -ChildPath "sessions.json") -Value ([object[]]@())

    $serverPath = Join-Path -Path $runtimeRoot -ChildPath "app/backend/saphir-server.ps1"
    $stdoutPath = Join-Path -Path $tempRoot -ChildPath "server.stdout.log"
    $stderrPath = Join-Path -Path $tempRoot -ChildPath "server.stderr.log"
    $env:SAPHIR_INSTANCE_TOKEN = $instanceToken
    $powerShellPath = Get-TestPowerShellExecutable
    Assert-TestPowerShellExecutableMatchesCurrentEdition -Path $powerShellPath -Description "Admin integration server"
    $serverProcess = Start-Process -FilePath $powerShellPath `
        -ArgumentList @("-NoProfile", "-File", $serverPath) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    $ready = $false
    $lastStartupError = ""
    $startupDeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $startupDeadline) {
        if ($serverProcess.HasExited) {
            $lastStartupError = "Server exited with code $($serverProcess.ExitCode)."
            break
        }
        try {
            $readyResponse = Invoke-TestHttpRequest -Method "GET" -Uri "$baseUri/"
            if ($readyResponse.StatusCode -eq 200 -and
                [string]$readyResponse.Headers["X-SAPHIR-Instance"] -eq $instanceToken) {
                $ready = $true
                break
            }
        }
        catch {
            $lastStartupError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        $stderrText = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath) } else { "" }
        throw "Integration server did not become ready. $lastStartupError $stderrText"
    }

    $login = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/auth/login" -Body @{
        username = "integration-admin"
        password = $adminPassword
    }
    Assert-Equal -Expected 200 -Actual $login.StatusCode -Message "Login failed."
    $token = [string]$login.Json.token
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($token)) -Message "Login did not return a bearer token."

    $employeeResponse = Invoke-TestHttpRequest -Method "GET" -Uri "$baseUri/employee/$employeeCode" -Token $token
    Assert-Equal -Expected 200 -Actual $employeeResponse.StatusCode -Message "The one-entry employee endpoint failed."
    Assert-True -Condition $employeeResponse.Body.TrimStart().StartsWith("[") -Message "A one-entry API response must remain a JSON array."
    Assert-Equal -Expected $entryId -Actual (@($employeeResponse.Json)[0].entryId) -Message "The employee endpoint returned the wrong entry."

    $manualAdd = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/employee/add/$employeeCode" -Token $token -Body @{
        date          = "2026-07-18"
        punchIn       = "16:00"
        punchOut      = "17:00"
        projectCode   = [string]$legacyEntry.projectCode
        overtimeCode  = "260"
        paymentOption = "leave"
        reasonCode    = "D"
    }
    Assert-Equal -Expected 200 -Actual $manualAdd.StatusCode -Message "Manually adding an entry beside a legacy singleton failed."
    $savedText = [IO.File]::ReadAllText($dataFile)
    Assert-True -Condition $savedText.TrimStart().StartsWith("[") -Message "Manual addition did not normalize singleton storage to an array."
    $savedEntries = @($savedText | ConvertFrom-Json)
    Assert-Equal -Expected 2 -Actual $savedEntries.Count -Message "Manual addition beside a singleton did not preserve both entries."
    Assert-Equal -Expected $entryId -Actual ([string]$savedEntries[0].entryId) -Message "Manual addition replaced the original singleton entry."
    Assert-Equal -Expected "must-survive" -Actual ([string]$savedEntries[0].futureField) -Message "Manual addition stripped an unknown field from the original entry."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$savedEntries[1].entryId)) -Message "The manually added entry did not receive a stable ID."

    $staleMutation = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/employee/approval/$employeeCode" -Token $token -Body @{
        entryId = "missing-entry-id"
        date    = [string]$legacyEntry.date
        punchIn = [string]$legacyEntry.punchIn
        status  = "approved"
        message = ""
    }
    Assert-Equal -Expected 404 -Actual $staleMutation.StatusCode -Message "A missing stable ID must not fall back to another entry's date/time."

    $approval = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/employee/approval/$employeeCode" -Token $token -Body @{
        entryId = $entryId
        status  = "approved"
        message = ""
    }
    Assert-Equal -Expected 200 -Actual $approval.StatusCode -Message "Approving the legacy singleton entry failed."

    $savedText = [IO.File]::ReadAllText($dataFile)
    Assert-True -Condition $savedText.TrimStart().StartsWith("[") -Message "The first successful write must normalize legacy singleton storage to an array."
    $savedEntries = @($savedText | ConvertFrom-Json)
    Assert-Equal -Expected 2 -Actual $savedEntries.Count -Message "The approval changed the entry count."
    Assert-Equal -Expected "approved" -Actual $savedEntries[0].status -Message "The approval was not persisted."
    Assert-Equal -Expected "must-survive" -Actual $savedEntries[0].futureField -Message "The approval stripped an unknown entry field."

    $rejection = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/employee/approval/$employeeCode" -Token $token -Body @{
        entryId = $entryId
        status  = "rejected"
        message = "Integration rejection"
    }
    Assert-Equal -Expected 200 -Actual $rejection.StatusCode -Message "Rejecting the one-entry employee record failed."
    $savedEntries = @([IO.File]::ReadAllText($dataFile) | ConvertFrom-Json)
    Assert-Equal -Expected "rejected" -Actual $savedEntries[0].status -Message "The rejection was not persisted."
    Assert-Equal -Expected "Integration rejection" -Actual $savedEntries[0].message -Message "The rejection message was not persisted."

    $schemaPath = Join-Path -Path $dataRoot -ChildPath "data-schema.json"
    Assert-True -Condition (Test-Path -LiteralPath $schemaPath -PathType Leaf) -Message "The server lost the fixture's DATA schema contract."

    Write-Host "Admin server HTTP integration passed: real login and singleton read/manual-add/approve/reject wiring are correct."
}
finally {
    $env:SAPHIR_INSTANCE_TOKEN = $previousInstanceToken
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        try {
            Invoke-TestHttpRequest `
                -Method "POST" `
                -Uri "$baseUri/__saphir/control/shutdown" `
                -Headers @{ "X-SAPHIR-Control-Token" = $instanceToken } `
                -TimeoutMs 3000 | Out-Null
            $serverProcess.WaitForExit(3000) | Out-Null
        }
        catch {
            # The process is still scoped to this temporary test runtime.
        }
    }
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
