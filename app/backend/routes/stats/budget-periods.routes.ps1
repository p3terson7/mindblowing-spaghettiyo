if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/budget-periods/?$") {
    try {
        $result = Get-BudgetPeriodProjectComparison -CurrentUser $currentUser
        respondWithSuccess $response ($result | ConvertTo-Json -Depth 10)
    }
    catch {
        Rethrow-HttpStatusException -Exception $_.Exception
        Write-Warning ("Unable to compute budget-period statistics: {0}" -f $_.Exception.Message)
        respondWithError $response 500 "Unable to compute budget-period statistics."
    }
    continue
}
