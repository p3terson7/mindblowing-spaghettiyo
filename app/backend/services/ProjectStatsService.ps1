function Get-ProjectStatistics {
    param (
        [string]$startDate,
        [string]$endDate,
        $CurrentUser
    )

    return (Get-ProjectStatisticsOverview -StartDate $startDate -EndDate $endDate -CurrentUser $CurrentUser)
}
