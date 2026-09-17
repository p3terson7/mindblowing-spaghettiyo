$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', got '{2}'." -f $Message, $Expected, $Actual)
    }
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
        passwordSalt       = [Convert]::ToBase64String($salt)
        passwordHash       = [Convert]::ToBase64String($hash)
        passwordIterations = $iterations
        passwordAlgorithm  = "PBKDF2-HMACSHA1"
    }
}

function Write-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)

    $json = ConvertTo-Json -InputObject $Value -Depth 16
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-TestRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Token = "",
        $Body = $null,
        [hashtable]$Headers = @{}
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Proxy = $null
    $request.Timeout = 6000
    $request.ReadWriteTimeout = 6000
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $request.Headers["Authorization"] = "Bearer $Token"
    }
    foreach ($headerName in $Headers.Keys) {
        $request.Headers[[string]$headerName] = [string]$Headers[$headerName]
    }
    if ($null -ne $Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 16 -Compress))
        $request.ContentType = "application/json; charset=utf-8"
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }

    $response = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
    }
    catch [System.Net.WebException] {
        if ($null -eq $_.Exception.Response) { throw }
        $response = [System.Net.HttpWebResponse]$_.Exception.Response
    }

    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $json = $null
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { }
        }
        return [PSCustomObject]@{
            StatusCode = [int]$response.StatusCode
            Body       = $text
            Json       = $json
            Headers    = $response.Headers
        }
    }
    finally {
        $response.Dispose()
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-compensation-http-{0}" -f [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path -Path $tempRoot -ChildPath "runtime"
$dataRoot = Join-Path -Path $tempRoot -ChildPath "data"
$serverProcess = $null
$baseUri = ""
$previousInstanceToken = [string]$env:SAPHIR_INSTANCE_TOKEN
$instanceToken = [Guid]::NewGuid().ToString("N")

try {
    New-Item -ItemType Directory -Path $runtimeRoot, $dataRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app") -Destination $runtimeRoot -Recurse -Force

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $baseUri = "http://localhost:$port"

    $safeDataRoot = $dataRoot.Replace("'", "''")
    $config = "@{`n ListenerPrefix = `"http://localhost:$port/`"`n DataFolderPath = '$safeDataRoot'`n EnableDemoSeed = `$false`n EnableGc179Import = `$false`n}`n"
    [System.IO.File]::WriteAllText((Join-Path -Path $runtimeRoot -ChildPath "app/backend/saphir-config.psd1"), $config, (New-Object System.Text.UTF8Encoding($false)))

    $superPassword = "Compensation-Super-Password-123!"
    $adminPassword = "Compensation-Admin-Password-123!"
    $employeePassword = "Compensation-Employee-Password-123!"
    $superCredential = New-TestCredential -Password $superPassword
    $adminCredential = New-TestCredential -Password $adminPassword
    $employeeCredential = New-TestCredential -Password $employeePassword
    Write-TestJson -Path (Join-Path -Path $dataRoot -ChildPath "users.json") -Value @(
        [PSCustomObject]@{ username = "compensation-super"; displayName = "Super User"; role = "superAdmin"; employeeCode = $null; disabled = $false; mustChangePassword = $false; passwordSalt = $superCredential.passwordSalt; passwordHash = $superCredential.passwordHash; passwordIterations = $superCredential.passwordIterations; passwordAlgorithm = $superCredential.passwordAlgorithm },
        [PSCustomObject]@{ username = "compensation-admin"; displayName = "Manager User"; role = "admin"; employeeCode = $null; disabled = $false; mustChangePassword = $false; passwordSalt = $adminCredential.passwordSalt; passwordHash = $adminCredential.passwordHash; passwordIterations = $adminCredential.passwordIterations; passwordAlgorithm = $adminCredential.passwordAlgorithm },
        [PSCustomObject]@{ username = "000000001"; displayName = "Worker User"; role = "employee"; employeeCode = "000000001"; disabled = $false; mustChangePassword = $false; passwordSalt = $employeeCredential.passwordSalt; passwordHash = $employeeCredential.passwordHash; passwordIterations = $employeeCredential.passwordIterations; passwordAlgorithm = $employeeCredential.passwordAlgorithm }
    )
    Write-TestJson -Path (Join-Path -Path $dataRoot -ChildPath "sessions.json") -Value ([object[]]@())
    Write-TestJson -Path (Join-Path -Path $dataRoot -ChildPath "history.json") -Value ([object[]]@())
    Write-TestJson -Path (Join-Path -Path $dataRoot -ChildPath "projects.json") -Value ([object[]]@())

    $stdout = Join-Path -Path $tempRoot -ChildPath "stdout.log"
    $stderr = Join-Path -Path $tempRoot -ChildPath "stderr.log"
    $env:SAPHIR_INSTANCE_TOKEN = $instanceToken
    $serverProcess = Start-Process -FilePath (Get-Command pwsh -ErrorAction Stop).Source -ArgumentList @("-NoProfile", "-File", (Join-Path -Path $runtimeRoot -ChildPath "app/backend/saphir-server.ps1")) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

    $ready = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ($serverProcess.HasExited) { break }
        try {
            $probe = Invoke-TestRequest -Method "GET" -Uri "$baseUri/"
            if ($probe.StatusCode -eq 200 -and [string]$probe.Headers["X-SAPHIR-Instance"] -eq $instanceToken) {
                $ready = $true
                break
            }
        }
        catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        $errorText = if (Test-Path -LiteralPath $stderr) { [System.IO.File]::ReadAllText($stderr) } else { "" }
        throw "Compensation integration server did not start. $errorText"
    }

    $anonymous = Invoke-TestRequest -Method "GET" -Uri "$baseUri/compensation-grid"
    Assert-Equal -Expected 401 -Actual $anonymous.StatusCode -Message "Anonymous users must not read the compensation grid."

    $employeeLogin = Invoke-TestRequest -Method "POST" -Uri "$baseUri/auth/login" -Body @{ username = "000000001"; password = $employeePassword }
    Assert-Equal -Expected 200 -Actual $employeeLogin.StatusCode -Message "Employee login failed."
    $employeeToken = [string]$employeeLogin.Json.token
    $employeeRead = Invoke-TestRequest -Method "GET" -Uri "$baseUri/compensation-grid" -Token $employeeToken
    Assert-Equal -Expected 403 -Actual $employeeRead.StatusCode -Message "Employees must not read salary bands."
    $employeeBudgetRead = Invoke-TestRequest -Method "GET" -Uri "$baseUri/budget-periods" -Token $employeeToken
    Assert-Equal -Expected 403 -Actual $employeeBudgetRead.StatusCode -Message "Employees must not read manager budget configuration."
    $employeeProfile = Invoke-TestRequest -Method "GET" -Uri "$baseUri/self/profile" -Token $employeeToken
    Assert-Equal -Expected 200 -Actual $employeeProfile.StatusCode -Message "Employee profile request failed."
    Assert-True -Condition ($employeeProfile.Body -notmatch "annualSalary|compensation") -Message "Employee profile exposed compensation data."

    $adminLogin = Invoke-TestRequest -Method "POST" -Uri "$baseUri/auth/login" -Body @{ username = "compensation-admin"; password = $adminPassword }
    Assert-Equal -Expected 200 -Actual $adminLogin.StatusCode -Message "Admin login failed."
    $adminToken = [string]$adminLogin.Json.token
    $adminRead = Invoke-TestRequest -Method "GET" -Uri "$baseUri/compensation-grid" -Token $adminToken
    Assert-Equal -Expected 403 -Actual $adminRead.StatusCode -Message "Non-super-admin managers must not read salary bands."
    $adminBudgetRead = Invoke-TestRequest -Method "GET" -Uri "$baseUri/budget-periods" -Token $adminToken
    Assert-Equal -Expected 200 -Actual $adminBudgetRead.StatusCode -Message "Managers must be able to read the budget calendar used by project statistics."
    $adminBudgetWrite = Invoke-TestRequest -Method "PUT" -Uri "$baseUri/budget-periods" -Token $adminToken -Body @{ cycleLabel = "blocked"; periods = @() }
    Assert-Equal -Expected 403 -Actual $adminBudgetWrite.StatusCode -Message "Only super admins may change budget dates."
    $employeeBootstrap = Invoke-TestRequest -Method "GET" -Uri "$baseUri/employees/bootstrap" -Token $adminToken
    Assert-Equal -Expected 200 -Actual $employeeBootstrap.StatusCode -Message "Manager employee bootstrap request failed."
    Assert-True -Condition ($employeeBootstrap.Body -notmatch "annualSalary|compensation-grid") -Message "Manager employee bootstrap exposed compensation data."

    $superLogin = Invoke-TestRequest -Method "POST" -Uri "$baseUri/auth/login" -Body @{ username = "compensation-super"; password = $superPassword }
    Assert-Equal -Expected 200 -Actual $superLogin.StatusCode -Message "Super-admin login failed."
    $superToken = [string]$superLogin.Json.token
    $initialRead = Invoke-TestRequest -Method "GET" -Uri "$baseUri/compensation-grid" -Token $superToken
    Assert-Equal -Expected 200 -Actual $initialRead.StatusCode -Message "Super admin could not read the seeded compensation grid."
    Assert-Equal -Expected 1 -Actual ([int]$initialRead.Json.schemaVersion) -Message "Compensation grid schema changed."
    Assert-Equal -Expected "CAD" -Actual ([string]$initialRead.Json.currency) -Message "Compensation grid currency changed."
    Assert-Equal -Expected 10 -Actual @($initialRead.Json.bands).Count -Message "The supplied salary bands were not all seeded."

    $initialBudgetRead = Invoke-TestRequest -Method "GET" -Uri "$baseUri/budget-periods" -Token $superToken
    Assert-Equal -Expected 200 -Actual $initialBudgetRead.StatusCode -Message "Super admin could not read the seeded budget periods."
    Assert-Equal -Expected 4 -Actual @($initialBudgetRead.Json.periods).Count -Message "Budget setup must expose P1 through P4."
    Assert-Equal -Expected 0 -Actual @($initialBudgetRead.Json.periods | Where-Object { [bool]$_.configured }).Count -Message "The release must not invent budget dates."
    $beforeBudgetSync = Invoke-TestRequest -Method "GET" -Uri "$baseUri/sync/status" -Token $superToken
    Assert-Equal -Expected 200 -Actual $beforeBudgetSync.StatusCode -Message "Initial budget sync-state read failed."

    $partialBudgetSave = Invoke-TestRequest -Method "PUT" -Uri "$baseUri/budget-periods" -Token $superToken -Body @{
        cycleLabel = "invalid"
        periods = @(
            @{ id = "P1"; startDate = "2026-04-01"; endDate = "" },
            @{ id = "P2"; startDate = ""; endDate = "" },
            @{ id = "P3"; startDate = ""; endDate = "" },
            @{ id = "P4"; startDate = ""; endDate = "" }
        )
    }
    Assert-Equal -Expected 400 -Actual $partialBudgetSave.StatusCode -Message "A partial budget range must be rejected."

    $validBudgetPeriods = @(
        @{ id = "P1"; startDate = "2026-04-01"; endDate = "2026-06-30" },
        @{ id = "P2"; startDate = "2026-07-01"; endDate = "2026-09-30" },
        @{ id = "P3"; startDate = ""; endDate = "" },
        @{ id = "P4"; startDate = ""; endDate = "" }
    )
    $validBudgetSave = Invoke-TestRequest -Method "PUT" -Uri "$baseUri/budget-periods" -Token $superToken -Body @{ cycleLabel = "2026-2027"; periods = $validBudgetPeriods }
    Assert-Equal -Expected 200 -Actual $validBudgetSave.StatusCode -Message "A valid budget calendar could not be saved."
    Assert-Equal -Expected "2026-2027" -Actual ([string]$validBudgetSave.Json.cycleLabel) -Message "The budget cycle label was not persisted."
    $afterBudgetSync = Invoke-TestRequest -Method "GET" -Uri "$baseUri/sync/status" -Token $superToken
    Assert-Equal -Expected "budget-periods" -Actual ([string]$afterBudgetSync.Json.category) -Message "Budget changes must publish their own sync category."
    Assert-Equal -Expected ([string]$beforeBudgetSync.Json.employeeDataEpoch) -Actual ([string]$afterBudgetSync.Json.employeeDataEpoch) -Message "Budget changes must not invalidate every employee entry cache."
    $budgetStats = Invoke-TestRequest -Method "GET" -Uri "$baseUri/stats/budget-periods" -Token $adminToken
    Assert-Equal -Expected 200 -Actual $budgetStats.StatusCode -Message "Managers could not load the budget-period comparison."
    Assert-Equal -Expected 4 -Actual @($budgetStats.Json.periods).Count -Message "Budget-period statistics must preserve P1 through P4."
    Assert-Equal -Expected $true -Actual ([bool]$budgetStats.Json.periods[0].configured) -Message "Configured periods were not available to project statistics."

    $gridPath = Join-Path -Path $dataRoot -ChildPath "compensation-grid.json"
    Assert-True -Condition (Test-Path -LiteralPath $gridPath -PathType Leaf) -Message "Shared compensation grid was not created."
    $initialGridHash = (Get-FileHash -LiteralPath $gridPath -Algorithm SHA256).Hash
    $initialSync = Invoke-TestRequest -Method "GET" -Uri "$baseUri/sync/status" -Token $superToken
    Assert-Equal -Expected 200 -Actual $initialSync.StatusCode -Message "Initial sync-state read failed."

    $invalidSave = Invoke-TestRequest -Method "PUT" -Uri "$baseUri/compensation-grid" -Token $superToken -Body @{
        bands = @([PSCustomObject]@{ id = "invalid-zero"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 0; effectiveFrom = "2026-01-01" })
    }
    Assert-Equal -Expected 400 -Actual $invalidSave.StatusCode -Message "Invalid salary values must be rejected."
    Assert-Equal -Expected $initialGridHash -Actual (Get-FileHash -LiteralPath $gridPath -Algorithm SHA256).Hash -Message "Rejected salary updates must not write a partial grid."

    $ambiguousClassificationSave = Invoke-TestRequest -Method "PUT" -Uri "$baseUri/compensation-grid" -Token $superToken -Body @{
        bands = @([PSCustomObject]@{ id = "ambiguous-group"; group = "AS-03"; subGroup = "04"; level = "1"; annualSalaryCents = 5727100; effectiveFrom = "2026-01-01" })
    }
    Assert-Equal -Expected 400 -Actual $ambiguousClassificationSave.StatusCode -Message "Ambiguous salary classifications must be rejected instead of silently rewritten."
    Assert-Equal -Expected $initialGridHash -Actual (Get-FileHash -LiteralPath $gridPath -Algorithm SHA256).Hash -Message "A rejected ambiguous classification changed the salary grid."

    $overlappingBands = @($initialRead.Json.bands)
    $overlappingBands += [PSCustomObject]@{ id = "cr-04-overlap"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 5900000; effectiveFrom = "2026-06-01" }
    $overlappingSave = Invoke-TestRequest -Method "PUT" -Uri "$baseUri/compensation-grid" -Token $superToken -Body @{ bands = $overlappingBands }
    Assert-Equal -Expected 400 -Actual $overlappingSave.StatusCode -Message "Overlapping salary periods must be rejected."
    Assert-Equal -Expected $initialGridHash -Actual (Get-FileHash -LiteralPath $gridPath -Algorithm SHA256).Hash -Message "Rejected overlapping updates must not overwrite the grid."

    $validBands = @($initialRead.Json.bands | ForEach-Object {
        [PSCustomObject]@{
            id                = [string]$_.id
            group             = [string]$_.group
            subGroup          = [string]$_.subGroup
            level             = [string]$_.level
            annualSalaryCents = [Int64]$_.annualSalaryCents
            effectiveFrom     = [string]$_.effectiveFrom
            effectiveTo       = if ($null -ne $_.effectiveTo) { [string]$_.effectiveTo } else { "" }
        }
    })
    $firstCrBand = @($validBands | Where-Object { $_.id -eq "cr-04-01-2026" })[0]
    Assert-True -Condition ($null -ne $firstCrBand) -Message "The CR-04 first-echelon seed band is missing."
    $firstCrBand.effectiveTo = "2026-06-30"
    $validBands += [PSCustomObject]@{ id = "cr-04-01-2026-h2"; group = "CR"; subGroup = "04"; level = "1"; annualSalaryCents = 5900000; effectiveFrom = "2026-07-01"; effectiveTo = "" }
    $validSave = Invoke-TestRequest -Method "PUT" -Uri "$baseUri/compensation-grid" -Token $superToken -Body @{ bands = $validBands }
    Assert-Equal -Expected 200 -Actual $validSave.StatusCode -Message "A valid versioned compensation update failed."
    Assert-Equal -Expected 11 -Actual @($validSave.Json.bands).Count -Message "The valid compensation update returned the wrong band count."
    Assert-Equal -Expected 5900000 -Actual (@($validSave.Json.bands | Where-Object { [string]$_.id -eq "cr-04-01-2026-h2" })[0]).annualSalaryCents -Message "The valid updated salary was not stored in cents."
    Assert-True -Condition ($initialGridHash -ne (Get-FileHash -LiteralPath $gridPath -Algorithm SHA256).Hash) -Message "A valid compensation update did not persist."

    $updatedSync = Invoke-TestRequest -Method "GET" -Uri "$baseUri/sync/status" -Token $superToken
    Assert-Equal -Expected 200 -Actual $updatedSync.StatusCode -Message "Updated sync-state read failed."
    Assert-Equal -Expected "compensation" -Actual ([string]$updatedSync.Json.category) -Message "Compensation updates must publish their own sync category."
    Assert-Equal -Expected ([string]$initialSync.Json.employeeDataEpoch) -Actual ([string]$updatedSync.Json.employeeDataEpoch) -Message "Compensation updates must not invalidate every employee entry cache."

    $unsupportedMethod = Invoke-TestRequest -Method "POST" -Uri "$baseUri/compensation-grid" -Token $superToken -Body @{}
    Assert-Equal -Expected 405 -Actual $unsupportedMethod.StatusCode -Message "Compensation grid must accept only GET and PUT."

    Write-Host "Business settings HTTP integration passed: compensation and budget-period access, validation, statistics, and targeted sync are correct."
}
finally {
    $env:SAPHIR_INSTANCE_TOKEN = $previousInstanceToken
    if ($serverProcess -and -not $serverProcess.HasExited -and -not [string]::IsNullOrWhiteSpace($baseUri)) {
        try { Invoke-TestRequest -Method "POST" -Uri "$baseUri/__saphir/control/shutdown" -Headers @{ "X-SAPHIR-Control-Token" = $instanceToken } | Out-Null } catch { }
        try { $serverProcess.WaitForExit(3000) | Out-Null } catch { }
    }
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
