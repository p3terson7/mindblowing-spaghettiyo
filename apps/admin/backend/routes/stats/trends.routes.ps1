        # Trends Endpoint: GET /stats/projects/trends
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/trends/?$") {
            # Parse query parameters for filtering.
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $startDate = $query["startDate"]
            $endDate = $query["endDate"]
    
            try {
                $result = Get-ProjectTrendModel -StartDate $startDate -EndDate $endDate
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Error retrieving project trends: $($_.Exception.Message)"
            }
            continue
        }
