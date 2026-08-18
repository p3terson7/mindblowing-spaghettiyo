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
    Assert-Equal -Expected "STS" -Actual $initialProfileResponse.gc179Profile.position -Message "A legacy Diverse-only profile did not receive the GC179 Group default."
    Assert-Equal -Expected "SUF-00" -Actual $initialProfileResponse.gc179Profile.level -Message "A legacy Diverse-only profile did not receive the GC179 Sub-Group default."

    $studentProfilePayload = [PSCustomObject]@{
        gc179Profile = [PSCustomObject]@{
            surname            = "EMPLOYEE"
            givenName          = "DIVERSE ONLY"
            initials           = "D.O.E"
            pri                = "000000731"
            position           = " sts "
            level              = " suf - 00 "
            compressedWorkWeek = $false
        }
    }
    Invoke-SelfProfileRoute -Method "PUT" -Path "/self/gc179-profile" -Payload $studentProfilePayload
    Assert-Equal -Expected 200 -Actual $script:CapturedStatusCode -Message "A Diverse-only employee could not update their GC179 profile."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "A successful Diverse-only GC179 profile update did not publish exactly one change."

    $savedUsers = @(Get-Content -LiteralPath $script:usersFile -Raw | ConvertFrom-Json)
    $savedUser = $savedUsers | Where-Object { [string]$_.employeeCode -eq $employeeCode } | Select-Object -First 1
    Assert-Equal -Expected "diverse" -Actual (@($savedUser.timeEntryTypes) -join ",") -Message "Saving GC179 parameters changed the employee's Diverse-only rights."
    Assert-Equal -Expected "STS" -Actual $savedUser.gc179Profile.position -Message "The Diverse-only employee's position/group was not persisted."
    Assert-Equal -Expected "SUF-00" -Actual $savedUser.gc179Profile.level -Message "The Diverse-only employee's echelon/sub-group was not persisted."

    Write-Host "Diverse-only GC179 self-profile access test passed."
}
finally {
    if (Test-Path -LiteralPath $tempFolder) {
        Remove-Item -LiteralPath $tempFolder -Recurse -Force
    }
}
