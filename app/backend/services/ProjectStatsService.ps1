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
        $monetaryTotal = [long]0
        $cashTotal = [long]0
        $leaveTotal = [long]0
        $calculatedCount = 0
        $unavailableCount = 0
        foreach ($summary in $summaries) {
            $projectSeconds = [long]$summary.totalSeconds
            $approvedSeconds += $projectSeconds
            $approvedEntryCount += [int]$summary.approvedEntryCount
            if ($projectSeconds -gt 0) {
                $projectsWithOvertimeCount++
            }
            if ($summary.PSObject.Properties.Name -contains "monetary" -and $null -ne $summary.monetary) {
                $monetaryTotal += [long]$summary.monetary.totalAmountCents
                $cashTotal += [long]$summary.monetary.cashAmountCents
                $leaveTotal += [long]$summary.monetary.compensatoryLeaveValueCents
                $calculatedCount += [int]$summary.monetary.calculatedEntryCount
                $unavailableCount += [int]$summary.monetary.unavailableEntryCount
            }
            else {
                $unavailableCount += [int]$summary.approvedEntryCount
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
            monetary                  = [PSCustomObject][ordered]@{
                currency                    = "CAD"
                estimateOnly                = $true
                costBasis                   = "salary-only"
                includesEmployerCosts       = $false
                approvedEntryCount          = $approvedEntryCount
                calculatedEntryCount        = $calculatedCount
                unavailableEntryCount       = $unavailableCount
                coveragePercent             = if ($approvedEntryCount -gt 0) { [math]::Round(($calculatedCount / [double]$approvedEntryCount) * 100, 1) } else { 100 }
                totalAmountCents            = $monetaryTotal
                cashAmountCents             = $cashTotal
                compensatoryLeaveValueCents = $leaveTotal
            }
            projects                  = @($summaries)
        })
    }

    return [PSCustomObject][ordered]@{
        schemaVersion = [int]$configuration.schemaVersion
        cycleLabel    = [string]$configuration.cycleLabel
        periods       = @($periodModels.ToArray())
    }
}
