$ErrorActionPreference = "Stop"

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
$repoRoot = (Get-Item -Path $scriptRoot).Parent.FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("overtime-batch-test-{0}" -f ([Guid]::NewGuid().ToString("N")))

. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/CommonHelpers.ps1")
. (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/EntryService.ps1")

$entries = @(
    [PSCustomObject]@{ entryId = "first"; date = "2026-07-01"; punchIn = "08:00:00"; exactPunchIn = "08:00:05" },
    [PSCustomObject]@{ entryId = "second"; date = "2026-07-02"; punchIn = "09:00:00"; exactPunchIn = "09:00:04" },
    [PSCustomObject]@{ entryId = "duplicate"; date = "2026-07-03"; punchIn = "10:00:00"; exactPunchIn = "10:00:01" },
    [PSCustomObject]@{ entryId = "duplicate"; date = "2026-07-03"; punchIn = "10:00:00"; exactPunchIn = "10:00:02" }
)
$lookup = New-EntryIndexLookup -Entries $entries
$lookupRequests = @(
    [PSCustomObject]@{ entryId = "second"; date = ""; punchIn = "" },
    [PSCustomObject]@{ entryId = "missing"; date = "2026-07-01"; punchIn = "08:00:05" },
    [PSCustomObject]@{ entryId = ""; date = "2026-07-02"; punchIn = "09:00:00" },
    [PSCustomObject]@{ entryId = "duplicate"; date = ""; punchIn = "" },
    [PSCustomObject]@{ entryId = "second"; date = "2026-07-01"; punchIn = "08:00:00" },
    [PSCustomObject]@{ entryId = "missing"; date = "2026-07-04"; punchIn = "11:00:00" }
)

foreach ($request in $lookupRequests) {
    $linearIndex = Find-EntryIndex -Entries $entries -EntryId $request.entryId -Date $request.date -PunchIn $request.punchIn
    $indexedIndex = Find-EntryIndexFromLookup -Lookup $lookup -EntryId $request.entryId -Date $request.date -PunchIn $request.punchIn
    Assert-Equal -Expected $linearIndex -Actual $indexedIndex -Message "Indexed entry lookup changed matching behavior."
}

$largeEntries = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 1000; $i++) {
    [void]$largeEntries.Add([PSCustomObject]@{
        entryId      = ("entry-{0}" -f $i)
        date         = (Get-Date "2026-01-01").AddDays($i).ToString("yyyy-MM-dd")
        punchIn      = "08:00:00"
        exactPunchIn = "08:00:01"
    })
}
$largeRequests = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 300; $i++) {
    [void]$largeRequests.Add(("entry-{0}" -f (($i * 37) % 1000)))
}

$linearElapsed = Measure-Command {
    foreach ($entryId in $largeRequests) {
        Find-EntryIndex -Entries $largeEntries -EntryId $entryId -Date "" -PunchIn "" | Out-Null
    }
}
$indexedElapsed = Measure-Command {
    $largeLookup = New-EntryIndexLookup -Entries $largeEntries
    foreach ($entryId in $largeRequests) {
        Find-EntryIndexFromLookup -Lookup $largeLookup -EntryId $entryId -Date "" -PunchIn "" | Out-Null
    }
}

