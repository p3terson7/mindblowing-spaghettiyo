$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

function Assert-True {
    param(
        [bool]$Condition,
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

    if (-not [string]::Equals([string]$Expected, [string]$Actual, [System.StringComparison]::Ordinal)) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-HasProperty {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $hasExactProperty = $false
    if ($null -ne $Value) {
        foreach ($property in @($Value.PSObject.Properties)) {
            if ([string]::Equals([string]$property.Name, $PropertyName, [System.StringComparison]::Ordinal)) {
                $hasExactProperty = $true
                break
            }
        }
    }
    if (-not $hasExactProperty) {
        throw "$Message Missing property '$PropertyName'."
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
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
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
        [int]$TimeoutMs = 10000
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
        $bodyText = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
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

        $json = $null
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            try {
                $json = ConvertFrom-Json -InputObject $responseBody -ErrorAction Stop
            }
            catch {
                # Some readiness requests intentionally return frontend HTML.
            }
        }

        return [PSCustomObject]@{
            StatusCode = [int]$webResponse.StatusCode
            Body       = $responseBody
            Json       = $json
            Headers    = $webResponse.Headers
        }
    }
    finally {
        $webResponse.Dispose()
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $scriptRoot -ChildPath "../lib/TestDataSnapshot.ps1")
. (Join-Path -Path $scriptRoot -ChildPath "../lib/TestPowerShellRuntime.ps1")

$tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-phase0-http-{0}" -f ([Guid]::NewGuid().ToString("N")))
$runtimeRoot = Join-Path -Path $tempRoot -ChildPath "runtime"
$testDataRoot = Join-Path -Path $tempRoot -ChildPath "data"
$productionDataRoot = Join-Path -Path $repoRoot -ChildPath "data"
$serverProcess = $null
$previousInstanceToken = [string]$env:SAPHIR_INSTANCE_TOKEN
$instanceToken = [Guid]::NewGuid().ToString("N")
$baseUri = ""

try {
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $testDataRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app") -Destination $runtimeRoot -Recurse -Force

    # Entirely synthetic fixture: it neither reads nor copies repository DATA.
    $adminUsername = "phase0-admin"
    $adminPassword = "Phase0-Contract-Password-123!"
    $employeeCode = "000100001"
    $entryId = "phase0-entry-0001"
    $adminCredential = New-TestPasswordCredential -Password $adminPassword
    $employeeCredential = New-TestPasswordCredential -Password "Employee-Password-123!"

    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "data-schema.json") -Value ([PSCustomObject]@{
        format = "SAPHIR"
        schemaVersion = 1
        minimumReaderVersion = 1
        createdAtUtc = "2026-01-01T00:00:00.0000000Z"
    })
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "employeeNames.json") -Value ([PSCustomObject]@{
        $employeeCode = "Employe Phase Zero"
    })
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "projects.json") -Value ([object[]]@(
        [PSCustomObject]@{
            projectCode = "P001"
            projectName = "Projet contrat"
            sector = "QA"
            color = "blue"
            admins = @()
            backupAdmins = @()
            archived = $false
        }
    ))
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "overtimeCodes.json") -Value ([object[]]@(
        [PSCustomObject]@{ code = "260"; labelEn = "Overtime"; labelFr = "Heures supplementaires" }
    ))
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "paymentOptions.json") -Value ([object[]]@(
        [PSCustomObject]@{ code = "cash"; labelEn = "Cash"; labelFr = "En espece" }
    ))
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "reasonCodes.json") -Value ([object[]]@(
        [PSCustomObject]@{ code = "D"; labelEn = "Workload increase"; labelFr = "Augmentation de la charge" }
    ))
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "history.json") -Value ([object[]]@())
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "sessions.json") -Value ([object[]]@())
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "users.json") -Value ([object[]]@(
        [PSCustomObject]@{
            username = $adminUsername
            displayName = "Phase Zero Admin"
            role = "superAdmin"
            employeeCode = $null
            disabled = $false
            mustChangePassword = $false
            createdAtUtc = "2026-01-01T00:00:00.0000000Z"
            passwordSalt = $adminCredential.passwordSalt
            passwordHash = $adminCredential.passwordHash
            passwordIterations = $adminCredential.passwordIterations
            passwordAlgorithm = $adminCredential.passwordAlgorithm
        },
        [PSCustomObject]@{
            username = $employeeCode
            displayName = "Employe Phase Zero"
            role = "employee"
            employeeCode = $employeeCode
            disabled = $false
            mustChangePassword = $false
            timeEntryTypes = @("overtime")
            createdAtUtc = "2026-01-01T00:00:00.0000000Z"
            passwordSalt = $employeeCredential.passwordSalt
            passwordHash = $employeeCredential.passwordHash
            passwordIterations = $employeeCredential.passwordIterations
            passwordAlgorithm = $employeeCredential.passwordAlgorithm
        }
    )) -Depth 10
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath "sync-state.json") -Value ([PSCustomObject]@{
        version = 0
        changeId = "11111111-1111-4111-8111-111111111111"
        updatedAtUtc = "2026-01-01T00:00:00.0000000Z"
        category = "bootstrap"
        resource = "system"
        employeeDataEpoch = "22222222-2222-4222-8222-222222222222"
        employeeDataRevisions = [PSCustomObject]@{}
    })
    Write-TestJson -Path (Join-Path -Path $testDataRoot -ChildPath ("{0}_data.json" -f $employeeCode)) -Value ([object[]]@(
        [PSCustomObject]@{
            entryId = $entryId
            name = "Employe Phase Zero"
            date = "2026-07-15"
            punchIn = "16:00:00"
            exactPunchIn = "16:02:00"
            punchOut = "17:00:00"
            exactPunchOut = "17:01:00"
            overtime = "01:00:00"
            status = "pending"
            message = ""
            projectCode = "P001"
            overtimeCode = "260"
            paymentOption = "cash"
            reasonCode = "D"
            workComment = "Preparation du test de contrat."
        }
    )) -Depth 8

    # Prove that the snapshot guard recognizes and refuses the real repository DATA path.
    $productionGuardWorked = $false
    try {
        Get-TestDataFolderSnapshot -RootPath $productionDataRoot -ForbiddenRootPath $productionDataRoot | Out-Null
    }
    catch {
        $productionGuardWorked = $_.Exception.Message -eq "Phase-zero mutation tests cannot use the repository DATA folder."
    }
    Assert-True -Condition $productionGuardWorked -Message "The phase-zero snapshot helper did not refuse production DATA."

    # This descendant does not need to exist: the guard must reject it from
    # normalized paths before performing any filesystem probe below DATA.
    $productionDescendantGuardWorked = $false
    try {
        Get-TestDataFolderSnapshot `
            -RootPath (Join-Path -Path $productionDataRoot -ChildPath "__phase0-never-probe__") `
            -ForbiddenRootPath $productionDataRoot | Out-Null
    }
    catch {
        $productionDescendantGuardWorked = $_.Exception.Message -eq "Phase-zero mutation tests cannot use the repository DATA folder."
    }
    Assert-True -Condition $productionDescendantGuardWorked -Message "The phase-zero snapshot helper did not reject a production DATA descendant before probing it."

    # Characterize the guard itself: a field outside the explicit allow-list
    # must fail before this helper is trusted to protect mutation contracts.
    $snapshotHelperRoot = Join-Path -Path $tempRoot -ChildPath "snapshot-helper-fixture"
    New-Item -ItemType Directory -Path $snapshotHelperRoot -Force | Out-Null
    $snapshotHelperPath = Join-Path -Path $snapshotHelperRoot -ChildPath "records.json"
    Write-TestJson -Path $snapshotHelperPath -Value ([object[]]@(
        [PSCustomObject]@{ status = "pending"; protectedValue = "original" }
    ))
    $helperBefore = Get-TestDataFolderSnapshot -RootPath $snapshotHelperRoot -ForbiddenRootPath $productionDataRoot
    Write-TestJson -Path $snapshotHelperPath -Value ([object[]]@(
        [PSCustomObject]@{ status = "approved"; protectedValue = "changed" }
    ))
    $helperAfterUnexpectedChange = Get-TestDataFolderSnapshot -RootPath $snapshotHelperRoot -ForbiddenRootPath $productionDataRoot
    $unexpectedFieldRejected = $false
    try {
        Assert-TestDataFolderChanges -Before $helperBefore -After $helperAfterUnexpectedChange -AllowedChanges @{
            "records.json" = @('$[0].status')
        } -Description "Snapshot helper self-test" | Out-Null
    }
    catch {
        $unexpectedFieldRejected = $true
    }
    Assert-True -Condition $unexpectedFieldRejected -Message "The snapshot helper accepted an unexpected JSON field mutation."

    # Property names are part of the persisted JSON contract. A case-only
    # rename must expose both the removed and added leaf, and a lower-case
    # allow-list must never authorize the upper-case replacement.
    Write-TestJson -Path $snapshotHelperPath -Value ([object[]]@(
        [PSCustomObject]@{ status = "pending" }
    ))
    $helperBeforeCaseRename = Get-TestDataFolderSnapshot -RootPath $snapshotHelperRoot -ForbiddenRootPath $productionDataRoot
    Write-TestJson -Path $snapshotHelperPath -Value ([object[]]@(
        [PSCustomObject]@{ Status = "pending" }
    ))
    $helperAfterCaseRename = Get-TestDataFolderSnapshot -RootPath $snapshotHelperRoot -ForbiddenRootPath $productionDataRoot
    $caseRenamePaths = @(Get-TestChangedJsonPaths `
        -BeforeFile $helperBeforeCaseRename.Files["records.json"] `
        -AfterFile $helperAfterCaseRename.Files["records.json"])
    Assert-Equal -Expected '$[0].Status,$[0].status' -Actual ($caseRenamePaths -join ",") -Message "The snapshot helper collapsed case-distinct JSON paths."
    $caseRenameRejected = $false
    try {
        Assert-TestDataFolderChanges -Before $helperBeforeCaseRename -After $helperAfterCaseRename -AllowedChanges @{
            "records.json" = @('$[0].status')
        } -Description "Snapshot helper case-sensitivity self-test" | Out-Null
    }
    catch {
        $caseRenameRejected = $true
    }
    Assert-True -Condition $caseRenameRejected -Message "The snapshot helper allowed a status-to-Status JSON property rename."

    $caseOnlyPropertyRejected = $false
    try {
        Assert-HasProperty -Value ([PSCustomObject]@{ Status = "pending" }) -PropertyName "status" -Message "Property case self-test"
    }
    catch {
        $caseOnlyPropertyRejected = $true
    }
    Assert-True -Condition $caseOnlyPropertyRejected -Message "HTTP property contracts accepted a case-only property mismatch."
    Remove-Item -LiteralPath $snapshotHelperRoot -Recurse -Force

    $portListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $portListener.Start()
    $port = ([System.Net.IPEndPoint]$portListener.LocalEndpoint).Port
    $portListener.Stop()
    $baseUri = "http://localhost:$port"

    $safeDataRoot = $testDataRoot.Replace("'", "''")
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

    $serverPath = Join-Path -Path $runtimeRoot -ChildPath "app/backend/saphir-server.ps1"
    $stdoutPath = Join-Path -Path $tempRoot -ChildPath "server.stdout.log"
    $stderrPath = Join-Path -Path $tempRoot -ChildPath "server.stderr.log"
    $env:SAPHIR_INSTANCE_TOKEN = $instanceToken
    $powerShellPath = Get-TestPowerShellExecutable
    Assert-TestPowerShellExecutableMatchesCurrentEdition -Path $powerShellPath -Description "HTTP contract server"
    $serverProcess = Start-Process -FilePath $powerShellPath `
        -ArgumentList @("-NoProfile", "-File", $serverPath) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    $ready = $false
    $startupDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $startupDeadline) {
        if ($serverProcess.HasExited) {
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
        catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        $stderrText = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath) } else { "" }
        $stdoutText = if (Test-Path -LiteralPath $stdoutPath) { [System.IO.File]::ReadAllText($stdoutPath) } else { "" }
        throw "Phase-zero HTTP server did not become ready. STDOUT: $stdoutText STDERR: $stderrText"
    }

    $beforeLogin = Get-TestDataFolderSnapshot -RootPath $testDataRoot -ForbiddenRootPath $productionDataRoot

    $unauthorizedDashboard = Invoke-TestHttpRequest -Method "GET" -Uri "$baseUri/dashboard/bootstrap"
    Assert-Equal -Expected 401 -Actual $unauthorizedDashboard.StatusCode -Message "Dashboard authentication contract changed."
    Assert-Equal -Expected "Authentication required." -Actual ([string]$unauthorizedDashboard.Json.error) -Message "Dashboard 401 body contract changed."

    $invalidLogin = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/auth/login" -Body @{
        username = $adminUsername
        password = "wrong-password"
    }
    Assert-Equal -Expected 401 -Actual $invalidLogin.StatusCode -Message "Invalid-login status contract changed."
    Assert-Equal -Expected "Invalid credentials." -Actual ([string]$invalidLogin.Json.error) -Message "Invalid-login body contract changed."

    $login = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/auth/login" -Body @{
        username = $adminUsername
        password = $adminPassword
    }
    Assert-Equal -Expected 200 -Actual $login.StatusCode -Message "Valid login failed."
    Assert-HasProperty -Value $login.Json -PropertyName "token" -Message "Login response contract changed."
    Assert-HasProperty -Value $login.Json -PropertyName "user" -Message "Login response contract changed."
    Assert-Equal -Expected $adminUsername -Actual ([string]$login.Json.user.username) -Message "Login returned the wrong user."
    Assert-Equal -Expected "superAdmin" -Actual ([string]$login.Json.user.role) -Message "Login returned the wrong role."
    $token = [string]$login.Json.token
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($token)) -Message "Login did not return a bearer token."

    $afterLogin = Get-TestDataFolderSnapshot -RootPath $testDataRoot -ForbiddenRootPath $productionDataRoot
    $loginChanges = @(Assert-TestDataFolderChanges -Before $beforeLogin -After $afterLogin -Description "Login" -AllowedChanges @{
        "sessions.json" = @('$[{index}].*')
    })
    Assert-Equal -Expected "sessions.json" -Actual ($loginChanges -join ",") -Message "Login changed files outside its persistence contract."

    $beforeReads = $afterLogin
    $me = Invoke-TestHttpRequest -Method "GET" -Uri "$baseUri/auth/me" -Token $token
    Assert-Equal -Expected 200 -Actual $me.StatusCode -Message "Authenticated-session read failed."
    Assert-Equal -Expected $adminUsername -Actual ([string]$me.Json.username) -Message "Session projection returned the wrong user."
    Assert-Equal -Expected "superAdmin" -Actual ([string]$me.Json.role) -Message "Session projection returned the wrong role."

    $dashboard = Invoke-TestHttpRequest -Method "GET" -Uri "$baseUri/dashboard/bootstrap" -Token $token
    Assert-Equal -Expected 200 -Actual $dashboard.StatusCode -Message "Dashboard bootstrap failed."
    foreach ($propertyName in @("employees", "totalOvertime", "pendingApprovals", "projects", "pendingQueue", "recentHistory", "selectedEmployeeEntries")) {
        Assert-HasProperty -Value $dashboard.Json -PropertyName $propertyName -Message "Dashboard body contract changed."
    }
    Assert-Equal -Expected 1 -Actual ([int]$dashboard.Json.pendingApprovals) -Message "Dashboard pending count changed unexpectedly."
    Assert-Equal -Expected $employeeCode -Actual ([string]$dashboard.Json.defaultEmployeeCode) -Message "Dashboard default employee contract changed."

    $employeeRead = Invoke-TestHttpRequest -Method "GET" -Uri "$baseUri/employee/$employeeCode" -Token $token
    Assert-Equal -Expected 200 -Actual $employeeRead.StatusCode -Message "Employee entry read failed."
    Assert-True -Condition $employeeRead.Body.TrimStart().StartsWith("[") -Message "Employee entry response must remain a JSON array."
    $readEntries = @($employeeRead.Json)
    Assert-Equal -Expected 1 -Actual $readEntries.Count -Message "Employee read returned the wrong number of entries."
    Assert-Equal -Expected $entryId -Actual ([string]$readEntries[0].entryId) -Message "Employee read returned the wrong entry."
    foreach ($propertyName in @("employeeCode", "employeeName", "canModify", "canApprove", "entryId", "projectCode", "status")) {
        Assert-HasProperty -Value $readEntries[0] -PropertyName $propertyName -Message "Employee projection contract changed."
    }

    $missingEmployee = Invoke-TestHttpRequest -Method "GET" -Uri "$baseUri/employee/999999999" -Token $token
    Assert-Equal -Expected 404 -Actual $missingEmployee.StatusCode -Message "Missing-employee status contract changed."
    Assert-Equal -Expected "Employee not found" -Actual ([string]$missingEmployee.Json.error) -Message "Missing-employee body contract changed."

    $afterReads = Get-TestDataFolderSnapshot -RootPath $testDataRoot -ForbiddenRootPath $productionDataRoot
    Assert-TestDataFolderUnchanged -Before $beforeReads -After $afterReads -Description "Auth/dashboard/employee reads"

    $beforeAdd = $afterReads
    $manualAdd = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/employee/add/$employeeCode" -Token $token -Body @{
        date = "2026-07-16"
        punchIn = "17:02"
        punchOut = "18:01"
        projectCode = "P001"
        overtimeCode = "260"
        paymentOption = "cash"
        reasonCode = "D"
    }
    Assert-Equal -Expected 200 -Actual $manualAdd.StatusCode -Message "Manual entry creation failed."
    Assert-Equal -Expected "Entry added successfully." -Actual ([string]$manualAdd.Json.message) -Message "Manual-add response contract changed."
    Assert-Equal -Expected "17:02:00" -Actual ([string]$manualAdd.Json.time) -Message "Manual-add response time contract changed."
    Assert-HasProperty -Value $manualAdd.Json -PropertyName "warnings" -Message "Manual-add warning contract changed."

    $afterAdd = Get-TestDataFolderSnapshot -RootPath $testDataRoot -ForbiddenRootPath $productionDataRoot
    $addChanges = @(Assert-TestDataFolderChanges -Before $beforeAdd -After $afterAdd -Description "Manual add" -AllowedChanges @{
        ("{0}_data.json" -f $employeeCode) = @('$[1].*')
        "history.json" = @('$[0].*')
        "sync-state.json" = @(
            '$.version',
            '$.changeId',
            '$.updatedAtUtc',
            '$.category',
            '$.resource',
            ("`$.employeeDataRevisions.{0}" -f $employeeCode)
        )
    })
    Assert-Equal -Expected ((@(("{0}_data.json" -f $employeeCode), "history.json", "sync-state.json") | Sort-Object) -join ",") -Actual (($addChanges | Sort-Object) -join ",") -Message "Manual add changed files outside its persistence contract."
    $savedAfterAdd = @([System.IO.File]::ReadAllText((Join-Path -Path $testDataRoot -ChildPath ("{0}_data.json" -f $employeeCode))) | ConvertFrom-Json)
    Assert-Equal -Expected 2 -Actual $savedAfterAdd.Count -Message "Manual add did not preserve the original entry."
    Assert-Equal -Expected $entryId -Actual ([string]$savedAfterAdd[0].entryId) -Message "Manual add replaced the original entry."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$savedAfterAdd[1].entryId)) -Message "Manual add did not persist an entry ID."

    $beforeApproval = $afterAdd
    $approval = Invoke-TestHttpRequest -Method "POST" -Uri "$baseUri/employee/approval/$employeeCode" -Token $token -Body @{
        entryId = $entryId
        status = "approved"
        message = ""
    }
    Assert-Equal -Expected 200 -Actual $approval.StatusCode -Message "Entry approval failed."
    Assert-Equal -Expected "Entry updated successfully." -Actual ([string]$approval.Json.message) -Message "Approval response contract changed."
    Assert-Equal -Expected $entryId -Actual ([string]$approval.Json.entryId) -Message "Approval response returned the wrong entry ID."
    Assert-HasProperty -Value $approval.Json -PropertyName "warnings" -Message "Approval warning contract changed."

    $afterApproval = Get-TestDataFolderSnapshot -RootPath $testDataRoot -ForbiddenRootPath $productionDataRoot
    $approvalChanges = @(Assert-TestDataFolderChanges -Before $beforeApproval -After $afterApproval -Description "Approval" -AllowedChanges @{
        ("{0}_data.json" -f $employeeCode) = @('$[0].status')
        "history.json" = @('$[1].*')
        "sync-state.json" = @(
            '$.version',
            '$.changeId',
            '$.updatedAtUtc',
            '$.category',
            '$.resource',
            ("`$.employeeDataRevisions.{0}" -f $employeeCode)
        )
    })
    Assert-Equal -Expected ((@(("{0}_data.json" -f $employeeCode), "history.json", "sync-state.json") | Sort-Object) -join ",") -Actual (($approvalChanges | Sort-Object) -join ",") -Message "Approval changed files outside its persistence contract."
    $savedAfterApproval = @([System.IO.File]::ReadAllText((Join-Path -Path $testDataRoot -ChildPath ("{0}_data.json" -f $employeeCode))) | ConvertFrom-Json)
    Assert-Equal -Expected "approved" -Actual ([string]$savedAfterApproval[0].status) -Message "Approval was not persisted on the requested entry."
    Assert-Equal -Expected "pending" -Actual ([string]$savedAfterApproval[1].status) -Message "Approval modified the wrong entry."

    Write-Host "Phase-zero HTTP contracts passed: auth, dashboard, employee read, add, approval, and strict isolated-DATA diffs are stable."
}
finally {
    $env:SAPHIR_INSTANCE_TOKEN = $previousInstanceToken
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited -and -not [string]::IsNullOrWhiteSpace($baseUri)) {
        try {
            Invoke-TestHttpRequest `
                -Method "POST" `
                -Uri "$baseUri/__saphir/control/shutdown" `
                -Headers @{ "X-SAPHIR-Control-Token" = $instanceToken } `
                -TimeoutMs 3000 | Out-Null
            $serverProcess.WaitForExit(3000) | Out-Null
        }
        catch {
            # The process is scoped to the disposable test runtime below.
        }
    }
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
