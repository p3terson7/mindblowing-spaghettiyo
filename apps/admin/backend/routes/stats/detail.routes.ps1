        # GET /stats/projects/{projectCode}: Return detailed overtime stats for a specific project.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/([^/]+)/?$") {
            $projectCode = [System.Uri]::UnescapeDataString([string]$matches[1]).Trim()
            
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $startDate = $query["startDate"]
            $endDate = $query["endDate"]

            try {
                $projects = @(Get-Projects)
                $projObj = $projects | Where-Object { [string]$_.projectCode -eq [string]$projectCode } | Select-Object -First 1
                if (-not (Test-CurrentUserCanAccessProjectCode -CurrentUser $currentUser -ProjectCode $projectCode)) {
                    respondWithError $response 403 "You do not have access to project $projectCode."
                    continue
                }

                if ($null -eq $projObj -and -not (Get-ProjectStatistics -startDate $startDate -endDate $endDate -CurrentUser $currentUser).ContainsKey($projectCode)) {
                    respondWithError $response 404 "Project with code $projectCode was not found."
                    continue
                }
                $result = Get-ProjectDetailModel -ProjectCode $projectCode -StartDate $startDate -EndDate $endDate -CurrentUser $currentUser
                $jsonResult = $result | ConvertTo-Json -Depth 4
                respondWithSuccess $response $jsonResult
            }
            catch {
                Write-Warning ("Unable to compute statistics for project {0}: {1}" -f $projectCode, $_.Exception.Message)
                respondWithError $response 500 "Unable to compute statistics for project $projectCode."
            }
            continue
        }
