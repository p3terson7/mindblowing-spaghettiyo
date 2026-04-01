$currentUser = Get-AuthenticatedUserFromRequest -Request $request
if ($request.Url.AbsolutePath -eq "/history") {
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserRole -CurrentUser $currentUser -AllowedRoles @("admin"))) {
        respondWithError $response 403 "Admin access is required."
        continue
    }
}

if ($request.Url.AbsolutePath -eq "/history/recent") {
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserRole -CurrentUser $currentUser -AllowedRoles @("admin"))) {
        respondWithError $response 403 "Admin access is required."
        continue
    }
}

        # GET /history Endpoint
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/history") {
            try {
                $historyContent = (@(Get-HistoryEntriesSnapshot) | ConvertTo-Json -Depth 6)
                respondWithSuccess $response $historyContent
            }
            catch {
                respondWithError $response 500 "Error reading history: $($_.Exception.Message)"
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

                $historyContent = (@(Get-RecentHistoryEntriesSnapshot -Limit $limit) | ConvertTo-Json -Depth 6)
                respondWithSuccess $response $historyContent
            }
            catch {
                respondWithError $response 500 "Error reading recent history: $($_.Exception.Message)"
            }
            continue
        }