try {
    New-Item -ItemType Directory -Path $tempFolder | Out-Null
    $script:sharedFolder = $tempFolder
    $script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
    $historyPath = Join-Path -Path $tempFolder -ChildPath "history.json"

    $seedHistory = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 200; $i++) {
        [void]$seedHistory.Add([PSCustomObject]@{
            action         = "Seed"
            message        = ("Seed history {0}" -f $i)
            employee       = "Seed Employee"
            targetEmployee = "Seed Employee"
            author         = "System"
            authorUsername = ""
            authorRole     = ""
            timestamp      = "2026-01-01 00:00:00"
        })
    }
    [System.IO.File]::WriteAllText($historyPath, ($seedHistory.ToArray() | ConvertTo-Json -Depth 6))

    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")

    $script:PublishCount = 0
    $script:LastPublishCategory = ""
    $script:LastPublishResource = ""
    $script:LastAffectedEmployeeCodes = @()
    $script:PublishFailureMessage = ""
    function Publish-DataChange {
        param(
            [string]$Category = "data",
            [string]$Resource = "shared",
            [string[]]$AffectedEmployeeCodes = @()
        )

        $script:PublishCount++
        $script:LastPublishCategory = $Category
        $script:LastPublishResource = $Resource
        $script:LastAffectedEmployeeCodes = @($AffectedEmployeeCodes)
        if (-not [string]::IsNullOrWhiteSpace($script:PublishFailureMessage)) {
            throw $script:PublishFailureMessage
        }
    }

    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/HistoryService.ps1")

    # Warm this process's cache, then simulate another process committing a
    # history record while respecting the shared resource lock.
    @(Read-JsonArrayFile -Path $historyPath) | Out-Null
    $externalHistory = @(Get-Content -Path $historyPath -Raw | ConvertFrom-Json)
    $externalHistory += [PSCustomObject]@{
        action = "External"; message = "External history"; employee = "External Employee";
        targetEmployee = "External Employee"; author = "External"; authorUsername = "external";
        authorRole = "admin"; timestamp = "2026-02-01 00:00:00"
    }
    $externalLock = Acquire-ResourceLock -ResourcePath $historyPath
    try {
        [System.IO.File]::WriteAllText($historyPath, ($externalHistory | ConvertTo-Json -Depth 6))
    }
    finally {
        Release-ResourceLock -LockHandle $externalLock
    }

    $script:OriginalReadJsonArrayFile = ${function:Read-JsonArrayFile}
    $script:OriginalWriteJsonAtomic = ${function:Write-JsonAtomic}
    $script:HistoryReadCount = 0
    $script:HistoryWriteCount = 0
    $script:WriteCountsByPath = @{}
    function Read-JsonArrayFile {
        param([Parameter(Mandatory = $true)][string]$Path)
        $script:HistoryReadCount++
        return (& $script:OriginalReadJsonArrayFile -Path $Path)
    }
    function Write-JsonAtomic {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)]$Value,
            [int]$Depth = 6
        )
        $script:HistoryWriteCount++
        if (-not $script:WriteCountsByPath.ContainsKey($Path)) {
            $script:WriteCountsByPath[$Path] = 0
        }
        $script:WriteCountsByPath[$Path]++
        & $script:OriginalWriteJsonAtomic -Path $Path -Value $Value -Depth $Depth
    }

    $currentUser = [PSCustomObject]@{
        displayName = "Batch Manager"
        username    = "manager"
        role        = "admin"
    }
    $batchHistory = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 20; $i++) {
        [void]$batchHistory.Add([PSCustomObject]@{
            action       = "Approved"
            message      = ("Approved entry {0}." -f $i)
            employeeName = if (($i % 2) -eq 0) { "Employee One" } else { "Employee Two" }
        })
    }

    $addedCount = Add-HistoryEntries -Entries @($batchHistory.ToArray()) -PublishChange:$false
    Assert-Equal -Expected 20 -Actual $addedCount -Message "The batch history helper did not append every valid record."
    Assert-Equal -Expected 1 -Actual $script:HistoryReadCount -Message "Batch history should read history.json once."
    Assert-Equal -Expected 1 -Actual $script:HistoryWriteCount -Message "Batch history should write history.json once."
    Assert-Equal -Expected 0 -Actual $script:PublishCount -Message "Batch history should defer sync publication when requested."

    $savedHistory = @(Get-Content -Path $historyPath -Raw | ConvertFrom-Json)
    Assert-Equal -Expected 221 -Actual $savedHistory.Count -Message "Batch history lost or duplicated records."
    Assert-Equal -Expected 1 -Actual @($savedHistory | Where-Object { $_.action -eq "External" }).Count -Message "Batch history overwrote an external writer."
    Assert-Equal -Expected 20 -Actual @($savedHistory | Where-Object { $_.authorUsername -eq "manager" }).Count -Message "Batch history actor metadata is incomplete."

    $script:HistoryReadCount = 0
    $script:HistoryWriteCount = 0
    $historyWrapperOutput = @(logHistory "Update" "Updated one entry." "Employee One")
    Assert-Equal -Expected 0 -Actual $historyWrapperOutput.Count -Message "The backwards-compatible history wrapper should not emit pipeline output."
    Assert-Equal -Expected 1 -Actual $script:HistoryReadCount -Message "Single-entry history wrapper should read once."
    Assert-Equal -Expected 1 -Actual $script:HistoryWriteCount -Message "Single-entry history wrapper should write once."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Single-entry history wrapper should publish once."
    Assert-Equal -Expected "history" -Actual $script:LastPublishCategory -Message "Single-entry history wrapper published the wrong category."
    Assert-Equal -Expected "Employee One" -Actual $script:LastPublishResource -Message "Single-entry history wrapper published the wrong resource."

    $employeeOneCode = "000000001"
    $employeeTwoCode = "000000002"
    $employeeOneFile = Join-Path -Path $tempFolder -ChildPath "${employeeOneCode}_data.json"
    $employeeTwoFile = Join-Path -Path $tempFolder -ChildPath "${employeeTwoCode}_data.json"
    $employeeOneEntry = [PSCustomObject]@{
        entryId = "batch-one"; date = "2026-07-10"; punchIn = "08:00:00"; exactPunchIn = "08:00:00";
        punchOut = "09:00:00"; status = "pending"; projectCode = "P001"
    }
    $employeeTwoEntry = [PSCustomObject]@{
        entryId = "batch-two"; date = "2026-07-11"; punchIn = "09:00:00"; exactPunchIn = "09:00:00";
        punchOut = "10:00:00"; status = "pending"; projectCode = "P001"
    }
    [System.IO.File]::WriteAllText($employeeOneFile, (ConvertTo-Json -InputObject @($employeeOneEntry) -Depth 8))
    [System.IO.File]::WriteAllText($employeeTwoFile, (ConvertTo-Json -InputObject @($employeeTwoEntry) -Depth 8))

    $script:BatchPayload = [PSCustomObject]@{
        status  = "approved"
        message = ""
        entries = @(
            [PSCustomObject]@{ employeeCode = $employeeOneCode; entryId = "batch-one"; date = "2026-07-10"; punchIn = "08:00:00" },
            [PSCustomObject]@{ employeeCode = $employeeTwoCode; entryId = "batch-two"; date = "2026-07-11"; punchIn = "09:00:00" }
        )
    }
    $request = [PSCustomObject]@{
        HttpMethod = "POST"
        Url        = [PSCustomObject]@{ AbsolutePath = "/employee/approval/batch" }
    }
    $response = [PSCustomObject]@{}
    $script:CapturedResponseJson = ""
    function Read-JsonRequestBody { param($Request) return $script:BatchPayload }
    function Get-EmployeeRoleByCode { param([string]$EmployeeCode) return "employee" }
    function Test-CurrentUserCanManageEntry { param($CurrentUser, $Entry) return $true }
    function Test-CurrentUserCanApproveEmployeeRole { param($CurrentUser, [string]$EmployeeRole) return $true }
    function Get-EmployeeName {
        param([string]$EmployeeCode)
        return ("Employee {0}" -f $EmployeeCode)
    }
    function respondWithSuccess {
        param($Response, [string]$Message)
        $script:CapturedResponseJson = $Message
    }
    function respondWithError {
        param($Response, [int]$StatusCode, [string]$Message)
        throw "Unexpected route error $StatusCode`: $Message"
    }

    $script:PublishCount = 0
    $script:LastPublishCategory = ""
    $script:LastPublishResource = ""
    $script:HistoryReadCount = 0
    $script:HistoryWriteCount = 0
    $script:WriteCountsByPath = @{}
    for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
        . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/batch-approval.routes.ps1")
    }

    $routeResult = $script:CapturedResponseJson | ConvertFrom-Json
    $savedEmployeeOne = @(Get-Content -Path $employeeOneFile -Raw | ConvertFrom-Json)[0]
    $savedEmployeeTwo = @(Get-Content -Path $employeeTwoFile -Raw | ConvertFrom-Json)[0]
    Assert-Equal -Expected 2 -Actual $routeResult.updatedCount -Message "Batch route returned the wrong update count."
    Assert-Equal -Expected "approved" -Actual $savedEmployeeOne.status -Message "Batch route did not update employee one."
    Assert-Equal -Expected "approved" -Actual $savedEmployeeTwo.status -Message "Batch route did not update employee two."
    Assert-Equal -Expected 1 -Actual $script:WriteCountsByPath[$employeeOneFile] -Message "Batch route should write employee one once."
    Assert-Equal -Expected 1 -Actual $script:WriteCountsByPath[$employeeTwoFile] -Message "Batch route should write employee two once."
    Assert-Equal -Expected 1 -Actual $script:WriteCountsByPath[$historyPath] -Message "Batch route should write history once."
    Assert-Equal -Expected 1 -Actual $script:PublishCount -Message "Batch route should publish sync once."
    Assert-Equal -Expected "employee" -Actual $script:LastPublishCategory -Message "Batch route published the wrong sync category."
    Assert-Equal -Expected "*" -Actual $script:LastPublishResource -Message "Multi-employee batch should publish the wildcard resource."
    Assert-Equal -Expected 2 -Actual @($script:LastAffectedEmployeeCodes).Count -Message "Multi-employee batch should publish both affected employee codes."

    $script:HistoryFailureMessage = ""
    $script:HistoryAttemptCount = 0
    function Add-HistoryEntries {
        param(
            [Parameter(Mandatory = $true)]$Entries,
            [bool]$PublishChange = $true,
            [string]$PublishResource = ""
        )

        $script:HistoryAttemptCount++
        if (-not [string]::IsNullOrWhiteSpace($script:HistoryFailureMessage)) {
            throw $script:HistoryFailureMessage
        }

        return @($Entries).Count
    }

    function respondWithSuccess {
        param($Response, [string]$Message)
        $script:CapturedSuccessJson = $Message
    }

    function respondWithError {
        param($Response, [int]$StatusCode, [string]$Message)
        $script:CapturedErrorStatus = $StatusCode
        $script:CapturedErrorMessage = $Message
    }

    function Invoke-BatchApprovalExceptionScenario {
        param(
            [string]$HistoryFailureMessage = "",
            [string]$PublishFailureMessage = ""
        )

        $scenarioEntry = [PSCustomObject]@{
            entryId = "batch-one"; date = "2026-07-10"; punchIn = "08:00:00"; exactPunchIn = "08:00:00";
            punchOut = "09:00:00"; status = "pending"; projectCode = "P001"
        }
        [System.IO.File]::WriteAllText($employeeOneFile, (ConvertTo-Json -InputObject @($scenarioEntry) -Depth 8))

        $script:BatchPayload = [PSCustomObject]@{
            status  = "approved"
            message = ""
            entries = @(
                [PSCustomObject]@{ employeeCode = $employeeOneCode; entryId = "batch-one"; date = "2026-07-10"; punchIn = "08:00:00" }
            )
        }
        $script:HistoryFailureMessage = $HistoryFailureMessage
        $script:PublishFailureMessage = $PublishFailureMessage
        $script:HistoryAttemptCount = 0
        $script:PublishCount = 0
        $script:LastPublishCategory = ""
        $script:LastPublishResource = ""
        $script:LastAffectedEmployeeCodes = @()
        $script:CapturedSuccessJson = ""
        $script:CapturedErrorStatus = 0
        $script:CapturedErrorMessage = ""

        $request = [PSCustomObject]@{
            HttpMethod = "POST"
            Url        = [PSCustomObject]@{ AbsolutePath = "/employee/approval/batch" }
        }
        $response = [PSCustomObject]@{}
        for ($routeRun = 0; $routeRun -lt 1; $routeRun++) {
            . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/batch-approval.routes.ps1")
        }

        $savedEntry = @(Get-Content -Path $employeeOneFile -Raw | ConvertFrom-Json)[0]
        return [PSCustomObject]@{
            Entry               = $savedEntry
            ErrorStatus         = $script:CapturedErrorStatus
            ErrorMessage        = $script:CapturedErrorMessage
            SuccessJson         = $script:CapturedSuccessJson
            HistoryAttemptCount = $script:HistoryAttemptCount
            PublishCount        = $script:PublishCount
            PublishCategory     = $script:LastPublishCategory
            PublishResource     = $script:LastPublishResource
            AffectedCodes       = @($script:LastAffectedEmployeeCodes)
        }
    }

    $historyFailure = "simulated history append failure"
    $historyFailureResult = Invoke-BatchApprovalExceptionScenario -HistoryFailureMessage $historyFailure
    Assert-Equal -Expected "approved" -Actual $historyFailureResult.Entry.status -Message "The employee mutation should remain committed when history append fails."
    Assert-Equal -Expected 1 -Actual $historyFailureResult.HistoryAttemptCount -Message "The failure scenario should attempt one batched history append."
    Assert-Equal -Expected 1 -Actual $historyFailureResult.PublishCount -Message "A committed employee mutation must still publish once when history append fails."
    Assert-Equal -Expected "employee" -Actual $historyFailureResult.PublishCategory -Message "The history-failure path published the wrong category."
    Assert-Equal -Expected $employeeOneCode -Actual $historyFailureResult.PublishResource -Message "The history-failure path published the wrong employee resource."
    Assert-Equal -Expected 1 -Actual @($historyFailureResult.AffectedCodes).Count -Message "The history-failure path should publish one affected employee code."
    Assert-Equal -Expected 500 -Actual $historyFailureResult.ErrorStatus -Message "A history append failure should return a server error."
    Assert-Equal -Expected $true -Actual ($historyFailureResult.ErrorMessage -like "*$historyFailure*") -Message "The history append failure should remain visible to the caller."
    Assert-Equal -Expected "" -Actual $historyFailureResult.SuccessJson -Message "A history append failure must not return success."

    $earlierFailure = "simulated earlier history operation failure"
    $maskedPublishFailure = "simulated publish failure that must not mask the operation error"
    $savedWarningPreference = $WarningPreference
    $WarningPreference = "SilentlyContinue"
    try {
        $operationAndPublishFailureResult = Invoke-BatchApprovalExceptionScenario -HistoryFailureMessage $earlierFailure -PublishFailureMessage $maskedPublishFailure
    }
    finally {
        $WarningPreference = $savedWarningPreference
    }
    Assert-Equal -Expected "approved" -Actual $operationAndPublishFailureResult.Entry.status -Message "The employee mutation should remain committed when history and publish both fail."
    Assert-Equal -Expected 1 -Actual $operationAndPublishFailureResult.PublishCount -Message "The finally block should attempt publication once after an earlier operation error."
    Assert-Equal -Expected 500 -Actual $operationAndPublishFailureResult.ErrorStatus -Message "The earlier operation failure should return a server error."
    Assert-Equal -Expected $true -Actual ($operationAndPublishFailureResult.ErrorMessage -like "*$earlierFailure*") -Message "Publish failure masked the earlier operation error."
    Assert-Equal -Expected $false -Actual ($operationAndPublishFailureResult.ErrorMessage -like "*$maskedPublishFailure*") -Message "The caller saw the publish failure instead of the earlier operation error."

    $publishOnlyFailure = "simulated publish-only failure"
    $publishFailureResult = Invoke-BatchApprovalExceptionScenario -PublishFailureMessage $publishOnlyFailure
    Assert-Equal -Expected "approved" -Actual $publishFailureResult.Entry.status -Message "The employee mutation should be committed before publication is attempted."
    Assert-Equal -Expected 1 -Actual $publishFailureResult.HistoryAttemptCount -Message "The publish-only scenario should complete its history operation."
    Assert-Equal -Expected 1 -Actual $publishFailureResult.PublishCount -Message "The publish-only scenario should attempt publication once."
    Assert-Equal -Expected 500 -Actual $publishFailureResult.ErrorStatus -Message "A publish failure with no earlier error should surface as a server error."
    Assert-Equal -Expected $true -Actual ($publishFailureResult.ErrorMessage -like "*$publishOnlyFailure*") -Message "The publish-only failure did not surface to the caller."
    Assert-Equal -Expected "" -Actual $publishFailureResult.SuccessJson -Message "A publish-only failure must not return success."

    $speedup = if ($indexedElapsed.TotalMilliseconds -gt 0) { $linearElapsed.TotalMilliseconds / $indexedElapsed.TotalMilliseconds } else { 0 }
    Write-Host ("Batch approval refactor test passed. Entry lookup: {0:N1} ms linear vs {1:N1} ms indexed ({2:N1}x)." -f $linearElapsed.TotalMilliseconds, $indexedElapsed.TotalMilliseconds, $speedup)
}
finally {
    if (Test-Path -Path $tempFolder) {
        Remove-Item -Path $tempFolder -Recurse -Force
    }
}
