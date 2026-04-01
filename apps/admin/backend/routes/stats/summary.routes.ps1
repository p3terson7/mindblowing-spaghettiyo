        # GET /stats/projects: Return a summary of overtime statistics for each project.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/projects/?$") {
            try {
                $result = @(Get-ProjectSummaryList)
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
