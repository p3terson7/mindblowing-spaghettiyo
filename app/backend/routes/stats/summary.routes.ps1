        # GET /stats/projects: Return a summary of overtime statistics for each project.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/?$") {
            try {
                $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
                $startDate = $query["startDate"]
                $endDate = $query["endDate"]
                $result = @(Get-ProjectSummaryList -StartDate $startDate -EndDate $endDate -CurrentUser $currentUser)
                $jsonResult = ConvertTo-Json -InputObject $result -Depth 6
                respondWithSuccess $response $jsonResult
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to compute project statistics: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to compute project statistics."
            }
            continue
        }
