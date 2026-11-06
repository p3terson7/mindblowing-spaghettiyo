$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-self-gc179-profile-{0}" -f ([Guid]::NewGuid().ToString("N")))

try {
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null

    $script:sharedFolder = $tempFolder
    $script:usersFile = Join-Path -Path $tempFolder -ChildPath "users.json"
    $script:sessionsFile = Join-Path -Path $tempFolder -ChildPath "sessions.json"
    $script:projectsFile = Join-Path -Path $tempFolder -ChildPath "projects.json"
    $script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
    $script:bootstrapAdminUsername = "admin"
    $script:bootstrapAdminPassword = "ChangeMe123!"

    New-Item -ItemType Directory -Path $script:lockFolder -Force | Out-Null
    [System.IO.File]::WriteAllText($script:sessionsFile, "[]", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($script:projectsFile, "[]", [System.Text.Encoding]::UTF8)

    $employeeCode = "000000731"
    $seedUser = [PSCustomObject]@{
        username           = $employeeCode
        employeeCode       = $employeeCode
        displayName        = "Diverse Only Employee"
        role               = "employee"
        disabled           = $false
        mustChangePassword = $false
        timeEntryTypes     = @("diverse")
        gc179Profile       = $null
    }
    [System.IO.File]::WriteAllText($script:usersFile, (ConvertTo-Json -InputObject @($seedUser) -Depth 8), [System.Text.Encoding]::UTF8)

    . (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/services/AuthService.ps1")

    $script:CurrentUser = $seedUser
    $script:RequestPayload = $null
    $script:CapturedStatusCode = 0
    $script:CapturedBody = ""
    $script:PublishCount = 0

    function Get-AuthenticatedUserFromRequest {
        param($Request)
        return $script:CurrentUser
    }

    function Read-JsonRequestBody {
        param($Request)
        return $script:RequestPayload
    }

    function Publish-DataChange {
        param(
            [string]$Category = "data",
            [string]$Resource = "shared",
            [string[]]$AffectedEmployeeCodes = @()
        )
        $script:PublishCount++
    }

    function Invoke-PostCommitActionSafely {
        param([string]$Description, [scriptblock]$Action)
        try {
            & $Action | Out-Null
            return ""
        }
        catch {
            return "$Description`: $($_.Exception.Message)"
        }
    }

    function Rethrow-HttpStatusException {
        param($Exception)
        if ($null -ne $Exception -and
            $null -ne $Exception.Data -and
            $Exception.Data.Contains("SaphirHttpStatusCode")) {
            throw $Exception
        }
    }

    function respondWithSuccess {
        param($Response, [string]$Message)
        $script:CapturedStatusCode = 200
        $script:CapturedBody = $Message
    }

    function respondWithError {
        param($Response, [int]$StatusCode, [string]$Message)
        $script:CapturedStatusCode = $StatusCode
        $script:CapturedBody = $Message
    }

    function Invoke-SelfProfileRoute {
        param(
            [Parameter(Mandatory = $true)][string]$Method,
            [Parameter(Mandatory = $true)][string]$Path,
            $Payload = $null
        )

        $script:CapturedStatusCode = 0
        $script:CapturedBody = ""
        $script:RequestPayload = $Payload
        $request = [PSCustomObject]@{
            HttpMethod = $Method
            Url        = [PSCustomObject]@{ AbsolutePath = $Path }
        }
        $response = [PSCustomObject]@{}

        for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
            . (Join-Path -Path $repoRoot -ChildPath "app/backend/routes/self.routes.ps1")
        }
    }

    Invoke-SelfProfileRoute -Method "GET" -Path "/self/profile"
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A Diverse-only employee could not read their self profile."
    $initialProfileResponse = $script:CapturedBody | ConvertFrom-Json
    Assert-Equal -Expected "diverse" -Actual (@($initialProfileResponse.timeEntryTypes) -join ",") -Message "Reading the profile changed or hid Diverse-only access."
    Assert-Equal -Expected "STS" -Actual $initialProfileResponse.gc179Profile.group -Message "A legacy Diverse-only profile did not receive the GC179 Group default."
    Assert-Equal -Expected "00" -Actual $initialProfileResponse.gc179Profile.subGroup -Message "A legacy Diverse-only profile did not receive the two-digit GC179 Sub-Group default."
    Assert-Equal -Expected "" -Actual $initialProfileResponse.gc179Profile.level -Message "A legacy Diverse-only profile did not receive a blank GC179 Level."

    $usersBeforeInvalidProfile = [IO.File]::ReadAllText($script:usersFile)
    $invalidProfilePayload = [PSCustomObject]@{
        gc179Profile = [PSCustomObject]@{ group = "AS-03"; subGroup = "04"; level = "123" }
    }
    Invoke-SelfProfileRoute -Method "PUT" -Path "/self/gc179-profile" -Payload $invalidProfilePayload
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "Ambiguous GC179 classifications must be rejected on self-service writes."
    Assert-Equal -Expected $usersBeforeInvalidProfile -Actual ([IO.File]::ReadAllText($script:usersFile)) -Message "A rejected GC179 classification changed users.json."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "A rejected GC179 classification published a false data change."

    $studentProfilePayload = [PSCustomObject]@{
        gc179Profile = [PSCustomObject]@{
            surname            = "EMPLOYEE"
            givenName          = "DIVERSE ONLY"
            initials           = "D.O.E"
            pri                = "000000731"
            group              = " sts "
            subGroup           = " 0 "
            level              = " 02 "
            compressedWorkWeek = $false
        }
    }
    Invoke-SelfProfileRoute -Method "PUT" -Path "/self/gc179-profile" -Payload $studentProfilePayload
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A Diverse-only employee could not update their GC179 profile."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "A successful Diverse-only GC179 profile update did not publish exactly one change."

    $savedUsers = @(Get-Content -LiteralPath $script:usersFile -Raw | ConvertFrom-Json)
    $savedUser = $savedUsers | Where-Object { [string]$_.employeeCode -eq $employeeCode } | Select-Object -First 1
    Assert-Equal -Expected "diverse" -Actual (@($savedUser.timeEntryTypes) -join ",") -Message "Saving GC179 parameters changed the employee's Diverse-only rights."
    Assert-Equal -Expected "STS" -Actual $savedUser.gc179Profile.group -Message "The Diverse-only employee's Group was not persisted."
    Assert-Equal -Expected "00" -Actual $savedUser.gc179Profile.subGroup -Message "The Diverse-only employee's Sub-Group was not normalized and persisted."
    Assert-Equal -Expected "02" -Actual $savedUser.gc179Profile.level -Message "The Diverse-only employee's Level was not persisted."

    Invoke-SelfProfileRoute -Method "PUT" -Path "/self/work-schedule" -Payload ([PSCustomObject]@{ compressedWorkWeek = $true })
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "The employee could not enable compressed time from the dashboard."
    $scheduleResponse = $script:CapturedBody | ConvertFrom-Json
    Assert-Equal -Expected "compressed" -Actual $scheduleResponse.workSchedule -Message "The dashboard endpoint returned the wrong normalized schedule."
    Assert-Equal -Expected 2 -Actual $script:PublishCount -Message "The compressed-schedule update did not publish exactly one additional auth change."

    $savedUsers = @(Get-Content -LiteralPath $script:usersFile -Raw | ConvertFrom-Json)
    $savedUser = $savedUsers | Where-Object { [string]$_.employeeCode -eq $employeeCode } | Select-Object -First 1
    Assert-Equal -Expected $true -Actual $savedUser.gc179Profile.compressedWorkWeek -Message "The dashboard schedule was not persisted."
    Assert-Equal -Expected "STS" -Actual $savedUser.gc179Profile.group -Message "The targeted schedule update overwrote the employee's Group."
    Assert-Equal -Expected "00" -Actual $savedUser.gc179Profile.subGroup -Message "The targeted schedule update overwrote the employee's Sub-Group."
    Assert-Equal -Expected "02" -Actual $savedUser.gc179Profile.level -Message "The targeted schedule update overwrote the employee's Level."

    Invoke-SelfProfileRoute -Method "PUT" -Path "/self/work-schedule" -Payload ([PSCustomObject]@{ compressedWorkWeek = "yes" })
    Assert-Equal -Expected 400 -Actual $script:CapturedStatusCode -Message "The dashboard endpoint accepted a non-boolean schedule value."

    # Legacy classifications remain readable, but a schedule-only change must
    # not silently migrate or truncate them.
    $savedUsers = @([IO.File]::ReadAllText($script:usersFile) | ConvertFrom-Json)
    $savedUser = $savedUsers | Where-Object { [string]$_.employeeCode -eq $employeeCode } | Select-Object -First 1
    $savedUser.gc179Profile.group = "AS-03"
    $savedUser.gc179Profile.subGroup = "SG-4"
    $savedUser.gc179Profile.level = "L-1"
    [IO.File]::WriteAllText($script:usersFile, (ConvertTo-Json -InputObject ([object[]]$savedUsers) -Depth 8))
    Clear-AuthRuntimeCaches
    $script:CurrentUser = $savedUser
    $legacyProfileBytes = [IO.File]::ReadAllText($script:usersFile)

    Invoke-SelfProfileRoute -Method "GET" -Path "/self/profile"
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A legacy decorated classification could not be read."
    $legacyReadResponse = $script:CapturedBody | ConvertFrom-Json
    Assert-Equal -Expected "AS" -Actual $legacyReadResponse.gc179Profile.group -Message "Legacy Group compatibility changed."
    Assert-Equal -Expected "04" -Actual $legacyReadResponse.gc179Profile.subGroup -Message "Legacy Sub-group compatibility changed."
    Assert-Equal -Expected "01" -Actual $legacyReadResponse.gc179Profile.level -Message "Legacy Level compatibility changed."
    Assert-Equal -Expected $legacyProfileBytes -Actual ([IO.File]::ReadAllText($script:usersFile)) -Message "Reading a legacy classification rewrote users.json."

    Invoke-SelfProfileRoute -Method "PUT" -Path "/self/work-schedule" -Payload ([PSCustomObject]@{ compressedWorkWeek = $false })
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A schedule-only update failed for a legacy classification."
    Assert-Equal -Expected 3 -Actual $script:PublishCount -Message "The second valid schedule update did not publish exactly one change."
    $savedUsers = @([IO.File]::ReadAllText($script:usersFile) | ConvertFrom-Json)
    $savedUser = $savedUsers | Where-Object { [string]$_.employeeCode -eq $employeeCode } | Select-Object -First 1
    Assert-Equal -Expected "AS-03" -Actual $savedUser.gc179Profile.group -Message "A schedule-only update rewrote a legacy Group."
    Assert-Equal -Expected "SG-4" -Actual $savedUser.gc179Profile.subGroup -Message "A schedule-only update rewrote a legacy Sub-group."
    Assert-Equal -Expected "L-1" -Actual $savedUser.gc179Profile.level -Message "A schedule-only update rewrote a legacy Level."
    Assert-Equal -Expected $false -Actual $savedUser.gc179Profile.compressedWorkWeek -Message "The legacy profile schedule itself was not updated."

    Write-Host "Diverse-only GC179 self-profile access test passed."
}
finally {
    if (Test-Path -LiteralPath $tempFolder) {
        Remove-Item -LiteralPath $tempFolder -Recurse -Force
    }
}
