        # GET /stats/projects: Return a summary of overtime statistics for each project.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/?$") {
            try {
                $allStats = Get-ProjectStatistics
                $projects = Get-Projects

                $result = @()
                foreach ($projCode in $allStats.Keys) {
                    $totalSec = $allStats[$projCode].totalSeconds
                    $count = $allStats[$projCode].entryCount
                    $totalTS = New-TimeSpan -Seconds $totalSec
                    $totalOvertime = $totalTS.ToString("hh\:mm\:ss")
                    $avgSec = ($count -gt 0) ? [math]::Round($totalSec / $count) : 0
                    $avgTS = New-TimeSpan -Seconds $avgSec
                    $averageOvertime = $avgTS.ToString("hh\:mm\:ss")
                    
                    # Lookup projectName from the projects list.
                    $projObj = $projects | Where-Object { $_.projectCode -eq $projCode } | Select-Object -First 1
                    $projectName = if ($projObj) { $projObj.projectName } else { "N/A" }
                    
                    $result += [PSCustomObject]@{
                        projectCode     = $projCode
                        projectName     = $projectName
                        totalOvertime   = $totalOvertime
                        entryCount      = $count
                        averageOvertime = $averageOvertime
                    }
                }
                
                if ($result.Count -eq 0) {
                    $jsonResult = "[]"
                }
                else {
                    $jsonResult = $result | ConvertTo-Json -Depth 3
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResult)
                $response.ContentType = "application/json"
                $response.StatusCode = 200
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            catch {
                $errMsg = "{ `"error`": `"Error computing project stats: $($_.Exception.Message)`" }"
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
