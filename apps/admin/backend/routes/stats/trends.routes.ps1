        # Trends Endpoint: GET /stats/projects/trends
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/trends/?$") {
            # Parse query parameters for filtering.
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $startDate = $query["startDate"]
            $endDate = $query["endDate"]
    
            try {
                # Hashtable to hold overtime totals per project per month.
                $trendStats = @{}
                
                # Get all employee data files (files ending with "_data.json").
                $employeeFiles = Get-ChildItem -Path $sharedFolder -Filter "*_data.json"
                
                foreach ($file in $employeeFiles) {
                    $entries = Read-JsonArrayFile -Path $file.FullName
                    foreach ($entry in $entries) {
                        # Skip entries without a projectCode.
                        if ([string]::IsNullOrWhiteSpace($entry.projectCode)) { continue }
                        
                        # Parse the entry date (assuming format "yyyy-MM-dd").
                        try {
                            $entryDate = [DateTime]::ParseExact($entry.date, "yyyy-MM-dd", $null)
                        }
                        catch {
                            continue
                        }
                        
                        # Apply date range filtering if provided.
                        if ($startDate) {
                            try {
                                $startDt = [DateTime]::ParseExact($startDate, "yyyy-MM-dd", $null)
                                if ($entryDate -lt $startDt) { continue }
                            }
                            catch { }
                        }
                        if ($endDate) {
                            try {
                                $endDt = [DateTime]::ParseExact($endDate, "yyyy-MM-dd", $null)
                                if ($entryDate -gt $endDt) { continue }
                            }
                            catch { }
                        }
                        
                        # Extract the month (YYYY-MM)
                        $month = $entry.date.Substring(0, 7)
                        
                        # Parse overtime string into a TimeSpan.
                        try {
                            $ts = [TimeSpan]::Parse($entry.overtime)
                        }
                        catch {
                            $ts = [TimeSpan]::Zero
                        }
                        $seconds = $ts.TotalSeconds
                        
                        # Initialize project entry if not already present.
                        if (-not $trendStats.ContainsKey($entry.projectCode)) {
                            $trendStats[$entry.projectCode] = @{}
                        }
                        # Initialize month within project if not already present.
                        if (-not $trendStats[$entry.projectCode].ContainsKey($month)) {
                            $trendStats[$entry.projectCode][$month] = 0
                        }
                        
                        $trendStats[$entry.projectCode][$month] += $seconds
                    }
                }
                
                # Reformat the trend statistics into the desired output structure.
                $result = @{}
                foreach ($proj in $trendStats.Keys) {
                    $monthsArray = @()
                    # Sort the month keys (assumes YYYY-MM format will sort lexicographically).
                    foreach ($m in $trendStats[$proj].Keys | Sort-Object) {
                        $totalSec = $trendStats[$proj][$m]
                        # Convert seconds into hours (rounded to 2 decimal places).
                        $hours = [math]::Round($totalSec / 3600, 2)
                        $monthsArray += [PSCustomObject]@{
                            month    = $m
                            overtime = $hours
                        }
                    }
                    $result[$proj] = $monthsArray
                }
                
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Error retrieving project trends: $($_.Exception.Message)"
            }
            continue
        }
