function Get-ProjectStatistics {
    param (
        [string]$startDate,
        [string]$endDate,
        $CurrentUser
    )

    return (Get-ProjectStatisticsOverview -StartDate $startDate -EndDate $endDate -CurrentUser $CurrentUser)
}

function Get-BudgetPeriodProjectComparison {
    param($CurrentUser)

    $configuration = Get-BudgetPeriodConfiguration
    $periodModels = New-Object System.Collections.ArrayList

    foreach ($period in @($configuration.periods)) {
        $isConfigured = [bool]$period.configured
        $summaries = if ($isConfigured) {
            @(Get-ProjectSummaryList -StartDate ([string]$period.startDate) -EndDate ([string]$period.endDate) -CurrentUser $CurrentUser)
        }
        else {
            @()
        }
        $approvedSeconds = [long]0
        $approvedEntryCount = 0
        $projectsWithOvertimeCount = 0
        foreach ($summary in $summaries) {
            $projectSeconds = [long]$summary.totalSeconds
            $approvedSeconds += $projectSeconds
            $approvedEntryCount += [int]$summary.approvedEntryCount
            if ($projectSeconds -gt 0) {
                $projectsWithOvertimeCount++
            }
        }

        [void]$periodModels.Add([PSCustomObject][ordered]@{
            id                        = [string]$period.id
            configured                = $isConfigured
            startDate                 = [string]$period.startDate
            endDate                   = [string]$period.endDate
            approvedSeconds           = $approvedSeconds
            approvedOvertime          = Convert-SecondsToTimeText -Seconds $approvedSeconds
            approvedEntryCount        = $approvedEntryCount
            projectsWithOvertimeCount = $projectsWithOvertimeCount
            projects                  = @($summaries)
        })
    }

    return [PSCustomObject][ordered]@{
        schemaVersion = [int]$configuration.schemaVersion
        cycleLabel    = [string]$configuration.cycleLabel
        periods       = @($periodModels.ToArray())
    }
}
