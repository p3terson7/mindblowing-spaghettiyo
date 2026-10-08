$ErrorActionPreference = "Stop"

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Get-BudgetPeriodConfiguration {
    return [PSCustomObject]@{
        schemaVersion = 2
        cycleLabel = "2026-2027"
        periods = @(
            [PSCustomObject]@{ id = "P1"; configured = $true; startDate = "2026-04-01"; endDate = "2026-06-30" },
            [PSCustomObject]@{ id = "P2"; configured = $true; startDate = "2026-07-01"; endDate = "2026-09-30" },
            [PSCustomObject]@{ id = "P3"; configured = $false; startDate = ""; endDate = "" },
            [PSCustomObject]@{ id = "P4"; configured = $false; startDate = ""; endDate = "" }
        )
    }
}

function Get-ProjectSummaryList {
    param([string]$StartDate, [string]$EndDate, $CurrentUser)

    if ($StartDate -eq "2026-04-01") {
        return @(
            [PSCustomObject]@{ projectCode = "A"; totalSeconds = 7200; approvedEntryCount = 2; monetary = [PSCustomObject]@{ totalAmountCents = 12000; cashAmountCents = 8000; compensatoryLeaveValueCents = 4000; calculatedEntryCount = 2; unavailableEntryCount = 0 } },
            [PSCustomObject]@{ projectCode = "B"; totalSeconds = 0; approvedEntryCount = 0 }
        )
    }
    if ($StartDate -eq "2026-07-01") {
        return @(
            [PSCustomObject]@{ projectCode = "A"; totalSeconds = 3600; approvedEntryCount = 1; monetary = [PSCustomObject]@{ totalAmountCents = 6000; cashAmountCents = 6000; compensatoryLeaveValueCents = 0; calculatedEntryCount = 1; unavailableEntryCount = 0 } },
            [PSCustomObject]@{ projectCode = "B"; totalSeconds = 1800; approvedEntryCount = 1 }
        )
    }
    throw "The comparison requested an unconfigured period."
}

function Convert-SecondsToTimeText {
    param([long]$Seconds)
    return ("{0:D2}:{1:D2}:00" -f [int][math]::Floor($Seconds / 3600), [int](($Seconds % 3600) / 60))
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/ProjectStatsService.ps1")

$result = Get-BudgetPeriodProjectComparison -CurrentUser ([PSCustomObject]@{ role = "admin" })
Assert-Equal -Expected "2026-2027" -Actual ([string]$result.cycleLabel) -Message "The cycle label was lost."
Assert-Equal -Expected 4 -Actual @($result.periods).Count -Message "The response must preserve P1 through P4."
Assert-Equal -Expected 7200 -Actual ([long]$result.periods[0].approvedSeconds) -Message "P1 approved time was aggregated incorrectly."
Assert-Equal -Expected 2 -Actual ([int]$result.periods[0].approvedEntryCount) -Message "P1 approved entries were aggregated incorrectly."
Assert-Equal -Expected 1 -Actual ([int]$result.periods[0].projectsWithOvertimeCount) -Message "Zero-hour projects must not count as active in a period."
Assert-Equal -Expected 5400 -Actual ([long]$result.periods[1].approvedSeconds) -Message "P2 approved time was aggregated incorrectly."
Assert-Equal -Expected 2 -Actual ([int]$result.periods[1].projectsWithOvertimeCount) -Message "P2 project activity was aggregated incorrectly."
Assert-Equal -Expected 0 -Actual @($result.periods[2].projects).Count -Message "Unconfigured periods must not query or expose project statistics."
Assert-Equal -Expected 12000 -Actual $result.periods[0].monetary.totalAmountCents -Message "Period monetary totals must reuse approved project amounts."
Assert-Equal -Expected 8000 -Actual $result.periods[0].monetary.cashAmountCents -Message "Cash and leave values were merged in the period result."
Assert-Equal -Expected 4000 -Actual $result.periods[0].monetary.compensatoryLeaveValueCents -Message "The period lost compensatory leave value."
Assert-Equal -Expected 1 -Actual $result.periods[1].monetary.unavailableEntryCount -Message "Entries without a monetary projection must count as unavailable."
Assert-Equal -Expected 50 -Actual $result.periods[1].monetary.coveragePercent -Message "Partial monetary coverage must be explicit."

Write-Host "Budget-period project comparison model tests passed."
