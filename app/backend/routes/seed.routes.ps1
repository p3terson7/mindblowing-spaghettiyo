if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/seed/demo-entries") {
    if (-not [bool]$demoSeedEnabled) {
        respondWithError $response 403 "Demo-data generation is disabled in this deployment."
        continue
    }

    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }

    if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
        respondWithError $response 403 "Super admin access is required."
        continue
    }

    $seedOperationStarted = $false
    $seedOperationCompleted = $false
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

        $seedOperationStarted = $true
        $result = New-DemoOvertimeEntries -CurrentUser $currentUser -MinimumEntriesPerEmployee $minimumEntries -MaximumEntriesPerEmployee $maximumEntries -MonthsBack $monthsBack
        $seedOperationCompleted = $true
        respondWithSuccess $response ($result | ConvertTo-Json -Depth 8)
    }
    catch {
        $seedOperationError = $_
        if ($seedOperationStarted -and -not $seedOperationCompleted) {
            # The seed service can fail after one or more employee files were written. A wildcard publication is safe
            # when the route cannot distinguish that partial-commit case from an earlier service validation failure.
            try {
                Publish-DataChange -Category "seed" -Resource "*" | Out-Null
            }
            catch {
                Write-Warning "Unable to publish seed cache invalidation after a failed seed operation: $($_.Exception.Message)"
            }
        }

        Write-Warning ("Unable to seed demo entries: {0}" -f $seedOperationError.Exception.Message)
        respondWithError $response 500 "Unable to seed demo entries."
    }
    continue
}
