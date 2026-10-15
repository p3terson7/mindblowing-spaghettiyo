$ErrorActionPreference = "Stop"

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

    if ([string]$Expected -cne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryDuration.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.EntryDuration.psm1"
$entryServicePath = Join-Path -Path $backendRoot -ChildPath "services/EntryService.ps1"
$readModelServicePath = Join-Path -Path $backendRoot -ChildPath "services/ReadModelService.ps1"
$gc179ExportServicePath = Join-Path -Path $backendRoot -ChildPath "services/Gc179ExportService.ps1"
$packageScriptPath = Join-Path -Path $repoRoot -ChildPath "scripts/package-app.ps1"
$releaseTestPath = Join-Path -Path $repoRoot -ChildPath "tests/powershell/test-release-package.ps1"

foreach ($path in @($manifestPath, $modulePath, $entryServicePath, $readModelServicePath, $gc179ExportServicePath, $packageScriptPath, $releaseTestPath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message ("Required duration-rule file is missing: {0}" -f $path)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "Saphir.EntryDuration.psm1" -Actual ([string]$manifest.RootModule) -Message "EntryDuration RootModule changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "EntryDuration must support Windows PowerShell 5.1."
Assert-Equal -Expected "Get-QuarterHourCreditSummary" -Actual (@($manifest.FunctionsToExport) -join "|") -Message "EntryDuration export contract changed."
Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
Assert-Equal -Expected 0 -Actual @($moduleParseErrors).Count -Message "EntryDuration has parser errors."
$forbiddenCommands = @(
    "Get-Content", "Set-Content", "Add-Content", "Out-File", "Test-Path",
    "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item", "Copy-Item",
    "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod", "Get-Date",
    "Acquire-ResourceLock", "Release-ResourceLock", "Read-JsonArrayFile",
    "Write-JsonAtomic", "Write-JsonArrayAtomic"
)
$impureCommands = @($moduleAst.FindAll({
    param($node)
    return ($node -is [System.Management.Automation.Language.CommandAst] -and $forbiddenCommands -contains $node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $impureCommands.Count -Message "EntryDuration must stay pure."

Remove-Module -Name "Saphir.EntryDuration" -Force -ErrorAction SilentlyContinue
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null

$creditCases = @(
    [PSCustomObject]@{ Label = "reported four-minute interval"; PunchIn = "14:04:00"; PunchOut = "14:08:00"; Expected = "00:00:00"; IsValid = $true },
    [PSCustomObject]@{ Label = "ten-minute boundary"; PunchIn = "14:04:00"; PunchOut = "14:14:00"; Expected = "00:15:00"; IsValid = $true },
    [PSCustomObject]@{ Label = "one second below boundary"; PunchIn = "14:04:00"; PunchOut = "14:13:59"; Expected = "00:00:00"; IsValid = $true },
    [PSCustomObject]@{ Label = "only first quarter qualifies"; PunchIn = "14:04:00"; PunchOut = "14:24:00"; Expected = "00:15:00"; IsValid = $true },
    [PSCustomObject]@{ Label = "two qualifying clock quarters"; PunchIn = "14:05:00"; PunchOut = "14:25:00"; Expected = "00:30:00"; IsValid = $true },
    [PSCustomObject]@{ Label = "invalid reverse interval"; PunchIn = "14:08:00"; PunchOut = "14:04:00"; Expected = "00:00:00"; IsValid = $false }
)
foreach ($case in $creditCases) {
    $summary = Saphir.EntryDuration\Get-QuarterHourCreditSummary -Date "2026-08-24" -PunchIn $case.PunchIn -PunchOut $case.PunchOut
    Assert-Equal -Expected $case.IsValid -Actual ([bool]$summary.isValid) -Message ("Duration validity changed for {0}." -f $case.Label)
    Assert-Equal -Expected $case.Expected -Actual ([string]$summary.creditedOvertime) -Message ("Quarter credit changed for {0}." -f $case.Label)
}

. $entryServicePath
$facadeSummary = Get-QuarterHourCreditSummary -Date "2026-08-24" -PunchIn "14:04:00" -PunchOut "14:08:00"
Assert-Equal -Expected "00:00:00" -Actual ([string]$facadeSummary.creditedOvertime) -Message "EntryService facade did not use exact quarter credit."

$shortEntry = [PSCustomObject]@{
    entryId = "short-entry"
    entryType = "overtime"
    name = "Short Entry"
    date = "2026-08-24"
    punchIn = "14:00:00"
    exactPunchIn = "14:04:00"
    punchOut = "14:15:00"
    exactPunchOut = "14:08:00"
    overtime = "00:15:00"
    status = "pending"
    message = ""
    projectCode = "P001"
}
Update-EntryComputedOvertime -Entry $shortEntry
Assert-Equal -Expected "00:00:00" -Actual ([string]$shortEntry.overtime) -Message "Completed short entry was not stored with zero credit."
Assert-Equal -Expected "quarter-10m-v1" -Actual ([string]$shortEntry.overtimeCalculationRule) -Message "Updated entry did not record its calculation rule."

. $gc179ExportServicePath
Assert-Equal -Expected $false -Actual (Test-Gc179ExportableEntry -Entry $shortEntry -MonthKey "2026-08") -Message "A zero-credit entry must not create an empty GC179 row."
Assert-Equal -Expected $false -Actual (Test-Gc179WorkedDateEntry -Entry $shortEntry) -Message "A zero-credit entry must not affect GC179 workday calculations."

$shortIssues = @(Get-EntryReviewIssues -Entry $shortEntry)
Assert-Equal -Expected 1 -Actual $shortIssues.Count -Message "Short entry should expose one review issue."
Assert-Equal -Expected "shortOvertime" -Actual ([string]$shortIssues[0].code) -Message "Short entry exposed the wrong review issue."
Assert-Equal -Expected 240 -Actual ([int]$shortIssues[0].actualSeconds) -Message "Short entry did not expose its actual duration."

$forgottenEntry = [PSCustomObject]@{ date = "2026-08-24"; punchIn = "14:00:00"; forgottenClockOut = $true }
$forgottenIssues = @(Get-EntryReviewIssues -Entry $forgottenEntry)
Assert-Equal -Expected "clockOutMissing" -Actual ([string]$forgottenIssues[0].code) -Message "Forgotten clock-out did not expose the review issue."

$activeEntry = [PSCustomObject]@{ date = "2026-08-24"; punchIn = "14:00:00" }
Assert-Equal -Expected 0 -Actual @(Get-EntryReviewIssues -Entry $activeEntry).Count -Message "An active session was incorrectly flagged as a clock-out error."

$importedShortEntry = $shortEntry.PSObject.Copy()
$importedShortEntry | Add-Member -NotePropertyName "gc179ImportBatchId" -NotePropertyValue "gc179-00000000000000000000000000000000"
Assert-Equal -Expected 0 -Actual @(Get-EntryReviewIssues -Entry $importedShortEntry).Count -Message "Official GC179 import duration must not be reinterpreted as a short-entry warning."
$importedShortEntry.overtime = "01:00:00"
Update-EntryComputedOvertime -Entry $importedShortEntry
Assert-Equal -Expected "01:00:00" -Actual ([string]$importedShortEntry.overtime) -Message "Saving an imported GC179 entry must preserve its declared duration."

$invalidEntry = $shortEntry.PSObject.Copy()
$invalidEntry.exactPunchOut = "not-a-time"
$invalidIssues = @(Get-EntryReviewIssues -Entry $invalidEntry)
Assert-Equal -Expected "invalidPunchTimes" -Actual ([string]$invalidIssues[0].code) -Message "Malformed completed punch times did not expose a review issue."

function Get-NormalizedRoleName {
    param([string]$Role)
    return $Role
}
. $readModelServicePath
$projection = New-EmployeeEntryProjection -EmployeeCode "000000001" -EmployeeName "Short Entry" -Entry $shortEntry
Assert-True -Condition ([bool]$projection.hasReviewIssues) -Message "Review projection did not expose its attention flag."
Assert-Equal -Expected "shortOvertime" -Actual ([string]$projection.reviewIssues[0].code) -Message "Review projection lost the short-entry issue."

$packageSource = Get-Content -LiteralPath $packageScriptPath -Raw
$releaseTestSource = Get-Content -LiteralPath $releaseTestPath -Raw
foreach ($fileName in @("Saphir.EntryDuration.psd1", "Saphir.EntryDuration.psm1")) {
    Assert-True -Condition $packageSource.Contains($fileName) -Message ("Runtime package validation omits {0}." -f $fileName)
    Assert-True -Condition $releaseTestSource.Contains($fileName) -Message ("Release package test omits {0}." -f $fileName)
}

Write-Host "Entry duration tests passed: exact quarter credit, persisted zero credit, Review issues, GC179 exemption, and package coverage."
