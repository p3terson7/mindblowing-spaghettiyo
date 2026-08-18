        # Trends Endpoint: GET /stats/projects/trends
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/trends/?$") {
            # Parse query parameters for filtering.
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $startDate = $query["startDate"]
            $endDate = $query["endDate"]
    
            try {
                $result = Get-ProjectTrendModel -StartDate $startDate -EndDate $endDate -CurrentUser $currentUser
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 4)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to retrieve project trends: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to retrieve project trends."
            }
            continue
        }
