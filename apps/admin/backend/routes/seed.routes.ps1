if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/seed/demo-entries") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }

    if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
        respondWithError $response 403 "Super admin access is required."
        continue
    }

    try {
        $payload = Read-JsonRequestBody -Request $request
        $minimumEntries = 4
        $maximumEntries = 8
        $monthsBack = 6

        if ($null -ne $payload) {
            if ($payload.PSObject.Properties.Name -contains "minimumEntriesPerEmployee") {
                $parsedMinimum = 0
                if ([int]::TryParse([string]$payload.minimumEntriesPerEmployee, [ref]$parsedMinimum) -and $parsedMinimum -gt 0) {
                    $minimumEntries = [math]::Min($parsedMinimum, 20)
                }
            }

            if ($payload.PSObject.Properties.Name -contains "maximumEntriesPerEmployee") {
                $parsedMaximum = 0
                if ([int]::TryParse([string]$payload.maximumEntriesPerEmployee, [ref]$parsedMaximum) -and $parsedMaximum -gt 0) {
                    $maximumEntries = [math]::Min($parsedMaximum, 30)
                }
            }

            if ($payload.PSObject.Properties.Name -contains "monthsBack") {
                $parsedMonthsBack = 0
                if ([int]::TryParse([string]$payload.monthsBack, [ref]$parsedMonthsBack) -and $parsedMonthsBack -gt 0) {
                    $monthsBack = [math]::Min($parsedMonthsBack, 24)
                }
            }
        }

        $result = New-DemoOvertimeEntries -CurrentUser $currentUser -MinimumEntriesPerEmployee $minimumEntries -MaximumEntriesPerEmployee $maximumEntries -MonthsBack $monthsBack
        respondWithSuccess $response ($result | ConvertTo-Json -Depth 8)
    }
    catch {
        respondWithError $response 500 "Unable to seed demo entries: $($_.Exception.Message)"
    }
    continue
}
