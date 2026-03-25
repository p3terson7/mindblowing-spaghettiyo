        # GET /stats/projects/{projectCode}: Return detailed overtime stats for a specific project.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/([^/]+)/?$") {
            $projectCode = $matches[1]
            
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $startDate = $query["startDate"]
            $endDate = $query["endDate"]

            try {
                $allStats = Get-ProjectStatistics -startDate $startDate -endDate $endDate
                $projects = Get-Projects
                
                if (-not $allStats.ContainsKey($projectCode)) {
                    respondWithError $response 404 "Project with code $projectCode has no overtime entries."
                    continue
                }
                
                $projStats = $allStats[$projectCode]
                $totalSec = $projStats.totalSeconds
                $count = $projStats.entryCount
                $totalTS = New-TimeSpan -Seconds $totalSec
                $totalOvertime = $totalTS.ToString("hh\:mm\:ss")
                $avgSec = ($count -gt 0) ? [math]::Round($totalSec / $count) : 0
                $avgTS = New-TimeSpan -Seconds $avgSec
                $averageOvertime = $avgTS.ToString("hh\:mm\:ss")
                
                $breakdown = @()
                foreach ($emp in $projStats.breakdown.Keys) {
                    $empData = $projStats.breakdown[$emp]
                    $empTS = New-TimeSpan -Seconds $empData.totalSeconds
                    $empOvertime = $empTS.ToString("hh\:mm\:ss")
                    $breakdown += [PSCustomObject]@{
                        employee   = $emp
                        overtime   = $empOvertime
                        entryCount = $empData.entryCount
                        entries    = $empData.entries
                    }
                }
                
                $projObj = $projects | Where-Object { $_.projectCode -eq $projectCode } | Select-Object -First 1
                $projectName = if ($projObj) { $projObj.projectName } else { "N/A" }
                
                $result = [PSCustomObject]@{
                    projectCode         = $projectCode
                    projectName         = $projectName
                    totalOvertime       = $totalOvertime
                    entryCount          = $count
                    averageOvertime     = $averageOvertime
                    breakdownByEmployee = $breakdown
                }
                
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
