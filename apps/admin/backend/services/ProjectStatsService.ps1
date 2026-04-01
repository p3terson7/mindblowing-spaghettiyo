function Get-ProjectStatistics {
    param (
        [string]$startDate,
        [string]$endDate
    )

    return (Get-ProjectStatisticsOverview -StartDate $startDate -EndDate $endDate)
}
