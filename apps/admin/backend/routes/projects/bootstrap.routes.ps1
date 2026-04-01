        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/projects/bootstrap") {
            try {
                $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
                $startDate = $query["startDate"]
                $endDate = $query["endDate"]
                $projectCode = $query["projectCode"]

                $payload = Get-ProjectsBootstrapModel -StartDate $startDate -EndDate $endDate -SelectedProjectCode $projectCode
                respondWithSuccess $response ($payload | ConvertTo-Json -Depth 8)
            }
            catch {
                respondWithError $response 500 "Unable to build project data: $($_.Exception.Message)"
            }
            continue
        }
