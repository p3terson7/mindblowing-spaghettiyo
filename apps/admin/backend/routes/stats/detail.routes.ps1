        # GET /stats/projects/{projectCode}: Return detailed overtime stats for a specific project.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/([^/]+)/?$") {
            $projectCode = $matches[1]
            
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $startDate = $query["startDate"]
            $endDate = $query["endDate"]

            try {
                $projects = @(Get-Projects)
                $projObj = $projects | Where-Object { [string]$_.projectCode -eq [string]$projectCode } | Select-Object -First 1
                if ($null -eq $projObj -and -not (Get-ProjectStatistics -startDate $startDate -endDate $endDate).ContainsKey($projectCode)) {
                    respondWithError $response 404 "Project with code $projectCode was not found."
                    continue
                }
                $result = Get-ProjectDetailModel -ProjectCode $projectCode -StartDate $startDate -EndDate $endDate
                $jsonResult = $result | ConvertTo-Json -Depth 4
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResult)
                $response.ContentType = "application/json"
                $response.StatusCode = 200
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            catch {
                $errMsg = "{ `"error`": `"Error computing stats for project $projectCode : $($_.Exception.Message)`" }"
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                $response.StatusCode = 500
                $response.ContentType = "application/json"
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $response.Close()
            }
            continue
        }
