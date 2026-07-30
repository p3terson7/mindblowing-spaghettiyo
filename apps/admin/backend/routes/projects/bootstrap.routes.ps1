        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/projects/bootstrap") {
            try {
                $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
                $startDate = $query["startDate"]
                $endDate = $query["endDate"]
                $projectCode = $query["projectCode"]

                $payload = Get-ProjectsBootstrapModel -StartDate $startDate -EndDate $endDate -SelectedProjectCode $projectCode -CurrentUser $currentUser
                respondWithSuccess $response ($payload | ConvertTo-Json -Depth 8)
            }
            catch {
                Write-Warning ("Unable to build project data: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to build project data."
            }
            continue
        }
