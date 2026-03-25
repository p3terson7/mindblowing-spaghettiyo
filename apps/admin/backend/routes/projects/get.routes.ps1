        # GET /projects: Return the list of projects.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/projects/?$") {
            try {
                $projectsData = Get-Projects
                $jsonResult = $projectsData | ConvertTo-Json -Depth 3
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResult)
                $response.ContentType = "application/json"
                $response.StatusCode = 200
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            catch {
                $errMsg = "{ `"error`": `"Error retrieving projects: $($_.Exception.Message)`" }"
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
