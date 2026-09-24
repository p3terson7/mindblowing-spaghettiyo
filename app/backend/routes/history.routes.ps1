if ($request.Url.AbsolutePath -eq "/history" -or $request.Url.AbsolutePath -eq "/history/recent") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    # GET /history Endpoint
    if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/history") {
        try {
            $historyContent = ConvertTo-Json -InputObject @(Get-HistoryEntriesSnapshot) -Depth 6
            respondWithSuccess $response $historyContent
        }
        catch {
            Rethrow-HttpStatusException -Exception $_.Exception
            Write-Warning ("Unable to read history: {0}" -f $_.Exception.Message)
            respondWithError $response 500 "Unable to read history."
        }
        continue
    }

    if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/history/recent") {
        try {
            $limit = 20
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            if ($query["limit"]) {
                $parsedLimit = 0
                if ([int]::TryParse([string]$query["limit"], [ref]$parsedLimit) -and $parsedLimit -gt 0) {
                    $limit = [math]::Min($parsedLimit, 100)
                }
            }

            $historyContent = ConvertTo-Json -InputObject @(Get-RecentHistoryEntriesSnapshot -Limit $limit) -Depth 6
            respondWithSuccess $response $historyContent
        }
        catch {
            Rethrow-HttpStatusException -Exception $_.Exception
            Write-Warning ("Unable to read recent history: {0}" -f $_.Exception.Message)
            respondWithError $response 500 "Unable to read recent history."
        }
        continue
    }
}
